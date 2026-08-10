const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.zf);

const GITHUB_API_URL = "https://api.github.com/repos/natecraddock/zf/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "zf",
    .type = .Package,
    .getDownloadTargets = common.FetchRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = decompressTargetFile,
};

fn matchingAsset(name: []const u8) bool {
    const targetFilename = comptime getTargetPrefix();

    return std.mem.endsWith(u8, name, targetFilename orelse return false);
}

fn markExecutable(alloc: std.mem.Allocator, io: std.Io, exeName: []const u8, dir: std.Io.Dir) DecompressError!void {
    const targetFilename = blk: {
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind == .file and std.mem.startsWith(u8, entry.name, exeName)) {
                break :blk try alloc.dupe(u8, entry.name);
            }
        } else {
            @branchHint(.unlikely);
            logger.err("target exe file not found.", .{});
            return error.FailedUnzipping;
        }
    };
    defer alloc.free(targetFilename);

    dir.rename(targetFilename, dir, exeName, io) catch {
        @branchHint(.unlikely);
        logger.err("failed renaming {s} to {s}", .{ targetFilename, exeName });
        dir.deleteTree(io, targetFilename) catch {};
        return error.FailedUnzipping;
    };

    const exeFile = dir.openFile(io, exeName, .{}) catch {
        @branchHint(.unlikely);
        logger.err("failed openning {s}", .{exeName});
        dir.deleteTree(io, exeName) catch {};
        return error.FailedUnzipping;
    };
    defer exeFile.close(io);

    exeFile.setPermissions(io, .executable_file) catch {
        @branchHint(.unlikely);
        logger.err("failed changing mod for {s}", .{exeName});
        dir.deleteTree(io, exeName) catch {};
        return error.FailedUnzipping;
    };
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    compression: compress.Compression,
    targetFile: std.Io.File,
    tmpDir: std.Io.Dir,
) DecompressError!std.Io.Dir {
    const exeName = "zf";

    if (common.dirContainsFileWithLog(io, tmpDir, exeName, logger, "using already decompressed {s}")) {
        return tmpDir;
    }

    switch (compression) {
        .xz => try compress.decompressXzDir(alloc, io, targetFile, tmpDir),
        else => unreachable,
    }

    if (common.dirContainsFileWithLog(io, tmpDir, exeName, logger, "decompressed {s}")) {
        if (builtin.target.os.tag != .windows) {
            try markExecutable(alloc, io, exeName, tmpDir);
        }

        return tmpDir;
    }

    return error.FailedUnzipping;
}

fn getTargetPrefix() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .linux => "linux",
        .macos => "macos",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };

    return std.fmt.comptimePrint("{s}-{s}.tar.xz", .{ arch, os });
}
