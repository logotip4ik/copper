/// This is a bit special, we don't export this as a config, but it pretty much is a config
const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.copper);

const COPPER_LATEST_RELEASE = "https://api.github.com/repos/logotip4ik/copper/releases/latest";

fn matchingAsset(name: []const u8) bool {
    const filename = comptime getCopperTarget();

    return std.mem.eql(u8, name, filename orelse return false);
}

const DownloadTarget = common.DownloadTarget;
pub fn latestVersion(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    progress: std.Progress.Node,
) !DownloadTarget {
    var targets = try common.fetchGithubReleases(
        alloc,
        logger,
        progress,
        client,
        COPPER_LATEST_RELEASE,
        common.stripV,
        matchingAsset,
    );
    defer targets.deinit(alloc);

    return targets.items[0];
}

pub fn decompressCopper(
    alloc: std.mem.Allocator,
    compression: compress.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) ![]const u8 {
    const exeName = "copper";

    if (common.dirContainsFileWithLog(tmpDir, exeName, logger, "using already decompressed {s}")) {
        return tmpDir.realpathAlloc(alloc, exeName);
    }

    switch (compression) {
        .gz => try compress.decompressGzDir(alloc, targetFile, tmpDir),
        .zip => try compress.decompressZipDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    if (common.dirContainsFileWithLog(tmpDir, exeName, logger, "decompressed {s}")) {
        return tmpDir.realpathAlloc(alloc, exeName);
    }

    return error.FailedUnzipping;
}

fn getCopperTarget() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };

    const ext = switch (builtin.target.os.tag) {
        .windows => ".zip",
        else => ".tar.gz",
    };

    return std.fmt.comptimePrint("copper-{s}-{s}{s}", .{ os, arch, ext });
}
