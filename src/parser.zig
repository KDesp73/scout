const std = @import("std");
const Parser = @This();

const agent = "search/0.0.1";

host: []const u8,
port: u16,
path: []const u8 = "/",
alloc: std.mem.Allocator,
headers: std.StringHashMap([]u8),

pub fn init(alloc: std.mem.Allocator, host: []const u8, port: u16) Parser {
    return Parser{
        .host = host,
        .port = port,
        .path = "/",
        .alloc = alloc,
        .headers = std.StringHashMap([]u8).init(alloc),
    };
}

pub fn deinit(self: *Parser) void {
    var it = self.headers.iterator();
    while (it.next()) |entry| {
        self.alloc.free(entry.key_ptr.*);
        self.alloc.free(entry.value_ptr.*);
    }
    self.headers.deinit();
}

pub fn parse(self: *Parser) !void {
    var tcp = try std.net.tcpConnectToHost(self.alloc, self.host, self.port);
    defer tcp.close();

    const tls_config = std.crypto.tls.Client.Options{
        .ca = .no_verification, // TODO: enable verification
        .host = .no_verification,
    };

    var tls_client = try std.crypto.tls.Client.init(tcp, tls_config);

    const request_fmt =
        "GET {s} HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "User-Agent: {s}\r\n" ++
        "Connection: close\r\n\r\n";

    var request_buf: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buf, request_fmt, .{self.path, self.host, agent});
    try tls_client.writeAll(tcp, request);

    var header_buf = std.ArrayList(u8).init(self.alloc);
    defer header_buf.deinit();

    const end_seq = "\r\n\r\n";

    while (true) {
        var chunk: [512]u8 = undefined;
        const n = tls_client.read(tcp, &chunk) catch |err| switch (err) {
            error.TlsConnectionTruncated => 0,
            else => return err,
        };
        if (n == 0) break;
        try header_buf.appendSlice(chunk[0..n]);

        if (std.mem.indexOf(u8, header_buf.items, end_seq)) |end_index| {
            const header_bytes = header_buf.items[0..end_index];
            var lines = std.mem.tokenizeAny(u8, header_bytes, "\r\n");
            _ = lines.next(); // skip status line

            while (lines.next()) |line| {
                if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                    const key = std.mem.trim(u8, line[0..colon], " ");
                    const value = std.mem.trim(u8, line[colon + 1..], " ");

                    const key_owned = try self.alloc.dupe(u8, key);
                    const value_owned = try self.alloc.dupe(u8, value);
                    try self.headers.put(key_owned, value_owned);
                }
            }

            // TODO: parse body after headers

            break;
        }
    }
}

pub fn printHeaders(self: *Parser) !void {
    var writer = std.io.getStdOut().writer();
    var it = self.headers.iterator();
    while (it.next()) |entry| {
        try writer.print("{s}: {s}\n", .{entry.key_ptr.*, entry.value_ptr.*});
    }
}
