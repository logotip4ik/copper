const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");

const common = @import("./common.zig");

const logger = std.log.scoped(.lazygit);

const GITHUB_API_URL = "https://api.github.com/repos/bensadeh/tailspin/releases";

pub const interface: common.ConfInterface = .{
    .getDownloadTargets = fetchVersions,
    .decompressTargetFile = decompressTargetFile,
};

fn matchingAsset(name: []const u8) bool {
    const targetFilename = comptime getTargetFilename();

    return std.ascii.endsWithIgnoreCase(name, targetFilename);
}

const DownloadTargets = common.DownloadTargets;
const DownloadTargetError = common.DownloadTargetError;
fn fetchVersions(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    progress: std.Progress.Node,
) DownloadTargetError!DownloadTargets {
    var stream: std.io.Writer.Allocating = .init(alloc);
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

    var targets: DownloadTargets = .empty;
    errdefer {
        for (targets.items) |item| item.deinit(alloc);
        targets.deinit(alloc);
    }

    for (json.value.array.items) |value| {
        const target = common.githubReleaseToDownloadTarget(
            alloc,
            logger,
            value.object,
            common.stripV,
            matchingAsset,
        ) catch return error.FailedConvertingToDownloadTarget;

        if (target) |t| {
            const space = targets.addOne(alloc) catch unreachable;
            space.* = t;
        }
    }

    return targets;
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: common.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    const exeName = "tspin";

    var iter = tmpDir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, exeName)) {
            logger.info("using already decompressed {s}", .{entry.name});
            return tmpDir;
        }
    }

    switch (compression) {
        .gz => try common.decompressGzDir(alloc, targetFile, tmpDir),
        .zip => try common.decompressZipDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    iter = tmpDir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, exeName)) {
            logger.info("decompressed {s}", .{entry.name});
            return tmpDir;
        }
    }

    return error.FailedUnzipping;
}

fn getTargetFilename() []const u8 {
    const os_tag = switch (builtin.target.os.tag) {
        .macos => "apple-darwin",
        .linux => "unknown-linux-musl",
        .windows => "pc-windows-msvc",
        else => @compileError("Unsupported OS"),
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => @compileError("Unsupported CPU"),
    };

    const extension = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("tailspin-{s}-{s}.{s}", .{ arch, os_tag, extension });
}
