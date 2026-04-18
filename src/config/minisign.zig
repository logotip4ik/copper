const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.minisign);

const GITHUB_API_URL = "https://api.github.com/repos/jedisct1/minisign/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "minisign",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = toSemver,
    }),
    .decompressTargetFile = common.DecompressExeName("minisign"),
};

pub fn toSemver(alloc: std.mem.Allocator, version: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(alloc, "{s}.0", .{version}) catch null;
}

fn matchingAsset(name: []const u8) bool {
    const targetSuffix = comptime getTargetSuffix();

    return std.mem.endsWith(u8, name, targetSuffix orelse return false);
}

fn getTargetSuffix() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .windows => switch (builtin.target.cpu.arch) {
            .x86_64 => "win64",
            else => return null,
        },
        .linux => switch (builtin.target.cpu.arch) {
            .x86_64 => "linux",
            else => return null,
        },
        .macos => switch (builtin.target.cpu.arch) {
            .aarch64 => "macos",
            else => return null,
        },
        else => return null,
    };

    const ext = if (builtin.target.os.tag == .linux) "tar.gz" else "zip";

    return std.fmt.comptimePrint("-{s}.{s}", .{ os, ext });
}
