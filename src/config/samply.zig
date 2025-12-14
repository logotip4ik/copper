const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.samply);

const GITHUB_API_URL = "https://api.github.com/repos/mstange/samply/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "samply",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = stripSamplyPrefix,
    }),
    .decompressTargetFile = decompressTargetFile,
    .getTarballShasum = getTarballShasum,
};

const DownloadTarget = common.DownloadTarget;
const GetTarballShasumError = common.GetTarballShasumError;
fn getTarballShasum(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    target: DownloadTarget,
    progress: std.Progress.Node,
) GetTarballShasumError!?[]const u8 {
    var stream: std.Io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    progress.setEstimatedTotalItems(1);

    const shasumTxtUrl = try std.fmt.allocPrint(alloc, "{s}.sha256", .{
        target.tarball orelse {
            logger.warn("expected {s} {s} to have prebuilt tarball url", .{
                interface.name,
                target.versionString,
            });
            return null;
        },
    });
    defer alloc.free(shasumTxtUrl);

    const shasumRes = client.fetch(.{
        .method = .GET,
        .location = .{ .url = shasumTxtUrl },
        .headers = consts.DEFAULT_HEADERS,
        .keep_alive = false,
        .response_writer = &stream.writer,
    }) catch return GetTarballShasumError.FailedFetching;

    progress.completeOne();

    const written = stream.written();

    if (shasumRes.status != .ok or written.len == 0) {
        return GetTarballShasumError.FailedFetching;
    }

    const firstSpace = std.mem.indexOfScalar(u8, written, ' ') orelse return GetTarballShasumError.ShasumNotFound;
    const shasum = written[0..firstSpace];

    return try alloc.dupe(u8, shasum);
}

fn stripSamplyPrefix(alloc: std.mem.Allocator, version: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, version, "samply-v")) {
        return alloc.dupe(u8, version["samply-v".len..]) catch null;
    }

    return null;
}

fn matchingAsset(name: []const u8) bool {
    const targetFilename = comptime getTargetPrefix();

    return std.mem.endsWith(u8, name, targetFilename orelse return false);
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
        stripSamplyPrefix,
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
    if (common.openFirstDirWithLog(tmpDir, logger, "using already decompressed {s}") catch null) |dir| {
        return dir;
    }

    switch (compression) {
        .xz => try compress.decompressXzDir(alloc, targetFile, tmpDir),
        .zip => try compress.decompressZipDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    const dir = common.openFirstDirWithLog(tmpDir, logger, "decompressed {s}") catch return DecompressError.FailedUnzipping;
    return dir orelse DecompressError.FailedUnzipping;
}

fn getTargetPrefix() ?[]const u8 {
    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "aarch64",
        else => return null,
    };

    const os = switch (builtin.target.os.tag) {
        .linux => "unknown-linux-gnu",
        .macos => "apple-darwin",
        .windows => "pc-windows-msvc",
        else => return null,
    };

    const extension = if (builtin.target.os.tag == .windows) "zip" else "tar.xz";

    return std.fmt.comptimePrint("{s}-{s}.{s}", .{ arch, os, extension });
}
