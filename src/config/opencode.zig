const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.opencode);

const GITHUB_API_URL = "https://api.github.com/repos/anomalyco/opencode/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "opencode",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = decompressTargetFile,
};

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    compression: compress.Compression,
    targetFile: std.Io.File,
    tmpDir: std.Io.Dir,
) DecompressError!std.Io.Dir {
    const exeName = "opencode";

    if (common.dirContainsFileWithLog(io, tmpDir, exeName, std.log, "using already decompressed {s}")) {
        return tmpDir;
    }

    switch (compression) {
        .gz => try compress.decompressGzDir(alloc, io, targetFile, tmpDir),
        .zip => try compress.decompressZipDir(alloc, io, targetFile, tmpDir),
        else => unreachable,
    }

    if (common.dirContainsFileWithLog(io, tmpDir, exeName, std.log, "decompressed {s}")) {
        if (builtin.target.os.tag != .windows) {
            common.markExecutablesInDir(io, tmpDir);
        }

        return tmpDir;
    }

    return error.FailedUnzipping;
}

fn matchingAsset(name: []const u8) bool {
    const targetSuffix = comptime getTargetSuffix();

    return std.mem.endsWith(u8, name, targetSuffix orelse return false);
}

fn getTargetSuffix() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "windows",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => return null,
    };

    const ext = switch (builtin.target.os.tag) {
        .macos, .windows => "zip",
        .linux => "tar.gz",
        else => return null,
    };

    return std.fmt.comptimePrint("opencode-{s}-{s}.{s}", .{ os, arch, ext });
}
