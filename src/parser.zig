const std = @import("std");
const Context = @import("context.zig");

const Parser = @This();
const agent = "search/0.0.1";

host: []const u8,
port: u16,
path: []const u8 = "/",
headers: std.StringHashMap([]u8),
body: std.ArrayList(u8),
links: std.ArrayList([]u8),
ctx: Context,

pub const Page = struct {
    url: []const u8,
    title: []const u8,
    keywords: []const u8,
    description: []const u8,
    body: []const u8, // full body
    content: []const u8, // striped body
    links: [][]u8,
};
pub fn printPage(page: Page) void {
    std.debug.print("{s}\n", .{page.url});
    std.debug.print("  Title: {s}\n", .{page.title});
    std.debug.print("  Keywords: {s}\n", .{page.keywords});
    std.debug.print("  Description: {s}\n", .{page.description});
    std.debug.print("  Links: {}\n", .{page.links.len});
    for (page.links) |link| {
        std.debug.print("    {s}\n", .{link});
    }
    // std.debug.print("  Content: {s}\n", .{page.content});
}

pub fn init(ctx: Context, host: []const u8, port: u16) Parser {
    return Parser{
        .host = host,
        .port = port,
        .path = "/",
        .ctx = ctx,
        .headers = std.StringHashMap([]u8).init(ctx.alloc),
        .body = std.ArrayList(u8).init(ctx.alloc),
        .links = std.ArrayList([]u8).init(ctx.alloc),
    };
}

pub fn deinit(self: *Parser) void {
    var it = self.headers.iterator();
    while (it.next()) |entry| {
        self.ctx.alloc.free(entry.key_ptr.*);
        self.ctx.alloc.free(entry.value_ptr.*);
    }
    self.headers.deinit();
    self.body.deinit();

    for (self.links.items) |link| self.ctx.alloc.free(link);
    self.links.deinit();
}

