const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");

const common = @import("./common.zig");

const logger = std.log.scoped(.zf);

const GITHUB_API_URL = "https://api.github.com/repos/natecraddock/zf/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "zf",
    .type = .Package,
    .getDownloadTargets = fetchVersions,
    .decompressTargetFile = decompressTargetFile,
};

fn matchingAsset(name: []const u8) bool {
    const targetFilename = comptime getTargetPrefix();

    return std.mem.endsWith(u8, name, targetFilename orelse return false);
}

const DownloadTargets = common.DownloadTargets;
const DownloadTargetError = common.DownloadTargetError;
fn fetchVersions(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    progress: std.Progress.Node,
) DownloadTargetError!DownloadTargets {
    var stream: std.Io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    progress.setEstimatedTotalItems(1);

    const result = client.fetch(.{
        .method = .GET,
        .location = .{ .url = GITHUB_API_URL },
        .response_writer = &stream.writer,
        .headers = consts.DEFAULT_HEADERS,
        .keep_alive = false,
    }) catch |err| {
        logger.err("Error while fetching: {s}\n", .{@errorName(err)});
        return error.FailedFetchingVersionJson;
    };

    progress.completeOne();

    if (result.status != .ok or stream.written().len == 0) {
        return error.FailedFetchingVersionJson;
    }

    const json: std.json.Parsed(std.json.Value) = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        stream.written(),
        .{},
    ) catch return error.FailedParsingJson;
    defer json.deinit();

    var targets: DownloadTargets = try .initCapacity(alloc, 1);
    errdefer {
        for (targets.items) |item| item.deinit(alloc);
        targets.deinit(alloc);
    }

    const target = common.githubReleaseToDownloadTarget(
        alloc,
        logger,
        json.value.object,
        common.stripV,
        matchingAsset,
    ) catch return error.FailedConvertingToDownloadTarget;

    if (target) |t| {
        targets.appendAssumeCapacity(t);
    }

    return targets;
}

fn markExecutanle(alloc: std.mem.Allocator, exeName: []const u8, dir: std.fs.Dir) DecompressError!void {
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
    compression: common.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    const exeName = "zf";

    if (common.dirContainsFileWithLog(tmpDir, exeName, logger, "using already decompressed {s}")) {
        return tmpDir;
    }

    switch (compression) {
        .xz => try common.decompressXzDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    if (common.dirContainsFileWithLog(tmpDir, exeName, logger, "decompressed {s}")) {
        if (builtin.target.os.tag != .windows) {
            try markExecutanle(alloc, exeName, tmpDir);
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
