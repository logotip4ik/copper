const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

pub const interface: common.ConfInterface = .{
    .type = .Runtime,
    .name = "rust",

    .binPath = "bin",
    .getDownloadTargets = getDownloadTargets,
    .decompressTargetFile = decompressTargetFile,
    .getTarballShasum = getTarballShasum,
};

const logger = std.log.scoped(.rust);

const GITHUB_RELEASES = "https://api.github.com/repos/rust-lang/rust/releases";
const TARBALL_URL_TEMPLATE = "https://static.rust-lang.org/dist/rust-{s}-{s}.tar.xz";

const GetTarballShasumError = common.GetTarballShasumError;
fn getTarballShasum(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    target: DownloadTarget,
    progress: std.Progress.Node,
) GetTarballShasumError!?[]const u8 {
    var stream: std.Io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    progress.setEstimatedTotalItems(1);

    const shasumTxtUrl = try std.fmt.allocPrint(alloc, "{s}.sha256", .{
        target.tarball orelse {
            logger.warn("expected {s} {s} to have prebuilt tarball url", .{
                interface.name,
                target.versionString,
            });
            return null;
        },
    });
    defer alloc.free(shasumTxtUrl);

    const shasumRes = client.fetch(.{
        .method = .GET,
        .location = .{ .url = shasumTxtUrl },
        .headers = consts.DEFAULT_HEADERS,
        .keep_alive = false,
        .response_writer = &stream.writer,
    }) catch return GetTarballShasumError.FailedFetching;

    progress.completeOne();

    const written = stream.written();

    if (shasumRes.status != .ok or written.len == 0) {
        return GetTarballShasumError.FailedFetching;
    }

    const firstSpace = std.mem.indexOfScalar(u8, written, ' ') orelse return GetTarballShasumError.ShasumNotFound;
    const shasum = written[0..firstSpace];

    return try alloc.dupe(u8, shasum);
}