fn isAllowedByRobots(self: *Parser) !bool {

    var tcp = try std.net.tcpConnectToHost(self.ctx.alloc, self.host, self.port);
    defer tcp.close();

    const tls_config = std.crypto.tls.Client.Options{
        .ca = .no_verification,
        .host = .no_verification,
    };

    var tls_client = try std.crypto.tls.Client.init(tcp, tls_config);

    const request = try std.fmt.allocPrint(self.ctx.alloc,
        \\GET /robots.txt HTTP/1.1\r\n
        \\Host: {s}\r\n
        \\User-Agent: {s}\r\n
        \\Connection: close\r\n
        \\Accept: */*\r\n\r\n
    , .{ self.host, agent });
    defer self.ctx.alloc.free(request);

    try tls_client.writeAll(tcp, request);

    var buffer = std.ArrayList(u8).init(self.ctx.alloc);
    defer buffer.deinit();

    while (true) {
        var chunk: [512]u8 = undefined;
        const n = tls_client.read(tcp, &chunk) catch |err| switch (err) {
            error.TlsConnectionTruncated => 0,
            else => return err,
        };
        if (n == 0) break;
        try buffer.appendSlice(chunk[0..n]);
    }

    const response = try buffer.toOwnedSlice();

    // If robots.txt not found, allow crawling
    if (!std.mem.containsAtLeast(u8, response, 1, "200 OK")) return true;

    var lines = std.mem.tokenizeAny(u8, response, "\r\n");
    var allow = true;
    var match_agent = false;

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "User-agent:")) {
            const value = std.mem.trim(u8, line["User-agent:".len..], " ");
            match_agent = std.mem.eql(u8, value, "*") or std.mem.eql(u8, value, agent);
        } else if (match_agent and std.mem.startsWith(u8, line, "Disallow:")) {
            const rule = std.mem.trim(u8, line["Disallow:".len..], " ");
            if (self.path.len >= rule.len and std.mem.startsWith(u8, self.path, rule)) {
                allow = false;
            }
        } else if (line.len == 0) {
            match_agent = false;
        }
    }

    return allow;
}

pub fn parse(self: *Parser) !Page {
    // FIXME: isAllowedByRobots hangs when reading response
    // const allowed = try self.isAllowedByRobots();
    // if (!allowed) {
    //     Logger.INFO("Blocked by robots.txt: {s}", .{self.path});
    //     return error.DisallowedByRobotsTxt;
    // }

    var tcp = try std.net.tcpConnectToHost(self.ctx.alloc, self.host, self.port);
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

    var header_buf = std.ArrayList(u8).init(self.ctx.alloc);
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
                    const key_owned = try self.ctx.alloc.dupe(u8, key);
                    const value_owned = try self.ctx.alloc.dupe(u8, value);
                    try self.headers.put(key_owned, value_owned);
                }
            }

            const body_start = end_index + end_seq.len;
            const body_remainder = header_buf.items[body_start..];
            try self.body.appendSlice(body_remainder);

            if (self.headers.get("Content-Type")) |tp| {
                const type_lc = try std.ascii.allocLowerString(self.ctx.alloc, tp);
                defer self.ctx.alloc.free(type_lc);

                if (!std.mem.startsWith(u8, type_lc, "text/html")) return error.InvalidContentType;
            }

            if (self.headers.get("Content-Length")) |len_str| {
                const content_length = try std.fmt.parseInt(usize, len_str, 10);
                if(content_length == 0) break;
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

    for (self.links.items) |link| self.ctx.alloc.free(link);
    self.links.deinit();
    self.links = try self.extractLinks();

    if(self.headers.get("Location")) |location| {
        try self.links.append(location);
    }

    const links_slice = try self.links.toOwnedSlice();
    var page_links = std.ArrayList([]u8).init(self.ctx.alloc);

    defer page_links.deinit();

    for (links_slice) |link| {
        const copy = try self.ctx.alloc.dupe(u8, link);
        try page_links.append(copy);
    }

    const title = try self.extractTitle();
    if(title.len == 0) return error.MissingTitle; // Do not accept pages without a title
    return Page{
        .url = try std.fmt.allocPrint(self.ctx.alloc, "https://{s}{s}", .{self.host, self.path}),
        .title = title,
        .keywords = try self.extractMeta("keywords"),
        .description = try self.extractMeta("description"),
        .content = try self.stripBody(),
        .body = try self.body.toOwnedSlice(),
        .links = try page_links.toOwnedSlice(),
    };
}

fn stripBody(self: *Parser) ![]const u8 {
    const start_tag = "<body";
    const end_tag = "</body>";

    const body_start_pos = std.mem.indexOf(u8, self.body.items, start_tag) orelse return "";
    const after_body_tag = self.body.items[body_start_pos..];
    const body_open_end = std.mem.indexOfScalar(u8, after_body_tag, '>') orelse return "";
    const content_start = body_start_pos + body_open_end + 1;

    const end_pos = std.mem.indexOf(u8, self.body.items, end_tag) orelse return "";
    if (content_start >= end_pos) return "";

    const inner = self.body.items[content_start..end_pos];

    const alloc = self.ctx.alloc;
    var text = std.ArrayList(u8).init(alloc);
    var i: usize = 0;
    var inside_tag = false;
    var skipping_script_or_style = false;
    var skipping_comment = false;

    while (i < inner.len) {
        if (!inside_tag and inner[i] == '<') {
            inside_tag = true;

            // Check for comment
            if (std.mem.startsWith(u8, inner[i..], "<!--")) {
                skipping_comment = true;
            }

            // Check for <script> or <style>
            if (std.mem.startsWith(u8, inner[i..], "<script") or std.mem.startsWith(u8, inner[i..], "<style")) {
                skipping_script_or_style = true;
            }
            i += 1;
            continue;
        }

        if (inside_tag and inner[i] == '>') {
            const tag = inner[i..@min(i + 16, inner.len)];

            // Check for end of script/style
            if (skipping_script_or_style and
                (std.mem.startsWith(u8, tag, "</script") or std.mem.startsWith(u8, tag, "</style")))
            {
                skipping_script_or_style = false;
            }

            // End of comment
            if (skipping_comment and i >= 2 and std.mem.eql(u8, inner[i - 2..i + 1], "-->")) {
                skipping_comment = false;
            }

            inside_tag = false;

            // Insert space after block-level tag closings
            if (std.mem.startsWith(u8, tag, "</p") or std.mem.startsWith(u8, tag, "<br") or
                std.mem.startsWith(u8, tag, "</div") or std.mem.startsWith(u8, tag, "</li") or
                std.mem.startsWith(u8, tag, "<hr"))
            {
                try text.append(' ');
            }

            i += 1;
            continue;
        }

        if (!inside_tag and !skipping_script_or_style and !skipping_comment) {
            if (inner[i] == '&') {
                if (std.mem.startsWith(u8, inner[i..], "&nbsp;")) {
                    try text.append(' ');
                    i += 6;
                    continue;
                } else if (std.mem.startsWith(u8, inner[i..], "&lt;")) {
                    try text.append('<');
                    i += 4;
                    continue;
                } else if (std.mem.startsWith(u8, inner[i..], "&gt;")) {
                    try text.append('>');
                    i += 4;
                    continue;
                } else if (std.mem.startsWith(u8, inner[i..], "&amp;")) {
                    try text.append('&');
                    i += 5;
                    continue;
                } else if (std.mem.startsWith(u8, inner[i..], "&quot;")) {
                    try text.append('"');
                    i += 6;
                    continue;
                } else {
                    try text.append(inner[i]);
                }
            } else {
                try text.append(inner[i]);
            }
        }

        i += 1;
    }

    return try text.toOwnedSlice();
}

fn extractTitle(self: *Parser) ![]const u8 {
    const start_tag = "<title>";
    const end_tag = "</title>";

    const start = std.mem.indexOf(u8, self.body.items, start_tag) orelse return "";
    const end = std.mem.indexOf(u8, self.body.items, end_tag) orelse return "";

    const title_start = start + start_tag.len;
    if (title_start >= end) return "";

    return try self.ctx.alloc.dupe(u8, self.body.items[title_start..end]);
}

fn extractMeta(self: *Parser, name: []const u8) ![]const u8 {
    const pattern = try std.fmt.allocPrint(self.ctx.alloc, "<meta name=\"{s}\" content=\"", .{name});
    defer self.ctx.alloc.free(pattern);

    const start = std.mem.indexOf(u8, self.body.items, pattern) orelse return "";
    const after = self.body.items[start + pattern.len..];

    const end_quote = std.mem.indexOfScalar(u8, after, '"') orelse return "";
    return try self.ctx.alloc.dupe(u8, after[0..end_quote]);
}

fn extractLinks(self: *Parser) !std.ArrayList([]u8) {
    var links = std.ArrayList([]u8).init(self.ctx.alloc);

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

        const url_copy = try self.ctx.alloc.dupe(u8, url);
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
