const std = @import("std");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.skhd);

pub const interface: common.ConfInterface = .{
    .name = "skhd",
    .type = .Package,
    .getDownloadTargets = getDownloadTargets,
    .decompressTargetFile = common.decompressFirstDir,
    .buildTarget = buildTarget,
};

const TAGS_URL = "https://api.github.com/repos/koekeishiya/skhd/tags";

const DownloadTarget = common.DownloadTarget;
const DownloadTargets = common.DownloadTargets;
const DownloadTargetError = common.DownloadTargetError;
fn getDownloadTargets(
    alloc: std.mem.Allocator,
    _: std.Io,
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

        targets.appendAssumeCapacity(entry);
    }

    return targets;
}

const BuildFromSourceError = common.BuildFromSourceError;
fn buildTarget(
    alloc: std.mem.Allocator,
    io: std.Io,
    progress: std.Progress.Node,
    sourceDir: std.Io.Dir,
    _: common.BuildTargetContext,
) BuildFromSourceError!std.Io.Dir {
    progress.setEstimatedTotalItems(1);
    defer progress.completeOne();

    logger.info("checking if make is installed", .{});
    const isMakeInstalled = common.isMakeInstalled(alloc, io);
    if (!isMakeInstalled) {
        logger.info("please install make before proceeding", .{});
        return BuildFromSourceError.DepsNotInstalled;
    }

    common.run(alloc, io, &.{"make"}, .{ .cwdDir = sourceDir }) catch |err| {
        logger.err("failed building with {s}", .{@errorName(err)});
        return BuildFromSourceError.FailedBuilding;
    };

    return sourceDir.openDir(io, "bin", .{}) catch BuildFromSourceError.FailedBuilding;
}
