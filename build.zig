const std = @import("std");

const Janitor = @import("janitor.zig").Janitor;

pub fn build(b: *std.Build) void {
    var j = Janitor.init(b);

    j.exe("search");
    j.install();

    _ = j.step(.clean);
    _ = j.step(.help);
    _ = j.step(.run);
}
