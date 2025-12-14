const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.nvim);

const GITHUB_API_URL = "https://api.github.com/repos/neovim/neovim/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "neovim",
    .type = .Package,
    .binPath = "bin",
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

    return std.mem.eql(u8, name, targetSuffix orelse return false);
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
        .zip => try compress.decompressZipDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    const dir = common.openFirstDirWithLog(tmpDir, logger, "decompressed {s}") catch return error.FailedUnzipping;
    return dir orelse error.FailedUnzipping;
}

fn getTargetFilename() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "win",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => if (builtin.target.os.tag == .windows) "64" else "-x86_64",
        .aarch64 => "-arm64",
        else => return null,
    };

    const ext = if (builtin.target.os.tag == .windows) ".zip" else ".tar.gz";

    return std.fmt.comptimePrint("nvim-{s}{s}{s}", .{ os, arch, ext });
}
