const std = @import("std");
const os = std.os;
const Parser = @import("parser.zig");
const Crawler = @import("crawler.zig");
const Storage = @import("storage.zig");
const c = @cImport({
    @cInclude("signal.h");
});


var received_sigint = false;
fn sigintHandler(_: c_int) callconv(.C) void {
    received_sigint = true;
}

pub fn main() !void {
    _ = c.signal(c.SIGINT, sigintHandler);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var storage = try Storage.init(alloc);
    defer storage.deinit();

    var crawler = Crawler.init(alloc);
    defer crawler.deinit();

    std.debug.print("Loading pages and queue...\n", .{});
    try crawler.load(&storage);

    try crawler.crawl(20, &received_sigint);

    std.debug.print("Saving queue...\n", .{});
    try storage.emptyQueue();
    try storage.saveQueue(crawler.queue);
}
