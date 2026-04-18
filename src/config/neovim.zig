const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.nvim);

const GITHUB_API_URL = "https://api.github.com/repos/neovim/neovim/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "neovim",
    .type = .Package,
    .binPath = "bin",
    .manPages = &.{"share/man/man1/nvim.1"},
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = common.decompressFirstDir,
};

fn matchingAsset(name: []const u8) bool {
    const targetSuffix = comptime getTargetFilename();

    return std.mem.eql(u8, name, targetSuffix orelse return false);
}

fn getTargetFilename() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "win",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => if (builtin.target.os.tag == .windows) "64" else "-x86_64",
        .aarch64 => "-arm64",
        else => return null,
    };

    const ext = if (builtin.target.os.tag == .windows) ".zip" else ".tar.gz";

    return std.fmt.comptimePrint("nvim-{s}{s}{s}", .{ os, arch, ext });
}