const DownloadTarget = common.DownloadTarget;
fn toDownloadTarget(
    alloc: std.mem.Allocator,
    release: std.json.ObjectMap,
    targetString: []const u8,
) !DownloadTarget {
    const versionValue = release.get("tag_name") orelse return error.MissingTagName;
    const versionString = try alloc.dupe(u8, versionValue.string);
    errdefer alloc.free(versionString);

    const version = try std.SemanticVersion.parse(versionString);

    const tarball = try std.fmt.allocPrint(alloc, TARBALL_URL_TEMPLATE, .{
        versionString,
        targetString,
    });
    errdefer alloc.free(tarball);

    return DownloadTarget{
        .versionString = versionString,
        .version = version,
        .shasum = null,
        .tarball = tarball,
    };
}

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

    const result = client.fetch(.{
        .method = .GET,
        .location = .{ .url = GITHUB_RELEASES },
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

    const targetString = comptime getTargetString();
    if (targetString == null) {
        return targets;
    }

    for (json.value.array.items) |value| {
        const target = toDownloadTarget(
            alloc,
            value.object,
            targetString.?,
        ) catch |err| {
            value.dump();
            logger.warn("failed coverting json above to download target with {s} error", .{
                @errorName(err),
            });
            continue;
        };

        try targets.append(alloc, target);
    }

    return targets;
}

fn ensureContainingDirExists(parent: std.fs.Dir, path: []const u8) void {
    const endOfChunk = std.mem.indexOfScalar(u8, path, std.fs.path.sep) orelse return;
    const chunkToCheck = path[0..endOfChunk];

    var dir = parent.makeOpenPath(chunkToCheck, .{}) catch return;
    defer dir.close();

    ensureContainingDirExists(dir, path[endOfChunk + 1 ..]);
}

test "ensureContainingDirExists" {
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const filePath = "share/doc/clippy/LICENSE";
    ensureContainingDirExists(tmpDir.dir, filePath);

    var folder = try tmpDir.dir.openDir(
        std.fs.path.dirname(filePath) orelse unreachable,
        .{},
    );
    defer folder.close();
}

fn copyComponent(
    noalias componentName: []const u8,
    componentDir: std.fs.Dir,
    noalias portableDirPath: []const u8,
    portableDir: std.fs.Dir,
) void {
    const manifestFile = componentDir.openFile("manifest.in", .{}) catch {
        logger.warn("{s} component is missing manifest.in", .{componentName});
        return;
    };
    defer manifestFile.close();

    var dirCheckBuf: [128]usize = undefined;
    var dirChecks: std.array_list.Aligned(usize, null) = .initBuffer(&dirCheckBuf);

    var manifestReaderBuf: [4 * 1024]u8 = undefined;
    var manifestReader = manifestFile.reader(&manifestReaderBuf);

    var componentDirPathBuf: [std.fs.max_path_bytes]u8 = undefined;
    const componentDirPath = componentDir.realpath(".", &componentDirPathBuf) catch unreachable;

    var pathBuf1: [std.fs.max_path_bytes]u8 = undefined;
    var pathBuf2: [std.fs.max_path_bytes]u8 = undefined;

    while (manifestReader.interface.takeDelimiter('\n') catch null) |line| {
        if (!std.mem.startsWith(u8, line, "file:")) {
            logger.warn("unuexpected line prefix in {s}/manifest.in: {s}", .{ componentName, line });
            continue;
        }

        const filepathToCopy = line["file:".len..];

        const dirPath = std.fs.path.dirname(filepathToCopy) orelse unreachable;
        const dirPathHash = std.hash.Wyhash.hash(0, dirPath);

        if (!std.mem.containsAtLeastScalar(usize, dirChecks.items, 1, dirPathHash)) {
            dirChecks.appendAssumeCapacity(dirPathHash);
            ensureContainingDirExists(portableDir, filepathToCopy);
        }

        const pathInPortable = std.fmt.bufPrint(&pathBuf1, "{s}{c}{s}", .{
            portableDirPath,
            std.fs.path.sep,
            filepathToCopy,
        }) catch {
            logger.err("copying {s}{c}{s} would result in error as resulting path exceeds maximum path length", .{
                portableDirPath,
                std.fs.path.sep,
                filepathToCopy,
            });
            continue;
        };

        const pathInComponent = std.fmt.bufPrint(&pathBuf2, "{s}{c}{s}", .{
            componentDirPath,
            std.fs.path.sep,
            filepathToCopy,
        }) catch {
            logger.err("copying {s}{c}{s} would result in error as resulting path exceeds maximum path length", .{
                componentDirPath,
                std.fs.path.sep,
                filepathToCopy,
            });
            continue;
        };

        std.fs.copyFileAbsolute(pathInComponent, pathInPortable, .{}) catch |err| {
            logger.err("failed copying {s} to {s} with {s}", .{
                pathInComponent,
                pathInPortable,
                @errorName(err),
            });
            continue;
        };
    }
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: compress.Compression,
    target: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    var rustDir = if (common.openFirstDirWithLog(tmpDir, logger, "using decompressed {s}") catch null) |dir|
        dir
    else blk: {
        switch (compression) {
            .xz => try compress.decompressXzDir(alloc, target, tmpDir),
            else => {
                logger.err("received unuexpected comppresiion for tarball: {s}", .{@tagName(compression)});
                return DecompressError.FailedUnzipping;
            },
        }

        if (common.openFirstDirWithLog(tmpDir, logger, "decompressed {s}")) |x| {
            break :blk x orelse {
                logger.err("decompressed folder missing resulting folder", .{});
                return DecompressError.FailedUnzipping;
            };
        } else |err| {
            logger.err("failed opening decompressed folder with {s}", .{@errorName(err)});
            return DecompressError.FailedUnzipping;
        }
    };
    defer rustDir.close();

    var portableDir = rustDir.makeOpenPath("portable", .{}) catch return DecompressError.FailedUnzipping;
    errdefer portableDir.close();

    var portableDirPathBuf: [std.fs.max_path_bytes]u8 = undefined;
    const portableDirPath = portableDir.realpath(".", &portableDirPathBuf) catch |err| {
        logger.err("failed reading realpath for portable folder with {s}", .{@errorName(err)});
        return DecompressError.FailedUnzipping;
    };

    var componentsFile = rustDir.openFile("components", .{}) catch return DecompressError.FailedOpeningFile;
    defer componentsFile.close();

    var componentsReaderBuf: [256]u8 = undefined;
    var componentsReader = componentsFile.reader(&componentsReaderBuf);

    while (componentsReader.interface.takeDelimiter('\n') catch null) |rawComponent| {
        const componentName = std.mem.trim(u8, rawComponent, &std.ascii.whitespace);
        if (componentName.len == 0) continue;

        const componentDir = rustDir.openDir(componentName, .{}) catch |err| {
            logger.warn("{s} component folder is missing. This may result in incomplete installation. err: {s}", .{
                componentName,
                @errorName(err),
            });
            continue;
        };

        copyComponent(componentName, componentDir, portableDirPath, portableDir);
    }

    return portableDir;
}

fn getTargetString() ?[]const u8 {
    return switch (builtin.target.os.tag) {
        .windows => "x86_64-pc-windows-msvc",
        .macos => switch (builtin.target.cpu.arch) {
            .aarch64 => "aarch64-apple-darwin",
            .x86_64 => "x86_64-apple-darwin",
            else => null,
        },
        .linux => switch (builtin.target.cpu.arch) {
            .aarch64 => "x86_64-unknown-linux-gnu",
            .x86_64 => "aarch64-unknown-linux-gnu",
            else => null,
        },
        else => null,
    };
}
