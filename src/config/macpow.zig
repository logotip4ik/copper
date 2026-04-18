const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.macpow);

const GITHUB_API_URL = "https://api.github.com/repos/k06a/macpow/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "macpow",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = common.DecompressExeName("macpow"),
};

fn matchingAsset(name: []const u8) bool {
    const targetSuffix = comptime getTargetSuffix();

    return std.mem.endsWith(u8, name, targetSuffix orelse return false);
}

fn getTargetSuffix() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "apple-darwin",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .aarch64 => "aarch64",
        else => return null,
    };

    return std.fmt.comptimePrint("-{s}-{s}.tar.gz", .{ arch, os });
}
