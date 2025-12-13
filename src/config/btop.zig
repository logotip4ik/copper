const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.btop);

pub const interface: common.ConfInterface = .{
    .name = "btop",
    .type = .Package,
    .getDownloadTargets = getDownloadTargets,
    .decompressTargetFile = decompressTargetFile,
    .buildTarget = buildTarget,
};

const GITHUB_API_URL = "https://api.github.com/repos/aristocratos/btop/releases/latest";

fn matchingAsset(name: []const u8) bool {
    const prefix = comptime getTargetPrefix();

    return std.mem.endsWith(u8, name, prefix orelse return false);
}

const DownloadTarget = common.DownloadTarget;
const DownloadTargets = common.DownloadTargets;
const DownloadTargetError = common.DownloadTargetError;
fn getDownloadTargets(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    progress: std.Progress.Node,
) DownloadTargetError!DownloadTargets {
    return common.fetchGithubReleases(
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
    compression: compress.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    if (common.openFirstDirWithLog(tmpDir, logger, "using cached decompressed {s}") catch null) |dir| {
        return dir;
    }

    switch (compression) {
        .gz => try compress.decompressGzDir(alloc, targetFile, tmpDir),
        .tgz => try compress.decompressTgzDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    const dir = common.openFirstDirWithLog(tmpDir, logger, "decompressed {s}") catch return error.FailedUnzipping;
    return dir orelse error.FailedUnzipping;
}

const BuildFromSourceError = common.BuildFromSourceError;
fn buildTarget(
    alloc: std.mem.Allocator,
    progress: std.Progress.Node,
    sourceDir: std.fs.Dir,
    _: common.BuildTargetContext,
) BuildFromSourceError!std.fs.Dir {
    progress.setEstimatedTotalItems(1);
    defer progress.completeOne();

    logger.info("checking if make is installed", .{});
    const isMakeInstalled = common.isMakeInstalled(alloc);
    if (!isMakeInstalled) {
        logger.info("please install make before proceeding", .{});
        return BuildFromSourceError.DepsNotInstalled;
    }

    common.run(alloc, &.{
        "make",
        "ADDFLAGS=-march=native",
        "QUIET=true",
        "STRIP=true",
    }, .{ .cwdDir = sourceDir }) catch |err| {
        logger.err("failed building with {s}\n", .{@errorName(err)});
        return BuildFromSourceError.FailedBuilding;
    };

    return sourceDir.openDir("bin", .{}) catch BuildFromSourceError.FailedBuilding;
}

fn getTargetPrefix() ?[]const u8 {
    const arch = switch (builtin.target.cpu.arch) {
        .aarch64 => "aarch64",
        .x86 => "i686",
        .mips64 => "mips64",
        .powerpc64 => "powerpc64",
        .x86_64 => "x86_64",
        else => return null,
    };

    const os = switch (builtin.target.os.tag) {
        .linux => "linux-musl",
        else => return null,
    };

    return std.fmt.comptimePrint("btop-{s}-{s}.tbz", .{ arch, os });
}
