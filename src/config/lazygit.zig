const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.lazygit);

const GITHUB_API_URL = "https://api.github.com/repos/jesseduffield/lazygit/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "lazygit",
    .type = .Package,
    .getDownloadTargets = fetchVersions,
    .decompressTargetFile = decompressTargetFile,
};

fn matchingAsset(name: []const u8) bool {
    const targetFilename = comptime getTargetFilename();

    return std.ascii.endsWithIgnoreCase(name, targetFilename orelse return false);
}

const DownloadTargets = common.DownloadTargets;
const DownloadTargetError = common.DownloadTargetError;
fn fetchVersions(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    progress: std.Progress.Node,
) DownloadTargetError!DownloadTargets {
    return try common.fetchGithubReleases(
        alloc,
        logger,
        progress,
        client,
        GITHUB_API_URL,
        common.stripV,
        matchingAsset,
    );
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: common.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    const exeName = "lazygit";

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
    const os = switch (builtin.target.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        .windows => "windows",
        .freebsd => "freeBSD",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        .x86 => "x86",
        .arm => "armv7",
        else => return null,
    };

    const extension = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("{s}_{s}.{s}", .{ os, arch, extension });
}
