const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.ripgrep);

const GITHUB_API_URL = "https://api.github.com/repos/BurntSushi/ripgrep/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "ripgrep",
    .type = .Package,
    .manPages = &.{"doc/rg.1"},
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
        .windows => "pc-windows-msvc",
        .linux => switch (builtin.target.cpu.arch) {
            .x86_64 => "unknown-linux-musl",
            .arm => "unknown-linux-gnueabihf",
            else => "unknown-linux-gnu",
        },
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "i686",
        .arm => "armv7",
        .s390x => "s390x",
        else => return null,
    };

    if (builtin.target.os.tag == .windows) {
        return std.fmt.comptimePrint("{s}-{s}.exe", .{ arch, os });
    }

    return std.fmt.comptimePrint("{s}-{s}.tar.gz", .{ arch, os });
}
