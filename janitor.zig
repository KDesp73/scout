const std = @import("std");

/// A utility struct to simplify and organize common Zig build steps.
///
/// This struct wraps around the Zig `std.Build` API and provides
/// a clean interface for setting up an executable target, managing dependencies,
/// creating custom build steps, and running or cleaning the project.
const Janitor = @This();

/// Represents a custom build step, either running or cleaning the build output.
pub const Step = enum {
    run,
    clean,
    tests,
    help,
};

const version = "0.1.1";

/// The main build object passed into `build.zig`.
b: *std.Build,

/// The compiled executable module, created via `exe()`.
mod: ?*std.Build.Step.Compile,

/// The target platform (e.g., x86_64-linux).
target: std.Build.ResolvedTarget,

/// The optimization mode (e.g., Debug, ReleaseFast).
optimize: std.builtin.OptimizeMode,

/// The name of the executable, for internal tracking.
name: ?[]const u8,

/// Initializes the Janitor helper with a reference to the build object.
pub fn init(b: *std.Build) Janitor {
    return Janitor{
        .b = b,
        .mod = null,
        .name = null,
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    };
}

fn ensureMod(self: *Janitor) *std.Build.Step.Compile {
    return self.mod orelse @panic("mod is not initialized. Call exe(), staticLib() or sharedLib() first.");
}

/// Defines the executable target.
///
/// This must be called before adding dependencies.
pub fn exe(self: *Janitor, name: []const u8) void {
    self.name = name;
    self.mod = self.b.addExecutable(.{
        .name = name,
        .root_source_file = self.b.path("src/main.zig"),
        .target = self.target,
        .optimize = self.optimize,
    });
}

/// Defines a static lib target.
///
/// This must be called before adding dependencies.
pub fn staticLib(self: *Janitor, name: []const u8, root: []const u8) void {
    const lib = self.b.addStaticLibrary(.{
        .name = name,
        .root_source_file = self.b.path(root),
        .target = self.target,
        .optimize = self.optimize,
    });
    self.name = name;
    self.mod = lib;
    _ = self.b.installArtifact(lib);
}

/// Defines a shared lib target.
///
/// This must be called before adding dependencies.
pub fn sharedLib(self: *Janitor, name: []const u8, root: []const u8) void {
    const lib = self.b.addSharedLibrary(.{
        .name = name,
        .root_source_file = self.b.path(root),
        .target = self.target,
        .optimize = self.optimize,
    });
    self.name = name;
    self.mod = lib;
    _ = self.b.installArtifact(lib);
}

/// Adds a dependency to the executable's root module.
///
/// `name` should match the dependency declared in `build.zig.zon`.
pub fn dep(self: *Janitor, name: []const u8) void {
    const mod = self.ensureMod();

    const d = self.b.dependency(name, .{});
    mod.root_module.addImport(name, d.module(name));
}

/// Declares a build option and returns its value.
///
/// This is useful for configurable builds (e.g., `-Dflag=value`).
pub fn opt(self: *Janitor, T: type, name: []const u8, desc: []const u8) ?T {
    return self.b.option(T, name, desc);
}

/// Marks the executable to be installed to `zig-out/bin` on build.
pub fn install(self: *Janitor) void {
    if (self.mod) |e| {
        self.b.installArtifact(e);
    }
}

/// Adds a predefined step to the build pipeline.
///
/// Supported steps: `.run` and `.clean`.
pub fn step(self: *Janitor, s: Step) *std.Build.Step {
    return switch (s) {
        Step.run => self.addRunStep(),
        Step.clean => self.addCleanStep(),
        Step.tests => self.addTestStep("src"),
        Step.help => self.addHelpStep(),
    };
}

/// Adds a `run` step that builds and executes the binary.
fn addRunStep(self: *Janitor) *std.Build.Step {
    const mod = self.ensureMod();
    const run_cmd = self.b.addRunArtifact(mod);
    const run_step = self.b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    return run_step;
}

