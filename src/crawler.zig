const std = @import("std");
const Parser = @import("parser.zig");

const Crawler = @This();

alloc: std.mem.Allocator,
visited: std.StringHashMap(void),

pub fn init(alloc: std.mem.Allocator) Crawler{
    return Crawler {
        .alloc = alloc,
        .visited = std.StringHashMap(void).init(alloc)
    };
}

pub fn deinit(self: *Crawler) void {
    var it = self.visited.iterator();
    while (it.next()) |entry| self.alloc.free(entry.key_ptr.*);
    self.visited.deinit();
}

fn normalizeUrl(base: []const u8, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) {
        return allocator.dupe(u8, path);
    }

    return try std.fmt.allocPrint(allocator, "https://{s}{s}", .{base, path});
}

pub fn crawl(self: *Crawler, seed: []const u8, max_depth: usize) !void {
    var queue = std.ArrayList([]u8).init(self.alloc);
    defer {
        for (queue.items) |url| self.alloc.free(url);
        queue.deinit();
    }

    try queue.append(try self.alloc.dupe(u8, seed));
    var current_depth: usize = 0;

    while (queue.items.len > 0 and current_depth < max_depth) {
        const url = queue.orderedRemove(0);

        if (self.visited.contains(url)) {
            self.alloc.free(url);
            continue;
        }

        try self.visited.put(try self.alloc.dupe(u8, url), {});
        std.debug.print("Crawling: {s}\n", .{url});

        // Extract host and path from URL
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

        parser.parse() catch |err| {
            std.debug.print("Failed to parse {s}: {}\n", .{url, err});
            continue;
        };


        for (parser.links.items) |link| {
            const normalized = normalizeUrl(host, link, self.alloc) catch continue;
            if (!self.visited.contains(normalized)) {
                try queue.append(normalized);
            } else {
                self.alloc.free(normalized);
            }
        }

        self.alloc.free(url);
        current_depth += 1;
    }
}
