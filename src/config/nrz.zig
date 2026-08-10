const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.nrz);

const GITHUB_API_URL = "https://api.github.com/repos/logotip4ik/nrz/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "nrz",
    .type = .Package,
    .getDownloadTargets = common.FetchRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = common.DecompressExeName("nrz"),
};

fn matchingAsset(name: []const u8) bool {
    const filename = comptime getTargetFilename();

    return std.mem.eql(u8, name, filename orelse return false);
}

fn getTargetFilename() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };

    return std.fmt.comptimePrint("nrz-{s}-{s}.tar.gz", .{ os, arch });
}
