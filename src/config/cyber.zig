const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");

const compress = @import("compress");
const common = @import("./common.zig");

const logger = std.log.scoped(.cyber);

const GITHUB_API_URL = "https://api.github.com/repos/fubark/cyber/releases";

pub const interface: common.ConfInterface = .{
    .name = "cyber",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = toSemanticVersion,
    }),
    .decompressTargetFile = decompressTargetFile,
};

fn matchingAsset(name: []const u8) bool {
    const targetFilename = comptime getTargetFilename();

    return std.mem.eql(u8, name, targetFilename orelse return false);
}

pub fn toSemanticVersion(alloc: std.mem.Allocator, version: []const u8) ?[]const u8 {
    if (version.len == 0 or std.mem.eql(u8, version, "latest")) return null;

    const v = if (version[0] == 'v') version[1..] else version;

    var dotIter = std.mem.splitScalar(u8, std.mem.trim(u8, v, &std.ascii.whitespace), '.');

    const major = dotIter.next() orelse return null;
    const minor = dotIter.next() orelse return null;
    const patch = dotIter.next() orelse "0";
    const rest = dotIter.rest();

    if (rest.len > 0) {
        return std.fmt.allocPrint(alloc, "{s}.{s}.{s}-{s}", .{
            major,
            minor,
            patch,
            rest,
        }) catch null;
    }

    return std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{
        major,
        minor,
        patch,
    }) catch null;
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: compress.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    const exeName = "cyber";

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
        .macos => "macos",
        .windows => "windows",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => return null,
    };

    const extension = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("cyber-{s}-{s}.{s}", .{ os, arch, extension });
}
