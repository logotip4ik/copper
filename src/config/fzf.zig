const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.fzf);

const GITHUB_API_URL = "https://api.github.com/repos/junegunn/fzf/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "fzf",
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
    const exeName = "fzf";

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
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .arm => "armv7",
        .x86 => "386",
        .s390x => "s390x",
        .powerpc64le => "ppc64le",
        else => return null,
    };

    const extension = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("{s}_{s}.{s}", .{ os, arch, extension });
}
