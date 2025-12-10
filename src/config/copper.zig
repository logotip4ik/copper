/// This is a bit special, we don't export this as a config, but it pretty much is a config
const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.copper);

const DownloadTarget = common.DownloadTarget;

fn matchingCopperAsset(name: []const u8) bool {
    const filename = comptime getCopperTarget();

    return std.mem.eql(u8, name, filename orelse return false);
}

const COPPER_LATEST_RELEASE = "https://api.github.com/repos/logotip4ik/copper/releases/latest";
pub fn latestVersion(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    progress: std.Progress.Node,
) !DownloadTarget {
    var stream: std.io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    var fetchingRelease = progress.start("fetching latest release", 0);
    const res = client.fetch(.{
        .headers = consts.DEFAULT_HEADERS,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "Accept", .value = "application/vnd.github+json" },
            .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
        },
        .keep_alive = false,
        .location = .{ .url = COPPER_LATEST_RELEASE },
        .method = .GET,
        .response_writer = &stream.writer,
    }) catch return error.FailedFetchingLatestRelease;
    fetchingRelease.end();

    const writen = stream.written();

    if (res.status != .ok or writen.len == 0) {
        return error.FailedFetchingLatestRelease;
    }

    const json: std.json.Parsed(std.json.Value) = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        writen,
        .{},
    ) catch return error.FailedParsingReleaseJson;
    defer json.deinit();

    return try common.githubReleaseToDownloadTarget(
        alloc,
        logger,
        json.value.object,
        common.stripV,
        matchingCopperAsset,
    );
}

pub fn decompressCopper(
    alloc: std.mem.Allocator,
    compression: common.Compression,
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
