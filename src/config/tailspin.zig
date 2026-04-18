const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.lazygit);

const GITHUB_API_URL = "https://api.github.com/repos/bensadeh/tailspin/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "tailspin",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = common.DecompressExeName("tspin"),
};

fn matchingAsset(name: []const u8) bool {
    const targetFilename = comptime getTargetFilename();

    return std.ascii.endsWithIgnoreCase(name, targetFilename orelse return false);
}

fn getTargetFilename() ?[]const u8 {
    const os_tag = switch (builtin.target.os.tag) {
        .macos => "apple-darwin",
        .linux => "unknown-linux-musl",
        .windows => "pc-windows-msvc",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };

    const extension = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("tailspin-{s}-{s}.{s}", .{ arch, os_tag, extension });
}
