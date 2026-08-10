const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.glab);

const GITLAB_API_URL = "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases/permalink/latest";

pub const interface: common.ConfInterface = .{
    .name = "glab",
    .type = .Package,
    .binPath = "bin",
    .getDownloadTargets = common.FetchRelease(.{
        .logger = logger,
        .relaseUrl = GITLAB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = common.decompressIntoTmpDir,
};

fn matchingAsset(name: []const u8) bool {
    const targetFilename = comptime getTargetFilenameSuffix();

    return std.mem.endsWith(u8, name, targetFilename orelse return false);
}

fn getTargetFilenameSuffix() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        .windows => "windows",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .arm => "armv6",
        .x86 => "386",
        .s390x => "s390x",
        .powerpc64le => "ppc64le",
        else => return null,
    };

    const extension = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("{s}_{s}.{s}", .{ os, arch, extension });
}
