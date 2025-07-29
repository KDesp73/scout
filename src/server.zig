const std = @import("std");
const net = std.net;
const Storage = @import("storage.zig");

const INDEX_HTML = @embedFile("site/index.html");
const RESULTS_HTML = @embedFile("site/results.html");

fn handleConnection(conn: net.Server.Connection, storage: *Storage) !void {
    defer conn.stream.close();

    var buffer: [2048]u8 = undefined;
    const len = try conn.stream.read(&buffer);
    const request = buffer[0..len];

    if (std.mem.startsWith(u8, request, "GET /search?query=")) {
        const query_marker = "query=";
        const query_pos = std.mem.indexOf(u8, request, query_marker) orelse return;
        const query_start = query_pos + query_marker.len;

        const query_end_opt = std.mem.indexOfScalar(u8, request[query_start..], ' ');
        const query_end = query_end_opt orelse request.len - query_start;
        const query_raw = request[query_start .. query_start + query_end];
        const query = std.mem.trim(u8, query_raw, "& ");

        const results = try storage.search(query);

        var list_buf = std.ArrayList(u8).init(std.heap.page_allocator);
        defer list_buf.deinit();

        var lw = list_buf.writer();
        for (results) |res| {
            try lw.print(
                "<li><a href=\"{s}\">{s}</a></li>\n", .{res.url, res.title}
            );
        }

        const result_list = try list_buf.toOwnedSlice();

        var html = try std.mem.replaceOwned(
            u8,
            std.heap.page_allocator,
            RESULTS_HTML,
            "{{results}}",
            result_list
        );
        std.heap.page_allocator.free(result_list);

        const new_html = try std.mem.replaceOwned(u8, std.heap.page_allocator, html, "{{query}}", query);
        std.heap.page_allocator.free(html);
        html = new_html;

        var writer = conn.stream.writer();
        try writer.print(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            .{html.len}
        );
        try writer.writeAll(html);

        std.heap.page_allocator.free(html);
        return;
    }

    // default response — send index.html
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
