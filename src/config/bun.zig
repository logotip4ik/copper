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
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = bunVersionToSemver,
    }),
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

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    compression: compress.Compression,
    targetFile: std.Io.File,
    tmpDir: std.Io.Dir,
) DecompressError!std.Io.Dir {
    if (common.openFirstDirWithLog(io, tmpDir, logger, "using cached decompressed {s}") catch null) |dir| {
        return dir;
    }

    switch (compression) {
        .gz => try compress.decompressGzDir(alloc, io, targetFile, tmpDir),
        .zip => try compress.decompressZipDir(alloc, io, targetFile, tmpDir),
        else => unreachable,
    }

    const dir = common.openFirstDirWithLog(io, tmpDir, logger, "decompressed {s}") catch return error.FailedUnzipping;

    if (builtin.target.os.tag != .windows) if (dir) |d| {
        var iter = d.iterate();
        while (iter.next(io) catch null) |entry| {
            if (!std.mem.eql(u8, entry.name, "bun")) {
                continue;
            }

            const file = d.openFile(io, entry.name, .{ .mode = .read_only }) catch continue;
            defer file.close(io);

            file.setPermissions(io, .executable_file) catch return error.FailedCopying;

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
