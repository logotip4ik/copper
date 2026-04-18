const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.fastfetch);

const GITHUB_API_URL = "https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "fastfetch",
    .type = .Package,
    .binPath = "bin",
    .manPages = &.{
        "share/man/man1/fastfetch.1",
    },
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = decompressTargetFile,
};

fn matchingAsset(name: []const u8) bool {
    const targetSuffix = comptime getTargetSuffix();

    return std.mem.endsWith(u8, name, targetSuffix orelse return false);
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    compression: compress.Compression,
    targetFile: std.Io.File,
    tmpDir: std.Io.Dir,
) DecompressError!std.Io.Dir {
    if (common.openFirstDirWithLog(io, tmpDir, logger, "") catch null) |usrDir| {
        if (common.openFirstDirWithLog(io, usrDir, logger, "using cached decompressed {s}") catch null) |dir| {
            return dir;
        }
    }

    switch (compression) {
        .gz => try compress.decompressGzDir(alloc, io, targetFile, tmpDir),
        .zip => try compress.decompressZipDir(alloc, io, targetFile, tmpDir),
        else => unreachable,
    }

    if (common.openFirstDirWithLog(io, tmpDir, logger, "") catch null) |usrDir| {
        if (common.openFirstDirWithLog(io, usrDir, logger, "decompressed {s}") catch null) |dir| {
            return dir;
        }
    }

    return error.FailedUnzipping;
}

fn getTargetSuffix() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "aarch64",
        else => return null,
    };

    const ext = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("fastfetch-{s}-{s}.{s}", .{ os, arch, ext });
}
