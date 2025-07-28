const std = @import("std");
const Storage = @This();
const Page = @import("parser.zig").Page;
const sqlite = @import("sqlite");

const DB_PATH = "data/search.db";

db: sqlite.Db,
alloc: std.mem.Allocator,

pub fn init(alloc: std.mem.Allocator) !Storage {
    return Storage {
        .alloc = alloc,
        .db = try sqlite.Db.init(.{
            .mode = sqlite.Db.Mode{ .File = DB_PATH },
            .open_flags = .{
                .write = true,
                .create = true,
            },
            .threading_mode = .MultiThread,
        }),
    };
}

pub fn deinit(self: *Storage) void {
    self.db.deinit();
}

pub fn store(self: *Storage, page: Page) !void {
    const query =
    \\INSERT INTO Pages(title, description, keywords, url) VALUES(?, ?, ?, ?)
    ;

    var stmt = try self.db.prepare(query);
    defer stmt.deinit();

    stmt.exec(.{}, .{
        .title = page.title,
        .description = page.description,
        .keywords = page.keywords,
        .url = page.url
    }) catch |err| switch (err) {
        error.SQLiteConstraint => return,
        else => return err
    };
}

pub fn getVisited(self:* Storage) ![][]const u8 {
    const query =
    \\SELECT url FROM Pages
    ;

    var stmt = try self.db.prepare(query);
    defer stmt.deinit();

    const urls = try stmt.all([]const u8, self.alloc, .{}, .{});
    return urls;
}

pub fn emptyQueue(self: *Storage) !void {
    const query =
    \\DELETE FROM Queue
    ;

    var stmt = try self.db.prepare(query);
    defer stmt.deinit();

    try stmt.exec(.{}, .{});
}

pub fn saveQueue(self: *Storage, queue: std.ArrayList([]u8)) !void {

    const query =
    \\INSERT INTO Queue(url) VALUES(?)
    ;

    var stmt = try self.db.prepare(query);
    defer stmt.deinit();

    for(queue.items) |url| {
        try stmt.exec(.{}, .{
            .url = url
        });
        stmt.reset();
    }
}

pub fn getQueue(self: *Storage) ![][]const u8 {
    const query =
    \\SELECT url FROM Queue
    ;

    var stmt = try self.db.prepare(query);
    defer stmt.deinit();

    const urls = try stmt.all([]const u8, self.alloc, .{}, .{});
    return urls;
}
