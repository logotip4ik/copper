const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.wrkflw);

const GITHUB_API_URL = "https://api.github.com/repos/bahdotsh/wrkflw/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "wrkflw",
    .type = .Package,
    .getDownloadTargets = common.FetchRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = common.DecompressExeName("wrkflw"),
};

fn matchingAsset(name: []const u8) bool {
    const targetSuffix = comptime getTargetPrefix();

    return std.mem.endsWith(u8, name, targetSuffix orelse return false);
}

fn getTargetPrefix() ?[]const u8 {
    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        else => return null,
    };

    const os = switch (builtin.target.os.tag) {
        .linux => "linux",
        .macos => "macos",
        else => return null,
    };

    return std.fmt.comptimePrint("{s}-{s}.tar.gz", .{ os, arch });
}
