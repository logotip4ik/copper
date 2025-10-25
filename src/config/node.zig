const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");

const common = @import("./common.zig");

const logger = std.log.scoped(.node);

const MIRROR_URLS = .{"https://nodejs.org/dist"};

pub const interface: common.ConfInterface = .{
    .binPath = "bin",
    .getDownloadTargets = fetchVersions,
    .decompressTargetFile = decompressTargetFile,
    .getTarballShasum = getTarballShasum,
};

const GetTarballShasumError = common.GetTarballShasumError;
fn getTarballShasum(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    target: DownloadTarget,
    progress: std.Progress.Node,
) GetTarballShasumError![]const u8 {
    var stream: std.io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    const shasumTxtUrl = std.fmt.allocPrint(alloc, "{s}/v{f}/SHASUMS256.txt", .{ MIRROR_URLS[0], target.version }) catch unreachable;
    defer alloc.free(shasumTxtUrl);

    const shasumRes = client.fetch(.{
        .method = .GET,
        .location = .{ .url = shasumTxtUrl },
        .headers = consts.DEFAULT_HEADERS,
        .keep_alive = false,
        .response_writer = &stream.writer,
    }) catch return error.FailedFetching;

    progress.completeOne();

    if (shasumRes.status != .ok or stream.written().len == 0) {
        return error.FailedFetching;
    }

    const tarballFilename = getTarballFilename(alloc, target.version) catch return error.FailedGeneratingTarballName;
    defer alloc.free(tarballFilename);

    const written = stream.written();

    var lineIter = std.mem.splitScalar(u8, written, '\n');
    while (lineIter.next()) |line| {
        if (line.len == 0) continue;

        var chunkIter = std.mem.splitSequence(u8, line, "  ");

        const shasum = chunkIter.next() orelse return error.InvalidShasumFile;
        const filename = chunkIter.next() orelse return error.InvalidShasumFile;

        if (std.mem.eql(u8, filename, tarballFilename)) {
            logger.info("fetched verification shasum {s}", .{shasum});

            return alloc.dupe(u8, shasum) catch unreachable;
        }
    }

    return error.ShasumNotFound;
}

const DownloadTarget = common.DownloadTarget;
fn toDownloadTarget(
    alloc: std.mem.Allocator,
    object: std.json.ObjectMap,
) !?DownloadTarget {
    const targetString = comptime try getTargetString();

    const filesValue = object.get("files") orelse return null;

    for (filesValue.array.items) |itemValue| {
        if (std.mem.eql(u8, targetString, itemValue.string)) {
            break;
        }
    } else {
        return null;
    }

    const versionValue = object.get("version") orelse return null;
    const versionString = try alloc.dupe(u8, versionValue.string[1..]);
    errdefer alloc.free(versionString);

    const version = try std.SemanticVersion.parse(versionString);

    const filename = try getTarballFilename(alloc, version);
    defer alloc.free(filename);

    const tarball = try std.fmt.allocPrint(
        alloc,
        "{s}/v{f}/{s}",
        .{ MIRROR_URLS[0], version, filename },
    );
    errdefer alloc.free(tarball);

    return DownloadTarget{
        .versionString = versionString,
        .version = version,
        .tarball = tarball,
    };
}

const DownloadTargets = common.DownloadTargets;
const DownloadTargetError = common.DownloadTargetError;
fn fetchVersions(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    progress: std.Progress.Node,
) DownloadTargetError!DownloadTargets {
    const mirror = MIRROR_URLS[0];
    const url = std.fmt.comptimePrint("{s}/{s}", .{ mirror, "index.json" });

    var stream: std.io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    const result = client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
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
        const target = toDownloadTarget(
            alloc,
            value.object,
        ) catch return error.FailedConvertingToDownloadTarget;

        if (target) |t| {
            const space = targets.addOne(alloc) catch unreachable;

            space.* = t;
        }
    }

    return targets;
}

const DecompressError = common.DecompressError;
const DecompressResult = common.DecompressResult;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: common.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    if (common.openFirstDirWithLog(tmpDir, logger, "using cached unzipped {s}") catch null) |dir| {
        return dir;
    }

    switch (compression) {
        .xz => {
            var decompressed = std.compress.xz.decompress(alloc, targetFile.deprecatedReader()) catch return error.FailedCreatingDecompressor;
            defer decompressed.deinit();

            var decompressedReader = decompressed.reader();

            const outwriterBuf = alloc.alloc(u8, 64 * 1024 * 1024) catch return error.FailedAllocatingBuffer;
            defer alloc.free(outwriterBuf);
            var newreader = decompressedReader.adaptToNewApi(outwriterBuf);

            std.tar.pipeToFileSystem(tmpDir, &newreader.new_interface, .{
                .mode_mode = .executable_bit_only,
            }) catch return error.FailedUnzipping;
        },
        .zip => {
            const fileBuf = alloc.alloc(u8, 32 * 1024 * 1024) catch return error.FailedAllocatingBuffer;
            defer alloc.free(fileBuf);

            var fileReader = targetFile.reader(fileBuf);

            std.zip.extract(tmpDir, &fileReader, .{}) catch return error.FailedUnzipping;
        },
        .gz => unreachable,
    }


    const dir = common.openFirstDirWithLog(tmpDir, logger, "unzipped {s}") catch return error.FailedUnzipping;
    return dir orelse error.FailedUnzipping;
}

fn getTargetString() ![]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "osx",
        .linux => "linux",
        .aix => "aix",
        .windows => "win",
        else => return error.UnsupportedOS,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .powerpc64 => "ppc64",
        .powerpc64le => "ppc64le",
        .s390x => "s390x",
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => return error.UnsupportedCPU,
    };

    if (builtin.target.os.tag == .macos) {
        return std.fmt.comptimePrint("{s}-{s}-tar", .{ os, arch });
    }

    if (builtin.target.os.tag == .windows) {
        return std.fmt.comptimePrint("{s}-{s}-zip", .{ os, arch });
    }

    return std.fmt.comptimePrint("{s}-{s}", .{ os, arch });
}

fn getTarballFilename(alloc: std.mem.Allocator, version: std.SemanticVersion) ![]const u8 {
    const osName = switch (builtin.target.os.tag) {
        .macos => "darwin",
        .windows => "win",
        .linux => "linux",
        .aix => "aix",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .aarch64 => "arm64",
        .s390x => "s390x",
        .x86_64 => "x64",
        .powerpc64 => "ppc64",
        .powerpc64le => "ppc64le",
        // not sure about this?
        .arm => "arm7l",
        else => return null,
    };

    const ext = switch (builtin.target.os.tag) {
        .windows => ".zip",
        else => ".tar.xz",
    };

    return std.fmt.allocPrint(alloc, "node-v{f}-{s}-{s}{s}", .{
        version,
        osName,
        arch,
        ext,
    });
}
