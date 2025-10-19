const std = @import("std");

const Alloc = std.mem.Allocator;

const Self = @This();

alloc: Alloc,

pub fn init(alloc: Alloc) Self {
    return Self{
        .alloc = alloc,
    };
}

pub fn deinit(self: Self) void {
    _ = self;
}

const isWindows = @import("builtin").os.tag == .windows;

pub fn getHomeDir(allocator: std.mem.Allocator) ![]const u8 {
    const var_name = if (isWindows) "USERPROFILE" else "HOME";
    return std.process.getEnvVarOwned(allocator, var_name) catch |err| switch (err) {
        error.InvalidUtf8, error.EnvironmentVariableNotFound => error.HomeDirNotFound,
        else => |e| return e,
    };
}

pub fn getTmpDirname(alloc: std.mem.Allocator) []const u8 {
    const env_vars = if (isWindows)
        &[_][]const u8{ "TEMP", "TMP" }
    else
        &[_][]const u8{"TMPDIR"};

    for (env_vars) |var_name| {
        if (std.process.getEnvVarOwned(alloc, var_name)) |path| {
            return path;
        } else |_| {}
    }

    const fallback = if (isWindows) "C:\\temp" else "/tmp";
    return alloc.dupe(u8, fallback) catch unreachable;
}
