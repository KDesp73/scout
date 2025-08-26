const std = @import("std");
const Logger = @import("logger.zig");
const Storage = @import("storage.zig");

const Context = @This();

alloc: std.mem.Allocator,
logger: Logger,

pub fn init(alloc: std.mem.Allocator, logger: Logger) Context {
    return Context {
        .alloc = alloc,
        .logger = logger,
    };
}
