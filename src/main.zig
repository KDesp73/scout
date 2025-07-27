const std = @import("std");
const Parser = @import("parser.zig");

pub fn main() !void {
    const hostname = "kdesp73.github.io";
    const port = 443;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var parser = Parser.init(alloc, hostname, port);
    defer parser.deinit();

    try parser.parse();
    try parser.printHeaders();
}
