const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.bun);

const GITHUB_API_URL = "https://api.github.com/repos/oven-sh/bun/releases";

pub const interface: common.ConfInterface = .{
    .name = "bun",
    .type = .Runtime,
    .getDownloadTargets = fetchVersions,
    .decompressTargetFile = decompressTargetFile,
};

fn matchingAsset(name: []const u8) bool {
    const targetFilename = comptime getTargetFilename();

    return std.mem.endsWith(u8, name, targetFilename orelse return false);
}

fn bunVersionToSemver(alloc: std.mem.Allocator, version: []const u8) ?[]const u8 {
    if (version[0] != 'b') return null;

    return alloc.dupe(u8, std.mem.trimStart(u8, version, "bun-v")) catch null;
}

const DownloadTargets = common.DownloadTargets;
const DownloadTargetError = common.DownloadTargetError;
fn fetchVersions(
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
        bunVersionToSemver,
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
    if (common.openFirstDirWithLog(tmpDir, logger, "using cached decompressed {s}") catch null) |dir| {
        return dir;
    }

    switch (compression) {
        .gz => try compress.decompressGzDir(alloc, targetFile, tmpDir),
        .zip => try compress.decompressZipDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    const dir = common.openFirstDirWithLog(tmpDir, logger, "decompressed {s}") catch return error.FailedUnzipping;

    if (builtin.target.os.tag != .windows) if (dir) |d| {
        var iter = d.iterate();
        while (iter.next() catch null) |entry| {
            if (!std.mem.eql(u8, entry.name, "bun")) {
                continue;
            }

            const file = d.openFile(entry.name, .{ .mode = .read_only }) catch continue;
            defer file.close();

            // Make it executable by adding execute permissions for user, group, and others
            // 0o755 means: rwxr-xr-x (user: read+write+execute, group: read+execute, others: read+execute)
            file.chmod(0o755) catch return error.FailedCopying;

            break;
        }
    };

    return dir orelse error.FailedUnzipping;
}

fn getTargetFilename() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "windows",
        else => return null,
    };
    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "aarch64",
        else => return null,
    };

    return std.fmt.comptimePrint("bun-{s}-{s}.zip", .{ os, arch });
}
