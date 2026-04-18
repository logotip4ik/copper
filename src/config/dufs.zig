const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.dufs);

const GITHUB_API_URL = "https://api.github.com/repos/sigoden/dufs/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "dufs",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = common.DecompressExeName("dufs"),
};

fn matchingAsset(name: []const u8) bool {
    const targetSuffix = comptime getTargetFilename();

    return std.mem.endsWith(u8, name, targetSuffix orelse return false);
}

fn getTargetFilename() ?[]const u8 {
    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "arm",
        else => return null,
    };

    const os = switch (builtin.target.os.tag) {
        .linux => "unknown-linux-musl",
        .macos => "apple-darwin",
        .windows => "pc-windows-msvc",
        else => return null,
    };

    const extension = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("{s}-{s}.{s}", .{ arch, os, extension });
}
