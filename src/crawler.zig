const std = @import("std");
const Parser = @import("parser.zig");
const Page = Parser.Page;
const Storage = @import("storage.zig");
const Logger = @import("logger.zig");
const Context = @import("context.zig");

const Crawler = @This();

visited: std.StringHashMap(void),
queue: std.ArrayList([]u8),
ctx: Context,

const MAX_QUEUE_SIZE = 10_000;

pub fn init(ctx: Context) Crawler {
    return Crawler{
        .ctx = ctx,
        .visited = std.StringHashMap(void).init(ctx.alloc),
        .queue = std.ArrayList([]u8).init(ctx.alloc),
    };
}

pub fn deinit(self: *Crawler) void {
    var it = self.visited.iterator();
    while (it.next()) |entry| self.ctx.alloc.free(entry.key_ptr.*);
    self.visited.deinit();

    for (self.queue.items) |url| self.ctx.alloc.free(url);
    self.queue.deinit();
}

pub fn appendQ(self: *Crawler, url: []const u8) !void {
    if(self.visited.contains(url)) return;
    const normalized = try normalizeUrl("https://", url, self.ctx.alloc);
    try self.queue.append(normalized);
}

fn normalizeUrl(base_scheme: []const u8, url: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
        return allocator.dupe(u8, url);
    } else if (std.mem.startsWith(u8, url, "//")) {
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ base_scheme, url });
    } else {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base_scheme, url });
    }
}

pub fn loadVisited(self: *Crawler, storage: *Storage) !void {
    const urls = try storage.getVisited();
    for (urls) |u| {
        try self.visited.put(u, {});
    }
}

pub fn loadQueue(self: *Crawler, storage: *Storage) !void {
    const urls = try storage.getQueue();
    std.debug.print("Loading", .{});
    for (urls, 0..) |u, i| {
        if(i % 1000 == 0) 
            std.debug.print(".", .{});
        try self.appendQ(u);
    }
    std.debug.print("\n", .{});
}

pub fn crawl(self: *Crawler, max_pages: ?usize, sigint: *bool) !void {
    var crawled: usize = 0;

    var logger = self.ctx.logger;
    var storage = try Storage.init(self.ctx);
    defer storage.deinit();

    while ((max_pages == null) or (self.queue.items.len > 0 and crawled < max_pages.?)) {
        if (sigint.*) {
            std.debug.print("SIGINT caught — stopping crawl\n", .{});
            break;
        }

        const url = self.queue.orderedRemove(0);
        defer self.ctx.alloc.free(url);

        if (self.visited.contains(url)) {
            try logger.INFO("{s} already visited", .{url});
            self.ctx.alloc.free(url);
            continue;
        }

        try self.visited.put(try self.ctx.alloc.dupe(u8, url), {});
        try logger.INFO("Crawling: {s}", .{url});

        const without_scheme = url["https://".len..];
        const slash_index = std.mem.indexOfScalar(u8, without_scheme, '/') orelse without_scheme.len;
        const host = without_scheme[0..slash_index];
        const path = if (slash_index < without_scheme.len)
            without_scheme[slash_index..]
        else
            "/";

        var parser = Parser.init(self.ctx, host, 443);
        parser.path = path;
        defer parser.deinit();

        const page = parser.parse() catch |err| {
            try logger.ERRO("Failed to parse {s}: {}\n", .{url, err});
            try storage.removePage(url);
            continue;
        };

        for (page.links) |link| {
            const normalized = normalizeUrl(host, link, self.ctx.alloc) catch continue;
            if (!self.visited.contains(normalized)) {
                try self.queue.append(normalized);
            } else {
                self.ctx.alloc.free(normalized);
            }
        }

        Parser.printPage(page);
        storage.store(page) catch |err| {
            try logger.ERRO("Could not store page: {}", .{err});
            continue;
        };

        crawled += 1;
    }
}

