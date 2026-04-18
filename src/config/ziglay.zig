const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.ziglay);

const GITHUB_API_URL = "https://api.github.com/repos/logotip4ik/ziglay/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "ziglay",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = common.DecompressExeName("ziglay"),
};

fn matchingAsset(name: []const u8) bool {
    const filename = comptime getTargetFilename();

    return std.mem.eql(u8, name, filename orelse return false);
}

fn getTargetFilename() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };

    const ext = switch (builtin.target.os.tag) {
        .windows => ".zip",
        else => ".tar.gz",
    };

    return std.fmt.comptimePrint("ziglay-{s}-{s}{s}", .{ os, arch, ext });
}
