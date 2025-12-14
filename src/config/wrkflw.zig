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
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = decompressTargetFile,
};

fn matchingAsset(name: []const u8) bool {
    const targetSuffix = comptime getTargetPrefix();

    return std.mem.endsWith(u8, name, targetSuffix orelse return false);
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: compress.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    const exeName = "wrkflw";

    if (common.dirContainsFileWithLog(tmpDir, exeName, logger, "using already decompressed {s}")) {
        return tmpDir;
    }

    switch (compression) {
        .gz => try compress.decompressGzDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    if (common.dirContainsFileWithLog(tmpDir, exeName, logger, "decompressed {s}")) {
        return tmpDir;
    }

    return error.FailedUnzipping;
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
