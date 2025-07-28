const std = @import("std");
const Storage = @This();
const Page = @import("parser.zig").Page;
const sqlite = @import("sqlite");

const DB_PATH = "data/search.db";

db: sqlite.Db,
alloc: std.mem.Allocator,

pub fn init(alloc: std.mem.Allocator) !Storage {
    const self = Storage {
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

    // https://sqlite.org/loadext.html#build
    const c = sqlite.c;

    if(c.sqlite3_enable_load_extension(self.db.db, 1) != c.SQLITE_OK) {
        std.log.err("Could not enable loading extensions", .{});
        return error.SQLiteError;
    }

    const err_msg: [*c][*c]u8 = null;
    const rc = c.sqlite3_load_extension(
        self.db.db,
        "./exts/fts5.so",
        null,
        err_msg
    );

    if (rc != c.SQLITE_OK) {
        if(err_msg != null){
            std.log.err("Failed to load extension: {s}", .{err_msg.?.*});
        }
        return error.SQLiteError;
    }

    return self;
}

pub fn deinit(self: *Storage) void {
    self.db.deinit();
}

pub fn store(self: *Storage, page: Page) !void {
    try self.db.exec("BEGIN TRANSACTION;", .{}, .{});

    const insert_pages_query =
        \\INSERT OR IGNORE INTO Pages(title, description, keywords, content, host, url)
        \\VALUES (?, ?, ?, ?, ?, ?);
    ;

    var insert_pages_stmt = try self.db.prepare(insert_pages_query);
    defer insert_pages_stmt.deinit();

    const host = blk: {
        const url = page.url;
        if (std.mem.startsWith(u8, url, "https://")) {
            const without_scheme = url["https://".len..];
            const slash_index = std.mem.indexOfScalar(u8, without_scheme, '/') orelse without_scheme.len;
            break :blk without_scheme[0..slash_index];
        } else if (std.mem.startsWith(u8, url, "http://")) {
            const without_scheme = url["http://".len..];
            const slash_index = std.mem.indexOfScalar(u8, without_scheme, '/') orelse without_scheme.len;
            break :blk without_scheme[0..slash_index];
        } else {
            break :blk "";
        }
    };

    try insert_pages_stmt.exec(.{}, .{
        page.title,
        page.description,
        page.keywords,
        page.body,
        host,
        page.url,
    });

    const delete_fts_query = "DELETE FROM PageIndex WHERE url = ?;";
    var diags = sqlite.Diagnostics{};
    var delete_fts_stmt = self.db.prepareWithDiags(delete_fts_query, .{ .diags = &diags }) catch |err| {
        std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
        return err;
    };
    defer delete_fts_stmt.deinit();

    try delete_fts_stmt.exec(.{}, .{page.url});

    const insert_fts_query =
    \\INSERT INTO PageIndex(title, description, keywords, content, url)
    \\VALUES (?, ?, ?, ?, ?);
    ;

    var insert_fts_stmt = self.db.prepareWithDiags(insert_fts_query, .{ .diags = &diags }) catch |err| {
        std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
        return err;
    };
    defer insert_fts_stmt.deinit();

    try insert_fts_stmt.exec(.{}, .{
        page.title,
        page.description,
        page.keywords,
        page.body,
        page.url,
    });

    try self.db.exec("COMMIT;", .{}, .{});
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
    try self.db.exec("BEGIN TRANSACTION;", .{}, .{});

    const query =
    \\INSERT INTO Queue(url) VALUES(?)
    ;

    var stmt = try self.db.prepare(query);
    defer stmt.deinit();

    for (queue.items) |url| {
        stmt.exec(.{}, .{ .url = url }) catch |err| {
            std.log.err("{}", .{err});
        };
        stmt.reset();
    }

    try self.db.exec("COMMIT;", .{}, .{});
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
