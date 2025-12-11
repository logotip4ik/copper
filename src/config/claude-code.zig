const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.@"claude-code");

const BASE_URL = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases";
const STABLE_VERSION_URL = BASE_URL ++ "/stable";

pub const interface: common.ConfInterface = .{
    .name = "claude-code",
    .type = .Package,
    .getDownloadTargets = fetchVersions,
    .decompressTargetFile = decompressTargetFile,
};

const DownloadTarget = common.DownloadTarget;
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
        .location = .{ .url = STABLE_VERSION_URL },
        .response_writer = &stream.writer,
        .headers = consts.DEFAULT_HEADERS,
        .keep_alive = false,
    }) catch |err| {
        logger.err("Error while fetching stable version: {s}\n", .{@errorName(err)});
        return error.FailedFetchingVersionJson;
    };

    progress.completeOne();

    if (result.status != .ok or stream.written().len == 0) {
        return error.FailedFetchingVersionJson;
    }

    const versionString = common.stripV(alloc, stream.written()) orelse return error.FailedConvertingToDownloadTarget;
    errdefer alloc.free(versionString);

    const version = std.SemanticVersion.parse(versionString) catch |err| {
        logger.err("Failed parsing version '{s}': {s}", .{ versionString, @errorName(err) });
        return error.FailedParsingJson;
    };

    var targets: DownloadTargets = .empty;
    errdefer {
        for (targets.items) |item| item.deinit(alloc);
        targets.deinit(alloc);
    }

    const target = comptime getTargetString();

    const tarball = std.fmt.allocPrint(alloc, "{s}/{s}/{s}/claude", .{
        BASE_URL,
        versionString,
        target orelse return targets,
    }) catch return error.FailedConvertingToDownloadTarget;
    errdefer alloc.free(tarball);

    targets.append(alloc, .{
        .versionString = versionString,
        .version = version,
        .tarball = tarball,
        .shasum = null,
    }) catch return error.FailedConvertingToDownloadTarget;

    return targets;
}

const DecompressError = common.DecompressError;

fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: compress.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    _ = alloc;

    std.debug.assert(compression == .uncompressed);

    var readerBuf: [64 * 1024]u8 = undefined;
    var reader = targetFile.reader(&readerBuf);

    const exeName = if (builtin.target.os.tag == .windows) "claude.exe" else "claude";

    if (common.dirContainsFileWithLog(tmpDir, "claude", logger, "using already decompressed {s}")) {
        return tmpDir;
    }

    const copy = tmpDir.createFile(exeName, .{}) catch return error.FailedCreatingCopyFile;
    defer copy.close();

    var writer = copy.writer(&.{});

    _ = reader.interface.streamRemaining(&writer.interface) catch return error.FailedCopying;

    if (builtin.target.os.tag != .windows) {
        copy.chmod(0o755) catch return error.FailedCopying;
    }

    logger.info("decompressed {s}", .{exeName});

    return tmpDir;
}

fn getTargetString() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "windows",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => return null,
    };

    return std.fmt.comptimePrint("{s}-{s}", .{ os, arch });
}