pub fn crawlOne(self: *Crawler, url: []const u8) !Page {
    if (self.visited.contains(url)) return error.AlreadyVisitedPage;

    var logger = self.ctx.logger;

    try self.visited.put(try self.ctx.alloc.dupe(u8, url), {});
    try logger.INFO("Crawling: {s}", .{url});

    const without_scheme = url["https://".len..];
    const slash_index = std.mem.indexOfScalar(u8, without_scheme, '/') orelse without_scheme.len;
    const host = without_scheme[0..slash_index];
    const path = if (slash_index < without_scheme.len)
        without_scheme[slash_index..]
    else
        "/";

    var parser = Parser.init(self.ctx, host, 443);
    parser.path = path;
    defer parser.deinit();

    const page = try parser.parse();

    for (page.links) |link| {
        const normalized = normalizeUrl(host, link, self.ctx.alloc) catch continue;
        if (!self.visited.contains(normalized)) {
            try self.queue.append(normalized);
        } else {
            self.ctx.alloc.free(normalized);
        }
    }

    Parser.printPage(page);
    return page;
}

const Queue = struct {
    list: *std.ArrayList([]u8),
    mutex: std.Thread.Mutex,
};

const WorkerArgs = struct {
    id: usize,
    queue: *Queue,
    depth: usize = 0, // unused but might be useful
    sigint: *bool,
    ctx: Context,
    storage: *Storage,
};

pub fn spawnAndRun(ctx: Context, worker_count: usize, received_sigint: *bool) !void {
    const allocator = ctx.alloc;
    var logger = ctx.logger;
    var storage = try Storage.init(ctx);
    defer storage.deinit();

    const initial_urls = try storage.getQueue();
    if (initial_urls.len < worker_count) {
        return error.NotEnoughSeeds;
    }

    const split = try splitQueue(initial_urls, worker_count, allocator);
    defer for (split) |*s| s.deinit();

    var queues = try allocator.alloc(Queue, worker_count);
    defer allocator.free(queues);

    for (split, 0..) |*list, i| {
        queues[i] = Queue{
            .list = list,
            .mutex = .{},
        };
    }

    var threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    for (queues, 0..) |*q, i| {
        threads[i] = try std.Thread.spawn(.{}, worker, .{
            WorkerArgs{
                .id = i,
                .queue = q,
                .sigint = received_sigint,
                .ctx = ctx,
                .storage = &storage,
            },
        });
    }

    for (threads) |t| t.join();

    try storage.emptyQueue();
    for (queues, 0..) |q, i| {
        try logger.INFO("Saving queue #{}...", .{i});
        try storage.saveQueue(q.list.*);
    }
}

fn splitQueue(urls: [][]const u8, parts: usize, allocator: std.mem.Allocator) ![]std.ArrayList([]u8) {
    var result = try allocator.alloc(std.ArrayList([]u8), parts);
    for (result) |*list| list.* = std.ArrayList([]u8).init(allocator);

    for (urls, 0..) |url, i| {
        try result[i % parts].append(try allocator.dupe(u8, url));
    }

    return result;
}

fn worker(args: WorkerArgs) void {
    const ctx = args.ctx;
    var crawler = Crawler.init(ctx);
    defer crawler.deinit();

    const queue = args.queue;
    const storage = args.storage;
    const sigint = args.sigint;

    while (!sigint.*) {
        queue.mutex.lock();
        const url = queue.list.orderedRemove(0);
        queue.mutex.unlock();

        if (crawler.visited.contains(url)) {
            ctx.alloc.free(url);
            continue;
        }

        const page = crawler.crawlOne(url) catch {
            ctx.alloc.free(url);
            continue;
        };

        storage.store(page) catch continue;

        for (crawler.queue.items) |found| {
            queue.mutex.lock();
            queue.list.append(found) catch {};
            queue.mutex.unlock();
        }
        crawler.queue.clearRetainingCapacity();

        ctx.alloc.free(url);
    }
}

pub fn printQueue(self: *Crawler) void {
    for (self.queue.items) |item| {
        std.debug.print("{s}\n", .{item});
    }
}
