const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.rtk);

const GITHUB_API_URL = "https://api.github.com/repos/rtk-ai/rtk/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "rtk",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = common.DecompressExeName("rtk"),
};

fn matchingAsset(name: []const u8) bool {
    const targetSuffix = comptime getTargetSuffix();

    return std.mem.endsWith(u8, name, targetSuffix orelse return false);
}

fn getTargetSuffix() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "apple-darwin",
        .windows => "pc-windows-msvc",
        .linux => switch (builtin.target.cpu.arch) {
            .x86_64 => "unknown-linux-musl",
            .aarch64 => "unknown-linux-gnu",
            else => return null,
        },
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };

    const ext = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("-{s}-{s}.{s}", .{ arch, os, ext });
}
