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
    .getDownloadTargets = common.FetchGithubRelease(.{
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

fn markExecutable(alloc: std.mem.Allocator, exeName: []const u8, dir: std.fs.Dir) DecompressError!void {
    const targetFilename = blk: {
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
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

    dir.rename(targetFilename, exeName) catch {
        @branchHint(.unlikely);
        logger.err("failed renaming {s} to {s}", .{ targetFilename, exeName });
        dir.deleteTree(targetFilename) catch {};
        return error.FailedUnzipping;
    };

    const exeFile = dir.openFile(exeName, .{}) catch {
        @branchHint(.unlikely);
        logger.err("failed openning {s}", .{exeName});
        dir.deleteTree(exeName) catch {};
        return error.FailedUnzipping;
    };
    defer exeFile.close();

    exeFile.chmod(0o755) catch {
        @branchHint(.unlikely);
        logger.err("failed changing mod for {s}", .{exeName});
        dir.deleteTree(exeName) catch {};
        return error.FailedUnzipping;
    };
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: compress.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    const exeName = "zf";

    if (common.dirContainsFileWithLog(tmpDir, exeName, logger, "using already decompressed {s}")) {
        return tmpDir;
    }

    switch (compression) {
        .xz => try compress.decompressXzDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    if (common.dirContainsFileWithLog(tmpDir, exeName, logger, "decompressed {s}")) {
        if (builtin.target.os.tag != .windows) {
            try markExecutable(alloc, exeName, tmpDir);
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
