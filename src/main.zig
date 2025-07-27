const std = @import("std");
const Parser = @import("parser.zig");
const Crawler = @import("crawler.zig");

pub fn main() !void {
    const hostname = "https://kdesp73.github.io";

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var crawler = Crawler.init(alloc);
    defer crawler.deinit();
    try crawler.crawl(hostname, 10);
}
