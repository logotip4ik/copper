const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.helix);

const GITHUB_API_URL = "https://api.github.com/repos/helix-editor/helix/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "helix",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = toSemanticVersion,
    }),
    .decompressTargetFile = decompressTargetFile,
};

fn toSemanticVersion(alloc: std.mem.Allocator, version: []const u8) ?[]const u8 {
    if (version[0] == 'v') {
        return common.stripV(alloc, version);
    }

    var chunkIter = std.mem.splitScalar(u8, version, '.');
    const major = chunkIter.next() orelse return null;
    var minor = chunkIter.next() orelse return null;
    var patch = chunkIter.next() orelse "0";

    if (minor.len > 1 and minor[0] == '0') {
        minor = minor[1..];
    }
    if (patch.len > 1 and patch[0] == '0') {
        patch = patch[1..];
    }

    return std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ major, minor, patch }) catch null;
}

test {
    const versions = &.{
        "25.07.1",
        "22.03",
        "v0.6.0",
    };

    inline for (versions) |version| {
        const v = toSemanticVersion(std.testing.allocator, version).?;
        defer std.testing.allocator.free(v);

        _ = try std.SemanticVersion.parse(v);
    }
}

fn matchingAsset(name: []const u8) bool {
    const targetSuffix = comptime getTargetPrefix();

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
        .zip => try compress.decompressZipDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    const dir = common.openFirstDirWithLog(tmpDir, logger, "decompressed {s}") catch return error.FailedUnzipping;
    return dir orelse error.FailedUnzipping;
}

fn getTargetPrefix() ?[]const u8 {
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

    const ext = if (builtin.target.os.tag == .windows) "zip" else "tar.xz";

    return std.fmt.comptimePrint("{s}-{s}.{s}", .{ arch, os, ext });
}
