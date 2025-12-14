const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.ouch);

const GITHUB_API_URL = "https://api.github.com/repos/ouch-org/ouch/releases/latest";

pub const interface: common.ConfInterface = .{
    .type = .Package,
    .name = "ouch",

    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = decompressTargetFile,

    .buildDeps = &.{"rust"},
    .buildTarget = common.BuildRustTarget(.{
        .executableName = "ouch",
        .logger = logger,
    }),
};

fn matchingAsset(name: []const u8) bool {
    const targetFilename = comptime getTargetPrefix();

    return std.mem.endsWith(u8, name, targetFilename orelse return false);
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: compress.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    if (common.openFirstDirWithLog(tmpDir, logger, "using already decompressed {s}") catch null) |dir| {
        return dir;
    }

    switch (compression) {
        .gz => try compress.decompressGzDir(alloc, targetFile, tmpDir),
        .zip => try compress.decompressZipDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    const dir = common.openFirstDirWithLog(tmpDir, logger, "decompressed {s}") catch return error.FailedUnzipping;
    return dir orelse error.FailedUnzipping;
}

fn getTargetPrefix() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "apple-darwin",
        .linux => "unknown-linux-gnu",
        .windows => "pc-windows-msvc",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };

    const ext = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("{s}-{s}.{s}", .{ arch, os, ext });
}