/// Adds a `test` step that runs all tests
fn addTestStep(self: *Janitor, path: []const u8) *std.Build.Step {
    const t = self.b.addTest(.{
        .root_source_file = self.b.path(path),
        .target = self.target,
        .optimize = self.optimize,
    });
    const s = self.b.step("test", "Run tests");
    s.dependOn(&t.step);
    return s;
}

/// Adds a `clean` step that deletes the Zig cache and output directories.
///
/// This allows running `zig build clean` to reset the build state.
fn addCleanStep(self: *Janitor) *std.Build.Step {
    const clean_step = self.b.step("clean", "Clean build output");
    clean_step.makeFn = struct {
        fn make(_: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
            const cwd = std.fs.cwd();
            cwd.deleteTree("zig-cache") catch |err| {
                if (err != error.FileNotFound) return err;
            };
            cwd.deleteTree("zig-out") catch |err| {
                if (err != error.FileNotFound) return err;
            };
        }
    }.make;
    return clean_step;
}

/// Adds a `help` step that prints the help message
fn addHelpStep(self: *Janitor) *std.Build.Step {
    const s = self.b.step("help", "Print the help message");

    s.makeFn = struct {
        fn make(st: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
            const writer = std.io.getStdOut().writer();
            const steps = st.owner.top_level_steps;

            try writer.print(
            \\USAGE
            \\  zig build [<STEP>]
            \\
            \\STEPS
            \\
            , .{});

            var it = steps.iterator();
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                const stp = entry.value_ptr.*;
                try writer.print("  {s:<20} {s}\n", .{ name, stp.description });
            }
        }
    }.make;

    return s;
}

/// Adds a fully custom step with a user-defined function.
///
/// `makeFn` must follow the `std.Build.Step.MakeFn` signature.
pub fn customStep(self: *Janitor, name: []const u8, desc: []const u8, makeFn: std.Build.Step.MakeFn) *std.Build.Step {
    const s = self.b.step(name, desc);
    s.makeFn = makeFn;
    return s;
}

/// Attempts to get the current Git version/tag.
///
/// Returns the output of `git describe --tags --always` trimmed of newline.
/// If Git is unavailable or fails, returns `null`.
pub fn getGitVersion(self: *Janitor) ?[]const u8 {
    const allocator = self.b.allocator;
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "describe", "--tags", "--always" },
    }) catch return null;

    if (result.term != .Exited or result.term.Exited != 0 or result.stdout.len == 0)
        return null;

    return std.mem.trimRight(u8, result.stdout, "\n");
}

/// Adds a translated C module to the executable build.
///
/// This function uses `addTranslateC` to compile a C source file into a Zig module,
/// and links it into the executable being built. Optionally, you can specify an
/// include directory for headers and an object file to link.
///
/// - `name`: The name under which the C module will be imported into the root module.
/// - `rootSrc`: The path to the C source file to be translated.
/// - `include`: (Optional) A directory path to be added to the include search paths.
/// - `obj`: (Optional) A path to a precompiled object file to link into the executable.
pub fn clib(self: *Janitor, name: []const u8, rootSrc: []const u8, include: ?[]const u8, obj: ?[]const u8) void {
    if(self.mod) |e| {
        const c_bindings = self.b.addTranslateC(.{
            .target = self.target,
            .optimize = self.optimize,
            .use_clang = true,
            .link_libc = true,
            .root_source_file = self.b.path(rootSrc),
        });

        e.root_module.addImport(name, c_bindings.createModule());

        if (include) |i| {
            e.addIncludePath(self.b.path(i));
        }

        if (obj) |o| {
            e.addObjectFile(self.b.path(o));
        }

    }
}

/// Execute a shell command
pub fn exec(allocator: std.mem.Allocator, tokens: []const []const u8) !u8 {
    var process = std.process.Child.init(tokens, allocator);

    process.stderr_behavior = .Inherit;
    process.stdout_behavior = .Inherit;

    try process.spawn();
    const result = try process.wait();
    return result.Exited;
}
