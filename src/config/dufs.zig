const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.dufs);

const GITHUB_API_URL = "https://api.github.com/repos/sigoden/dufs/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "dufs",
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
    const targetSuffix = comptime getTargetFilename();

    return std.mem.endsWith(u8, name, targetSuffix orelse return false);
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: compress.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    const exeName = "dufs";

    if (common.dirContainsFileWithLog(tmpDir, exeName, logger, "using already decompressed {s}")) {
        return tmpDir;
    }

    switch (compression) {
        .gz => try compress.decompressGzDir(alloc, targetFile, tmpDir),
        .zip => try compress.decompressZipDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    if (common.dirContainsFileWithLog(tmpDir, exeName, logger, "decompressed {s}")) {
        return tmpDir;
    }

    return error.FailedUnzipping;
}

fn getTargetFilename() ?[]const u8 {
    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "arm",
        else => return null,
    };

    const os = switch (builtin.target.os.tag) {
        .linux => "unknown-linux-musl",
        .macos => "apple-darwin",
        .windows => "pc-windows-msvc",
        else => return null,
    };

    const extension = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("{s}-{s}.{s}", .{ arch, os, extension });
}
