const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.odin);

const GITHUB_API_URL = "https://api.github.com/repos/odin-lang/Odin/releases";

pub const interface: common.ConfInterface = .{
    .name = "odin",
    .type = .Runtime,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = toSemVerString,
    }),
    .decompressTargetFile = common.decompressFirstDir,
};

pub fn toSemVerString(alloc: std.mem.Allocator, version: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, version, "dev-"))
        return null;

    var parts = std.mem.splitScalar(u8, version[4..], '-');

    const year = parts.next() orelse return null;
    const month_part = parts.next() orelse return null;

    if (parts.next() != null)
        return null;

    var month_end: usize = 0;
    while (month_end < month_part.len and std.ascii.isDigit(month_part[month_end])) {
        month_end += 1;
    }

    if (month_end == 0)
        return null;

    const month_str = month_part[0..month_end];
    const suffix = month_part[month_end..];

    const month = std.fmt.parseUnsigned(u8, month_str, 10) catch return null;
    if (month == 0 or month > 12)
        return null;

    if (suffix.len == 0) {
        return std.fmt.allocPrint(
            alloc,
            "{s}.{d}.0",
            .{ year, month },
        ) catch null;
    }

    const patch = suffix[0] - 'a' + 1;

    return std.fmt.allocPrint(
        alloc,
        "{s}.{d}.{d}",
        .{ year, month, patch },
    ) catch null;
}

fn matchingAsset(name: []const u8) bool {
    const prefix, const suffix = comptime getTargetSuffix();

    return std.mem.startsWith(
        u8,
        name,
        prefix orelse return null,
    ) and std.mem.endsWith(
        u8,
        name,
        suffix orelse return null,
    );
}

fn getTargetSuffix() struct { ?[]const u8, ?[]const u8 } {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "winddows",
        else => return .{ null, null },
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => return .{ null, null },
    };

    return .{
        std.fmt.comptimePrint("odin-{s}-{s}", .{ os, arch }),
        if (builtin.target.os.tag == .windows) "zip" else "tar.gz",
    };
}
