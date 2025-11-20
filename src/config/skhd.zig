const std = @import("std");

const consts = @import("consts");
const common = @import("./common.zig");

const logger = std.log.scoped(.skhd);

pub const interface: common.ConfInterface = .{
    .binPath = "bin",
    .getDownloadTargets = getDownloadTargets,
    .decompressTargetFile = decompressTargetFile,
    .buildTarget = buildTarget,
};

const TAGS_URL = "https://api.github.com/repos/koekeishiya/skhd/tags";

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

    var targets: DownloadTargets = .empty;
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

    for (tags.items) |item| {
        const tag = switch (item) {
            .object => |obj| obj,
            else => {
                logger.warn("encourted invalid tag in {s} json response", .{TAGS_URL});
                continue;
            },
        };

        const versionValue = tag.get("name") orelse continue;
        const versionString = common.stripV(
            alloc,
            switch (versionValue) {
                .string => |s| s,
                else => continue,
            },
        ) orelse continue;
        errdefer alloc.free(versionString);

        const version = std.SemanticVersion.parse(versionString) catch |err| {
            logger.err("failed converting {s} to semantic version with err {s}", .{ versionString, @errorName(err) });
            return DownloadTargetError.InvalidJson;
        };

        const sourceTarballValue = tag.get("tarball_url") orelse {
            logger.err("missing tarball_url field", .{});
            return DownloadTargetError.InvalidJson;
        };
        const sourceTarballString = switch (sourceTarballValue) {
            .string => |s| s,
            else => |v| {
                logger.err("invalid tarball_url field value, expected string, got: {any}", .{v});
                return DownloadTargetError.InvalidJson;
            },
        };
        const sourceTarball = alloc.dupe(u8, sourceTarballString) catch return DownloadTargetError.FailedConvertingToDownloadTarget;
        errdefer alloc.free(sourceTarball);

        targets.append(alloc, DownloadTarget{
            .versionString = versionString,
            .version = version,
            .tarball = sourceTarball,
        }) catch return DownloadTargetError.FailedConvertingToDownloadTarget;
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
        .gz => try common.decompressGzDir(alloc, targetFile, tmpDir),
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
) BuildFromSourceError!void {
    progress.setEstimatedTotalItems(1);
    defer progress.completeOne();

    logger.info("checking if make is installed", .{});
    // i know, naming is not great...
    var makeChild: std.process.Child = .init(&.{"make", "-v"}, alloc);
    makeChild.stdin_behavior = .Ignore;
    makeChild.stdout_behavior = .Ignore;
    makeChild.stderr_behavior = .Inherit;
    makeChild.create_no_window = true;
    makeChild.progress_node = progress;

    const res = makeChild.spawnAndWait() catch |err| {
        logger.err("failed spawining or waiting child process for checking if make exists: {s}", .{
            @errorName(err),
        });
        return BuildFromSourceError.FailedSpawinngProcess;
    };

    switch (res) {
        .Exited => |e| if (e != 0) {
            logger.err("please install 'make' before procesing", .{});
            return BuildFromSourceError.DepsNotInstalled;
        },
        .Signal, .Stopped, .Unknown => return BuildFromSourceError.Unknown,
    }

    logger.info("building skhd...", .{});
    var buildProcess: std.process.Child = .init(&.{"make", "install"}, alloc);
    buildProcess.stdin_behavior = .Ignore;
    buildProcess.stdout_behavior = .Ignore;
    buildProcess.stderr_behavior = .Pipe;
    buildProcess.cwd_dir = sourceDir;
    buildProcess.create_no_window = true;
    buildProcess.progress_node = progress;
    _ = buildProcess.spawnAndWait() catch return BuildFromSourceError.FailedSpawinngProcess;
}
