const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.hyperfine);

const GITHUB_API_URL = "https://api.github.com/repos/sharkdp/hyperfine/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "hyperfine",
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
    const targetFilename = comptime getTargetFilename();

    return std.mem.endsWith(u8, name, targetFilename orelse return false);
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
    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "arm",
        else => return null,
    };

    const os_spec = switch (builtin.target.os.tag) {
        .linux => "unknown-linux-gnu",
        .macos => "apple-darwin",
        .windows => "pc-windows-msvc",
        else => return null,
    };

    const extension = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("{s}-{s}.{s}", .{ arch, os_spec, extension });
}
