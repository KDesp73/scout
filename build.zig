const std = @import("std");

const Janitor = @import("janitor.zig");

pub fn build(b: *std.Build) void {
    var j = Janitor.init(b);

    j.exe("search");
    j.install();
    j.dep("sqlite");

    _ = j.step(.clean);
    _ = j.step(.help);
    _ = j.step(.run);
}
