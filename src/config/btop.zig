const std = @import("std");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.btop);

pub const interface: common.ConfInterface = .{
    .name = "btop",
    .type = .Package,
    .getDownloadTargets = getDownloadTargets,
    .decompressTargetFile = decompressTargetFile,
    .buildTarget = buildTarget,
};

const TAGS_URL = "https://api.github.com/repos/aristocratos/btop/tags";

const DownloadTarget = common.DownloadTarget;
const DownloadTargets = common.DownloadTargets;
const DownloadTargetError = common.DownloadTargetError;
fn getDownloadTargets(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    progress: std.Progress.Node,
) DownloadTargetError!DownloadTargets {
    var stream: std.Io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    progress.setEstimatedTotalItems(1);

    const res = client.fetch(.{
        .method = .GET,
        .keep_alive = false,
        .headers = consts.DEFAULT_HEADERS,
        .location = .{ .url = TAGS_URL },
        .response_writer = &stream.writer,
    }) catch |err| {
        logger.err("{s} request failed with {s}", .{ TAGS_URL, @errorName(err) });
        return DownloadTargetError.FailedFetchingVersionJson;
    };

    progress.completeOne();

    if (res.status != .ok or stream.written().len == 0) {
        logger.err("failed fetching {s}, status: {s}, body size: {d}", .{
            TAGS_URL,
            @tagName(res.status),
            stream.written().len,
        });
        return DownloadTargetError.FailedFetchingVersionJson;
    }

    var targets: DownloadTargets = try .initCapacity(alloc, 1);
    errdefer {
        for (targets.items) |item| item.deinit(alloc);
        targets.deinit(alloc);
    }

    const json: std.json.Parsed(std.json.Value) = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        stream.written(),
        .{},
    ) catch return DownloadTargetError.FailedParsingJson;
    defer json.deinit();

    const tags = switch (json.value) {
        .array => |arr| arr,
        else => return DownloadTargetError.InvalidJson,
    };

    if (tags.items.len > 0) {
        const entry = common.githubTagToDownloadTarget(alloc, logger, tags.items[0], common.stripV) catch |err| {
            logger.err("failed converting github tag to download target with {s}", .{@errorName(err)});
            return DownloadTargetError.FailedConvertingToDownloadTarget;
        };

        targets.append(alloc, entry) catch return DownloadTargetError.FailedConvertingToDownloadTarget;
    }

    return targets;
}

const Compression = common.Compression;
const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    if (common.openFirstDirWithLog(tmpDir, logger, "using cached decompressed {s}") catch null) |dir| {
        return dir;
    }

    switch (compression) {
        .gz => try compress.decompressGzDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    const dir = common.openFirstDirWithLog(tmpDir, logger, "decompressed {s}") catch return error.FailedUnzipping;
    return dir orelse error.FailedUnzipping;
}

const BuildFromSourceError = common.BuildFromSourceError;
fn buildTarget(
    alloc: std.mem.Allocator,
    progress: std.Progress.Node,
    sourceDir: std.fs.Dir,
    _: []const u8,
) BuildFromSourceError!std.fs.Dir {
    progress.setEstimatedTotalItems(1);
    defer progress.completeOne();

    logger.info("checking if make is installed", .{});
    const isMakeInstalled = common.isMakeInstalled(alloc);
    if (!isMakeInstalled) {
        logger.info("please install make before proceeding", .{});
        return BuildFromSourceError.DepsNotInstalled;
    }

    var buildProcess: std.process.Child = .init(&.{
        "make",
        "ADDFLAGS=-march=native",
        "QUIET=true",
    }, alloc);
    buildProcess.stdin_behavior = .Ignore;
    buildProcess.stdout_behavior = .Ignore;
    buildProcess.stderr_behavior = .Inherit;
    buildProcess.cwd_dir = sourceDir;
    buildProcess.create_no_window = true;
    buildProcess.progress_node = progress;
    const term = buildProcess.spawnAndWait() catch return BuildFromSourceError.FailedSpawinngProcess;

    switch (term) {
        .Exited => |e| {
            if (e != 0) return BuildFromSourceError.FailedBuilding;
        },
        else => return BuildFromSourceError.FailedBuilding,
    }

    return sourceDir.openDir("bin", .{}) catch BuildFromSourceError.FailedBuilding;
}
