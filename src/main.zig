const std = @import("std");
const Parser = @import("parser.zig");
const Crawler = @import("crawler.zig");
const Storage = @import("storage.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var storage = try Storage.init(alloc);
    defer storage.deinit();

    var crawler = Crawler.init(alloc);
    defer crawler.deinit();

    std.debug.print("Loading pages and queue...\n", .{});
    try crawler.load(&storage);

    try crawler.crawl(20);

    std.debug.print("Saving queue...\n", .{});
    try storage.emptyQueue();
    try storage.saveQueue(crawler.queue);
}
