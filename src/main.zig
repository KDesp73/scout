const std = @import("std");
const Parser = @import("parser.zig");
const Crawler = @import("crawler.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var crawler = Crawler.init(alloc);
    defer crawler.deinit();
    try crawler.appendQ("https://iee.ihu.gr");
    try crawler.appendQ("https://kdesp73.github.io");
    try crawler.appendQ("https://github.com");

    try crawler.crawl(50);
}
