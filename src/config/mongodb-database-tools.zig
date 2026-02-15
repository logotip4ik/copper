const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.@"mongodb-database-tools");

pub const interface: common.ConfInterface = .{
    .name = "mongodb-database-tools",
    .type = .Package,
    .binPath = "bin",
    .getDownloadTargets = getDownloadTargets,
    .decompressTargetFile = decompressTargetFile,
};

const DOWNLOAD_TARGET_TEMPLATE = "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-{s}-{s}-{s}.{s}";

const Version = struct {
    target: []const u8,
    arch: []const u8,
    ext: []const u8,
};

const KNOWN_VERSIONS = std.static_string_map.StaticStringMap([]const Version).initComptime([_]struct { []const u8, []const Version }{
    .{
        "100.14.1",
        &[_]Version{
            .{ .target = "macos", .arch = "arm64", .ext = "zip" },
            .{ .target = "macos", .arch = "x86_64", .ext = "zip" },
            .{ .target = "windows", .arch = "x86_64", .ext = "zip" },
            .{ .target = "linux", .arch = "x86_64", .ext = "tgz" },
        },
    },
});

const DownloadTarget = common.DownloadTarget;
const DownloadTargets = common.DownloadTargets;
const DownloadTargetError = common.DownloadTargetError;
pub fn getDownloadTargets(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    progress: std.Progress.Node,
) DownloadTargetError!DownloadTargets {
    _ = client;

    progress.setEstimatedTotalItems(1);

    var targets: DownloadTargets = .empty;
    errdefer {
        for (targets.items) |item| item.deinit(alloc);
        targets.deinit(alloc);
    }

    const targetOs = @tagName(builtin.target.os.tag);
    const targetArch = switch (builtin.target.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => return targets,
    };

    for (KNOWN_VERSIONS.keys()) |versionString| {
        const versions = KNOWN_VERSIONS.get(versionString) orelse continue;

        for (versions) |version| {
            if (!std.mem.eql(u8, version.target, targetOs)) {
                continue;
            }

            if (!std.mem.eql(u8, version.arch, targetArch)) {
                continue;
            }

            const versionStringDupe = alloc.dupe(
                u8,
                versionString,
            ) catch return error.FailedConvertingToDownloadTarget;
            errdefer alloc.free(versionStringDupe);

            const semanticVersion = std.SemanticVersion.parse(
                versionStringDupe,
            ) catch return error.FailedConvertingToDownloadTarget;

            const tarballTarget = if (builtin.target.os.tag == .linux) "debian12" else targetOs;
            const tarball = std.fmt.allocPrint(alloc, DOWNLOAD_TARGET_TEMPLATE, .{
                tarballTarget,
                version.arch,
                versionString,
                version.ext,
            }) catch return error.FailedConvertingToDownloadTarget;

            targets.append(alloc, DownloadTarget{
                .versionString = versionStringDupe,
                .version = semanticVersion,
                .tarball = tarball,
            }) catch unreachable;
        }
    }

    return targets;
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: compress.Compression,
    target: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    if (common.openFirstDirWithLog(tmpDir, logger, "using cached decompressed {s}") catch null) |dir| {
        return dir;
    }

    switch (compression) {
        .zip => try compress.decompressZipDir(alloc, target, tmpDir),
        .tgz => try compress.decompressTgzDir(alloc, target, tmpDir),
        else => unreachable,
    }

    if (common.openFirstDirWithLog(tmpDir, logger, "decompressed {s}") catch null) |dir| {
        if (builtin.target.os.tag != .windows) {
            var binDir = dir.openDir(interface.binPath, .{ .iterate = true }) catch {
                logger.err("missing bin dir in decompressed dir", .{});
                return error.FailedUnzipping;
            };
            defer binDir.close();

            common.markExecutablesInDir(binDir);
        }

        return dir;
    }

    return error.FailedUnzipping;
}
