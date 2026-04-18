const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.@"git-delta");

const GITHUB_API_URL = "https://api.github.com/repos/dandavison/delta/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "git-delta",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = common.decompressFirstDir,
};

fn matchingAsset(name: []const u8) bool {
    const targetFilename = comptime getTargetFilename();

    return std.mem.endsWith(u8, name, targetFilename orelse return false);
}

fn getTargetFilename() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "apple-darwin",
        .linux => "unknown-linux-gnu",
        .windows => "pc-windows-msvc",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "i686",
        .arm => "arm",
        else => return null,
    };

    if (builtin.target.os.tag == .windows) {
        return std.fmt.comptimePrint("{s}-{s}.zip", .{ arch, os });
    }

    return std.fmt.comptimePrint("{s}-{s}.tar.gz", .{ arch, os });
}
