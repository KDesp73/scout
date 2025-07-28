const std = @import("std");
const os = std.os;
const Parser = @import("parser.zig");
const Crawler = @import("crawler.zig");
const Storage = @import("storage.zig");
const c = @cImport({
    @cInclude("signal.h");
});
const cli = @import("cli");

var received_sigint = false;
fn sigintHandler(_: c_int) callconv(.C) void {
    received_sigint = true;
}

var config = struct {
    seed: ?[]const u8 = null,
    depth: u8 = 20,
}{};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const alloc = gpa.allocator();

fn parseArgs(allocator: std.mem.Allocator) cli.AppRunner.Error!cli.ExecFn {
    var r = try cli.AppRunner.init(allocator);

    const app = cli.App{
        .command = cli.Command{
            .name = "search",
            .description = cli.Description{
                .one_line = "A cli search engine",
            },
            .target = cli.CommandTarget{
                .subcommands = try r.allocCommands(&.{
                    cli.Command{
                        .name = "crawl",
                        .description = cli.Description{
                            .one_line = "Run a crawler",
                        },
                        .options = try r.allocOptions(&.{
                            .{
                                .long_name = "seed",
                                .help = "Specify the seed hostname",
                                .value_ref = r.mkRef(&config.seed),
                                .required = false,
                                .value_name = "SEED",
                            },
                            .{
                                .long_name = "depth",
                                .help = "The max depth the crawler can reach",
                                .value_ref = r.mkRef(&config.depth),
                                .value_name = "INT",
                                .required = false,
                            },
                        }),
                        .target = cli.CommandTarget{
                            .action = .{ .exec = crawlCommand }
                        },
                    },
                    cli.Command {
                        .name = "parse",
                        .description = cli.Description {
                            .one_line = "Run the parser"
                        },
                        .options = try r.allocOptions(&.{
                            .{
                                .long_name = "host",
                                .help = "Specify the host to parse",
                                .value_ref = r.mkRef(&config.seed),
                                .value_name = "HOST",
                                .required = true
                            }
                        }),
                        .target = cli.CommandTarget {
                            .action = .{ .exec = parseCommand }
                        },
                    },
                }),
            },
        },
        .version = "0.0.1",
        .author = "KDesp73",
    };

    return r.getAction(&app);
}

pub fn main() anyerror!void {
    _ = c.signal(c.SIGINT, sigintHandler);

    const action = try parseArgs(alloc);
    const r = action();

    if(config.seed != null)
        alloc.free(config.seed.?);

    return r;
}

pub fn crawlCommand() !void {
    var storage = try Storage.init(alloc);
    defer storage.deinit();

    var crawler = Crawler.init(alloc);
    defer crawler.deinit();

    try crawler.loadVisited(&storage);

    if(config.seed) |s| {
        try crawler.appendQ(s);
    } else {
        try crawler.loadQueue(&storage);
    }

    try crawler.crawl(config.depth, &received_sigint);

    std.debug.print("Saving queue...\n", .{});
    try storage.emptyQueue();
    try storage.saveQueue(crawler.queue);
}

pub fn parseCommand() !void {
    var parser = Parser.init(alloc, config.seed.?, 443);
    defer parser.deinit();
    const page = try parser.parse();

    parser.printHeaders();
    std.debug.print("\n", .{});
    Parser.printPage(page.?);
    std.debug.print("\n", .{});
}
