const std = @import("std");
const net = std.net;
const Storage = @import("storage.zig");

const INDEX_HTML = @embedFile("site/index.html");

fn handleConnection(conn: net.Server.Connection, storage: *Storage) !void {
    defer conn.stream.close();

    var buffer: [2048]u8 = undefined;
    const len = conn.stream.read(&buffer) catch return;

    const request = buffer[0..len];

    if (std.mem.startsWith(u8, request, "GET /search?query=")) {
        const query_marker = "query=";
        const query_pos = std.mem.indexOf(u8, request, query_marker) orelse return;
        const query_start = query_pos + query_marker.len;

        const query_end = std.mem.indexOfScalar(u8, request[query_start..], ' ') orelse request.len;
        const query_raw = request[query_start .. query_start + query_end];

        const query = std.mem.trim(u8, query_raw, "& ");

        const results = storage.search(query) catch return;

        var writer = conn.stream.writer();
        try writer.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n");

        try writer.writeByte('[');
        for (results, 0..) |res, i| {
            if (i != 0) try writer.writeByte(',');
            try writer.print("{{\"title\":\"{s}\",\"url\":\"{s}\"}}", .{ res.title, res.url });
        }
        try writer.writeByte(']');
        return;
    }

    var writer = conn.stream.writer();
    try writer.print(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        .{INDEX_HTML.len}
    );
    try writer.writeAll(INDEX_HTML);
}

pub fn serve(storage: *Storage, ip: []const u8, port: u16, sigint: *bool) !void {
    const address = try std.net.Address.parseIp(ip, port);
    
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    std.log.info("Listening on http://{s}:{}...", .{ ip, port });

    while (!sigint.*) {
        const conn = server.accept() catch |err| {
            std.log.err("Failed to accept connection: {}", .{err});
            continue;
        };

        const thread = std.Thread.spawn(.{}, handleConnection, .{ conn, storage }) catch |err| {
            std.log.err("Failed to spawn thread: {}", .{err});
            conn.stream.close();
            continue;
        };

        thread.detach();
    }

    std.log.info("Server shutting down...", .{});
}
