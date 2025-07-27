const std = @import("std");
const Parser = @This();

const agent = "search/0.0.1";

host: []const u8,
port: u16,
path: []const u8 = "/",
alloc: std.mem.Allocator,
headers: std.StringHashMap([]u8),
body: std.ArrayList(u8),
links: std.ArrayList([]u8),

pub const Page = struct {
    url: []const u8,
    title: []const u8,
    keywords: []const u8,
    description: []const u8,
    body: []const u8,
    links: [][]u8,
};
pub fn printPage(page: Page) void {
    std.debug.print("URL: {s}\n", .{page.url});
    std.debug.print("Title: {s}\n", .{page.title});
    std.debug.print("Keywords: {s}\n", .{page.keywords});
    std.debug.print("Description: {s}\n", .{page.description});
    std.debug.print("Links: {}\n", .{page.links.len});
    for (page.links) |link| {
        std.debug.print("    {s}\n", .{link});
    }
}

pub fn init(alloc: std.mem.Allocator, host: []const u8, port: u16) Parser {
    return Parser{
        .host = host,
        .port = port,
        .path = "/",
        .alloc = alloc,
        .headers = std.StringHashMap([]u8).init(alloc),
        .body = std.ArrayList(u8).init(alloc),
        .links = std.ArrayList([]u8).init(alloc),
    };
}

pub fn deinit(self: *Parser) void {
    var it = self.headers.iterator();
    while (it.next()) |entry| {
        self.alloc.free(entry.key_ptr.*);
        self.alloc.free(entry.value_ptr.*);
    }
    self.headers.deinit();
    self.body.deinit();

    for (self.links.items) |link| self.alloc.free(link);
    self.links.deinit();
}

pub fn parse(self: *Parser) !?Page {
    var tcp = std.net.tcpConnectToHost(self.alloc, self.host, self.port) catch |err| switch (err) {
        error.InvalidIPAddressFormat => return null,
        else => return err,
    };
    defer tcp.close();

    const tls_config = std.crypto.tls.Client.Options{
        .ca = .no_verification,
        .host = .no_verification,
    };

    var tls_client = try std.crypto.tls.Client.init(tcp, tls_config);

    const request_fmt =
        "GET {s} HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "User-Agent: " ++ agent ++ "\r\n" ++
        "Connection: close\r\n\r\n";

    var request_buf: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buf, request_fmt, .{self.path, self.host});
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

            const body_start = end_index + end_seq.len;
            const body_remainder = header_buf.items[body_start..];
            try self.body.appendSlice(body_remainder);

            if (self.headers.get("Content-Length")) |len_str| {
                const content_length = try std.fmt.parseInt(usize, len_str, 10);
                var received = body_remainder.len;

                while (received < content_length) {
                    const to_read = @min(content_length - received, chunk.len);
                    const size = tls_client.read(tcp, chunk[0..to_read]) catch |err| switch (err) {
                        error.TlsConnectionTruncated => 0,
                        else => return err,
                    };
                    if (size == 0) break;
                    received += size;
                    try self.body.appendSlice(chunk[0..size]);
                }
            } else {
                while (true) {
                    const size = tls_client.read(tcp, &chunk) catch |err| switch (err) {
                        error.TlsConnectionTruncated => 0,
                        else => return err,
                    };
                    if (size == 0) break;
                    try self.body.appendSlice(chunk[0..size]);
                }
            }

            break;
        }
    }

    for (self.links.items) |link| self.alloc.free(link);
    self.links.deinit();
    self.links = try self.extractLinks();

    const links_slice = try self.links.toOwnedSlice();
    var page_links = std.ArrayList([]u8).init(self.alloc);

    defer page_links.deinit();

    // Deep copy each link string so `Page` owns its own copies.
    for (links_slice) |link| {
        const copy = try self.alloc.dupe(u8, link);
        try page_links.append(copy);
    }

    // Now build Page with owned links:
    return Page{
        .url = try std.fmt.allocPrint(self.alloc, "https://{s}{s}", .{self.host, self.path}),
        .title = try self.extractTitle(),
        .keywords = try self.extractMeta("keywords"),
        .description = try self.extractMeta("description"),
        .body = try self.body.toOwnedSlice(),
        .links = try page_links.toOwnedSlice(),
    };
}

fn extractTitle(self: *Parser) ![]const u8 {
    const start_tag = "<title>";
    const end_tag = "</title>";

    const start = std.mem.indexOf(u8, self.body.items, start_tag) orelse return "";
    const end = std.mem.indexOf(u8, self.body.items, end_tag) orelse return "";

    const title_start = start + start_tag.len;
    if (title_start >= end) return "";

    return try self.alloc.dupe(u8, self.body.items[title_start..end]);
}

fn extractMeta(self: *Parser, name: []const u8) ![]const u8 {
    const pattern = try std.fmt.allocPrint(self.alloc, "<meta name=\"{s}\" content=\"", .{name});
    defer self.alloc.free(pattern);

    const start = std.mem.indexOf(u8, self.body.items, pattern) orelse return "";
    const after = self.body.items[start + pattern.len..];

    const end_quote = std.mem.indexOfScalar(u8, after, '"') orelse return "";
    return try self.alloc.dupe(u8, after[0..end_quote]);
}

fn extractLinks(self: *Parser) !std.ArrayList([]u8) {
    var links = std.ArrayList([]u8).init(self.alloc);

    const pattern = "href=\"";
    var i: usize = 0;

    while (i < self.body.items.len) {
        const remaining = self.body.items[i..];
        const href_pos = std.mem.indexOf(u8, remaining, pattern);
        if (href_pos == null) {
            break;
        }

        i += href_pos.? + pattern.len;

        const after_href = self.body.items[i..];
        const quote_pos = std.mem.indexOfScalar(u8, after_href, '"');
        if (quote_pos == null) break;

        const url = after_href[0..quote_pos.?];

        if (std.mem.startsWith(u8, url, "javascript:") or std.mem.startsWith(u8, url, "mailto:")) {
            i += quote_pos.? + 1;
            continue;
        }

        const url_copy = try self.alloc.dupe(u8, url);
        try links.append(url_copy);

        i += quote_pos.? + 1;
    }

    return links;
}

pub fn printHeaders(self: *Parser) void {
    var it = self.headers.iterator();
    while (it.next()) |entry| {
        std.debug.print("{s}: {s}\n", .{entry.key_ptr.*, entry.value_ptr.*});
    }
}

pub fn printBody(self: *Parser) !void {
    std.debug.print("{s}\n", .{try self.body.toOwnedSlice()});
}

pub fn printLinks(self: *Parser) void {
    std.debug.print("Count: {}\n", .{self.links.items.len});
    for (self.links.items) |link| std.debug.print("- {s}\n", .{link});
}
