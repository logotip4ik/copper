const std = @import("std");
const builtin = @import("builtin");

const compress = @import("compress");
const consts = @import("consts");
const common = @import("./common.zig");

const logger = std.log.scoped(.git);

pub const interface: common.ConfInterface = .{
    .name = "git",
    .type = .Package,
    .binPath = "bin",

    .getDownloadTargets = getDownloadTargets,
    .decompressTargetFile = decompressTargetFile,
    .buildTarget = buildTarget,
};

const TAGS_URL = "https://api.github.com/repos/git/git/tags";

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

    if (tags.items.len > 0) for (tags.items) |item| {
        const entry = common.githubTagToDownloadTarget(alloc, logger, item, common.stripV) catch |err| {
            logger.err("failed converting github tag to download target with {s}", .{@errorName(err)});
            return DownloadTargetError.FailedConvertingToDownloadTarget;
        };

        if (entry.version.build != null or entry.version.pre != null) {
            entry.deinit(alloc);
            continue;
        }

        targets.append(alloc, entry) catch return DownloadTargetError.FailedConvertingToDownloadTarget;
        break;
    };

    return targets;
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: compress.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
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
    context: common.BuildTargetContext,
) BuildFromSourceError!std.fs.Dir {
    progress.setEstimatedTotalItems(1);
    defer progress.completeOne();

    logger.info("checking if make is installed", .{});
    const isMakeInstalled = common.isMakeInstalled(alloc);
    if (!isMakeInstalled) {
        logger.info("please install make before proceeding", .{});
        return BuildFromSourceError.DepsNotInstalled;
    }

    var prefixBuf: ["prefix=".len + std.fs.max_path_bytes]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefixBuf, "prefix={s}", .{context.targetDirPath}) catch unreachable;

    const args = [_][]const u8{
        // "NO_PERL=1",
        "NO_PYTHON=1",
        "NO_TCLTK=1",
        "NO_GETTEXT=1",
        "NO_GITWEB=1",
        "DEVELOPER_CFLAGS=-march=native",
        "INSTALL_SYMLINKS=1",
        "DESTDIR=./",
    };

    const osArgs = comptime switch (builtin.target.os.tag) {
        .macos => [_][]const u8{
            "NO_FINK=1",
            "NO_DARWIN_PORTS=1",
            "NO_OPENSSL=1",
            "APPLE_COMMON_CRYPTO=1",
        },
        else => [_][]const u8{},
    };

    common.run(
        alloc,
        [_][]const u8{
            "make",
            prefix,
            "install",
        } ++ &args ++ &osArgs,
        .{ .cwdDir = sourceDir },
    ) catch return BuildFromSourceError.FailedBuilding;
    logger.info("compiled git", .{});

    const gitCore = std.fmt.allocPrint(alloc, "{s}/libexec/git-core", .{
        // skip leading slash, so it's relative to sourceDir
        context.targetDirPath[1..]}) catch unreachable;
    defer alloc.free(gitCore);

    if (builtin.os.tag == .macos) {
        install(
            alloc,
            "contrib/credential/osxkeychain",
            &.{"make"},
            "git-credential-osxkeychain",
            sourceDir,
            gitCore,
        );
    }

    blk: {
        var diffHighlightDir = sourceDir.openDir("contrib/diff-highlight", .{}) catch break :blk;
        defer diffHighlightDir.close();

        common.run(alloc, &.{"make"}, .{ .cwdDir = diffHighlightDir }) catch break :blk;
        logger.info("built diff-highlight", .{});
    }

    install(
        alloc,
        "contrib/credential/netrc",
        &.{ "make", "test" },
        "git-credential-netrc",
        sourceDir,
        gitCore,
    );

    install(
        alloc,
        "contrib/subtree",
        &.{"make"},
        "git-subtree",
        sourceDir,
        gitCore,
    );

    const outDir = sourceDir.openDir(context.targetDirPath[1..], .{}) catch return BuildFromSourceError.FailedBuilding;

    outDir.makeDir("share/git-core") catch {
        logger.err("failed creating share/git-core path", .{});
        return BuildFromSourceError.FailedBuilding;
    };
    const shareGitCorePath = std.fs.path.join(alloc, &[_][]const u8{
        context.targetDirPath[1..],
        "share",
        "git-core",
        "contrib",
    }) catch unreachable;
    defer alloc.free(shareGitCorePath);

    sourceDir.rename(
        "contrib",
        shareGitCorePath,
    ) catch return BuildFromSourceError.FailedBuilding;
    logger.info("moved contrib to {s} folder", .{shareGitCorePath});

    common.run(alloc, &.{ "make", "clean" }, .{ .cwdDir = sourceDir }) catch {
        logger.warn("failed cleaning build dir", .{});
    };

    return outDir;
}

fn install(
    alloc: std.mem.Allocator,
    comptime subPackagePath: []const u8,
    comptime runCommand: []const []const u8,
    comptime outputFilename: []const u8,
    sourceDir: std.fs.Dir,
    gitCorePath: []const u8,
) void {
    var dir = sourceDir.openDir(subPackagePath, .{}) catch return;
    defer dir.close();

    common.run(alloc, runCommand, .{ .cwdDir = dir }) catch return;
    logger.info("built {s}", .{outputFilename});

    const oldPath = std.fmt.allocPrint(alloc, "{s}{c}{s}", .{
        subPackagePath,
        std.fs.path.sep,
        outputFilename,
    }) catch unreachable;
    defer alloc.free(oldPath);

    const newPath = std.fmt.allocPrint(alloc, "{s}{c}{s}", .{
        gitCorePath,
        std.fs.path.sep,
        outputFilename,
    }) catch unreachable;
    defer alloc.free(newPath);

    sourceDir.rename(
        oldPath,
        newPath,
    ) catch |err| {
        logger.err("failed moving {s} to {s} with {s}", .{
            outputFilename,
            gitCorePath,
            @errorName(err),
        });
        return;
    };
    logger.info("installed {s}", .{outputFilename});

    common.run(alloc, &.{ "make", "clean" }, .{ .cwdDir = dir }) catch {};
}
