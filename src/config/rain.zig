const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.rain);

const GITHUB_API_URL = "https://api.github.com/repos/cenkalti/rain/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "rain",
    .type = .Package,
    .getDownloadTargets = common.FetchRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = common.DecompressExeName("rain"),
};

fn matchingAsset(name: []const u8) bool {
    const targetSuffix = comptime getTargetSuffix();

    return std.mem.endsWith(u8, name, targetSuffix orelse return false);
}

fn getTargetSuffix() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return null,
    };

    switch (builtin.target.cpu.arch) {
        .x86_64 => {},
        .aarch64 => switch (builtin.target.os.tag) {
            .macos => {},
            else => return null,
        },
        else => return null,
    }

    const ext = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("{s}.{s}", .{ os, ext });
}
