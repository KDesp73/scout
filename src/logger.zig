const std = @import("std");

const Logger = @This();

pub const Level = enum(u8) {
    INFO = 0,
    WARN = 1,
    ERROR = 2,
};

level: Level = .INFO,
fdout: std.fs.File,
log2file: bool,
alloc: std.mem.Allocator,
outfile: ?[]const u8 = null,
file: ?std.fs.File = null,

pub fn init(alloc: std.mem.Allocator, lvl: Level, fdout: std.fs.File, log2file: bool) Logger {
    var logger = Logger{
        .level = lvl,
        .fdout = fdout,
        .log2file = log2file,
        .alloc = alloc,
    };

    if (log2file) {
        var buf: [128]u8 = undefined;
        const ts = std.time.timestamp();
        const name = std.fmt.bufPrint(&buf, "log-{d}.txt", .{ts}) catch {
            std.log.err("Could not initialize outfile name", .{});
            return logger;
        };

        logger.outfile = alloc.dupe(u8, name) catch { return logger; };
        logger.file = std.fs.cwd().createFile(logger.outfile.?, .{
            .read = false,
        }) catch {
            std.log.err("Could not open file for writing", .{});
            return logger;
        };
    }

    return logger;
}

pub fn deinit(self: *Logger) void {
    if (self.file) |*f| {
        f.close();
    }
    if (self.outfile) |name| {
        self.alloc.free(name);
    }
}

pub fn log(self: *Logger, lvl: Level, comptime fmt: []const u8, args: anytype) !void {
    if (@intFromEnum(lvl) < @intFromEnum(self.level)) return;

    switch (lvl) {
        .INFO => try self.INFO(fmt, args),
        .WARN => try self.WARN(fmt, args),
        .ERROR => try self.ERROR(fmt, args),
    }
}

fn LOG(self: *Logger, tag: []const u8, comptime fmt: []const u8, args: anytype) !void {
    // Always print to main output
    var writer = self.fdout.writer();
    try writer.print("[{s}] ", .{tag});
    try writer.print(fmt, args);
    try writer.print("\n", .{});

    // Also write to file if enabled
    if (self.log2file) {
        if (self.file) |*file| {
            var file_writer = file.writer();
            try file_writer.print("[{s}] ", .{tag});
            try file_writer.print(fmt, args);
            try file_writer.print("\n", .{});
        }
    }
}

pub fn INFO(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
    try self.LOG("INFO", fmt, args);
}

pub fn WARN(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
    try self.LOG("WARN", fmt, args);
}

pub fn ERRO(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
    try self.LOG("ERRO", fmt, args);
}

pub fn TODO(self: *Logger, comptime fmt: []const u8, args: anytype) noreturn {
    self.LOG("TODO", fmt, args) catch {};
    std.os.exit(1);
}

pub fn printfln(comptime fmt: []const u8, args: anytype) !void {
    var writer = std.io.getStdOut().writer();
    try writer.print(fmt, args);
    try writer.print("\n", .{});
}
