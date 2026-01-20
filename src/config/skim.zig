const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.skim);

const GITHUB_API_URL = "https://api.github.com/repos/skim-rs/skim/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "skim",
    .type = .Package,
    .manPages = &.{
        "man/man1/sk.1",
        "man/man1/sk-tmux.1",
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
    compression: compress.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    if (common.openFirstDirWithLog(tmpDir, logger, "using cached decompressed {s}") catch null) |dir| {
        return dir;
    }

    switch (compression) {
        .xz => try compress.decompressXzDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    const dir = common.openFirstDirWithLog(tmpDir, logger, "decompressed {s}") catch return error.FailedUnzipping;
    return dir orelse error.FailedUnzipping;
}

fn getTargetSuffix() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "apple-darwin",
        .linux => "unknown-linux-gnu",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };

    return std.fmt.comptimePrint("-{s}-{s}.tar.xz", .{ arch, os });
}
