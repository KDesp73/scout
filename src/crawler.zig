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
    }

    const full_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_scheme, url });

    return full_url;
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

pub fn crawl(self: *Crawler, max_pages: usize, sigint: *bool) !void {
    var crawled: usize = 0;

    while (self.queue.items.len > 0 and crawled < max_pages) {
        if (self.queue.items.len >= MAX_QUEUE_SIZE) break;

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
        var storage = try Storage.init(self.alloc);
        try storage.store(page.?);

        self.alloc.free(url);
        crawled += 1;
    }
}

pub fn printQueue(self: *Crawler) void {
    for (self.queue.items) |item| {
        std.debug.print("{s}\n", .{item});
    }
}
