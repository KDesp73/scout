const std = @import("std");
const Parser = @import("parser.zig");
const Page = Parser.Page;
const Storage = @import("storage.zig");

const Crawler = @This();

alloc: std.mem.Allocator,
visited: std.StringHashMap(void),
queue: std.ArrayList([]u8),

const MAX_QUEUE_SIZE = 10_000;

pub fn init(alloc: std.mem.Allocator) Crawler {
    return Crawler{
        .alloc = alloc,
        .visited = std.StringHashMap(void).init(alloc),
        .queue = std.ArrayList([]u8).init(alloc),
    };
}

pub fn deinit(self: *Crawler) void {
    var it = self.visited.iterator();
    while (it.next()) |entry| self.alloc.free(entry.key_ptr.*);
    self.visited.deinit();

    for (self.queue.items) |url| self.alloc.free(url);
    self.queue.deinit();
}

pub fn appendQ(self: *Crawler, url: []const u8) !void {
    if(self.visited.contains(url)) return;
    const normalized = try normalizeUrl("https://", url, self.alloc);
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
    for (urls) |u| {
        try self.appendQ(u);
    }
}

pub fn crawl(self: *Crawler, max_pages: ?usize, sigint: *bool) !void {
    var crawled: usize = 0;

    var storage = try Storage.init(self.alloc);
    defer storage.deinit();

    while ((max_pages == null) or (self.queue.items.len > 0 and crawled < max_pages.?)) {
        if (sigint.*) {
            std.debug.print("SIGINT caught — stopping crawl\n", .{});
            break;
        }

        const url = self.queue.orderedRemove(0);

        if (self.visited.contains(url)) {
            self.alloc.free(url);
            continue;
        }

        try self.visited.put(try self.alloc.dupe(u8, url), {});
        std.debug.print("Crawling: {s}\n", .{url});

        const without_scheme = url["https://".len..];
        const slash_index = std.mem.indexOfScalar(u8, without_scheme, '/') orelse without_scheme.len;
        const host = without_scheme[0..slash_index];
        const path = if (slash_index < without_scheme.len)
            without_scheme[slash_index..]
        else
            "/";

        var parser = Parser.init(self.alloc, host, 443);
        parser.path = path;
        defer parser.deinit();

        const page = parser.parse() catch |err| {
            std.debug.print("Failed to parse {s}: {}\n", .{url, err});
            self.alloc.free(url);
            continue;
        };

        for (page.?.links) |link| {
            const normalized = normalizeUrl(host, link, self.alloc) catch continue;
            if (!self.visited.contains(normalized)) {
                try self.queue.append(normalized);
            } else {
                self.alloc.free(normalized);
            }
        }

        Parser.printPage(page.?);
        try storage.store(page.?);

        self.alloc.free(url);
        crawled += 1;
    }
    
}

pub fn crawlOne(self: *Crawler, url: []const u8) !?Page {
    if (self.visited.contains(url)) {
        return null;
    }

    try self.visited.put(try self.alloc.dupe(u8, url), {});
    std.debug.print("Crawling: {s}\n", .{url});

    const without_scheme = url["https://".len..];
    const slash_index = std.mem.indexOfScalar(u8, without_scheme, '/') orelse without_scheme.len;
    const host = without_scheme[0..slash_index];
    const path = if (slash_index < without_scheme.len)
        without_scheme[slash_index..]
    else
        "/";

    var parser = Parser.init(self.alloc, host, 443);
    parser.path = path;
    defer parser.deinit();

    const page = try parser.parse();

    for (page.?.links) |link| {
        const normalized = normalizeUrl(host, link, self.alloc) catch continue;
        if (!self.visited.contains(normalized)) {
            try self.queue.append(normalized);
        } else {
            self.alloc.free(normalized);
        }
    }

    Parser.printPage(page.?);
    return page;
}

const Queue = struct {
    list: *std.ArrayList([]u8),
    mutex: std.Thread.Mutex,
};

const WorkerArgs = struct {
    id: usize,
    storage: *Storage,
    queue: *Queue,
    depth: usize = 0, // unused but might be useful
    allocator: std.mem.Allocator,
    sigint: *bool,
};

pub fn spawnAndRun(worker_count: usize, received_sigint: *bool) !void {
    const allocator = std.heap.page_allocator;

    var storage = try Storage.init(allocator);
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
                .storage = &storage,
                .allocator = allocator,
                .sigint = received_sigint,
            },
        });
    }

    for (threads) |t| t.join();

    try storage.emptyQueue();
    for (queues, 0..) |q, i| {
        std.log.info("Saving queue #{}...", .{i});
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
    const allocator = args.allocator;
    var crawler = Crawler.init(allocator);
    defer crawler.deinit();

    const queue = args.queue;
    const storage = args.storage;
    const sigint = args.sigint;

    while (!sigint.*) {
        queue.mutex.lock();
        const url = queue.list.orderedRemove(0);
        queue.mutex.unlock();

        if (crawler.visited.contains(url)) {
            allocator.free(url);
            continue;
        }

        const page = crawler.crawlOne(url) catch {
            allocator.free(url);
            continue;
        };

        if (page) |p| {
            storage.store(p) catch continue;

            for (crawler.queue.items) |found| {
                queue.mutex.lock();
                queue.list.append(found) catch {};
                queue.mutex.unlock();
            }
            crawler.queue.clearRetainingCapacity();
        }

        allocator.free(url);
    }
}

pub fn printQueue(self: *Crawler) void {
    for (self.queue.items) |item| {
        std.debug.print("{s}\n", .{item});
    }
}
