const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");

const common = @import("./common.zig");

const logger = std.log.scoped(.delta);

const GITHUB_API_URL = "https://api.github.com/repos/dandavison/delta/releases";

pub const interface: common.ConfInterface = .{
    .getDownloadTargets = fetchVersions,
    .decompressTargetFile = decompressTargetFile,
};

fn versionToSemVer(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}", .{version});
}

const DownloadTarget = common.DownloadTarget;
fn toDownloadTarget(
    alloc: std.mem.Allocator,
    release: std.json.ObjectMap,
) !?DownloadTarget {
    const tagNameValue = release.get("tag_name") orelse return null;

    const versionString = try alloc.dupe(u8, tagNameValue.string);
    errdefer alloc.free(versionString);

    const version = std.SemanticVersion.parse(versionString) catch |err| {
        logger.warn("Failed to parse version '{s}': {}", .{ versionString, err });
        return null;
    };

    const assetsValue = release.get("assets") orelse return error.InvalidRelease;
    const targetFilename = comptime try getTargetFilename();

    for (assetsValue.array.items) |asset| {
        const name = asset.object.get("name") orelse continue;

        if (!std.mem.endsWith(u8, name.string, targetFilename)) {
            continue;
        }

        const downloadUrlValue = asset.object.get("browser_download_url") orelse continue;
        const tarball = try alloc.dupe(u8, downloadUrlValue.string);
        errdefer alloc.free(tarball);

        const digest = asset.object.get("digest") orelse return error.InvalidReleaseJson;
        var shasum: ?[]const u8 = null;
        errdefer if (shasum) |sum| alloc.free(sum);

        switch (digest) {
            .string => {
                shasum = try alloc.dupe(u8, digest.string[("sha256:".len)..]);
            },
            else => {},
        }

        return DownloadTarget{
            .versionString = versionString,
            .version = version,
            .tarball = tarball,
            .shasum = shasum,
        };
    }

    alloc.free(versionString);
    return null;
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
        .gz => {
            const fileBuf = alloc.alloc(u8, 32 * 1024 * 1024) catch return error.FailedAllocatingBuffer;
            defer alloc.free(fileBuf);

            var fileReader = targetFile.reader(fileBuf);

            const decompressBuf = alloc.alloc(u8, 32 * 1024 * 1024) catch return error.FailedAllocatingBuffer;
            defer alloc.free(decompressBuf);
            var decompressed = std.compress.flate.Decompress.init(&fileReader.interface, .gzip, decompressBuf);

            std.tar.pipeToFileSystem(tmpDir, &decompressed.reader, .{
                .mode_mode = .executable_bit_only,
            }) catch return error.FailedUnzipping;
        },
        .zip => {
            const fileBuf = alloc.alloc(u8, 32 * 1024 * 1024) catch return error.FailedAllocatingBuffer;
            defer alloc.free(fileBuf);

            var fileReader = targetFile.reader(fileBuf);

            std.zip.extract(tmpDir, &fileReader, .{}) catch return error.FailedUnzipping;
        },
        else => unreachable,
    }

    const dir = common.openFirstDirWithLog(tmpDir, logger, "unzipped {s}") catch return error.FailedUnzipping;
    return dir orelse error.FailedUnzipping;
}

fn getTargetFilename() ![]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "apple-darwin",
        .linux => "unknown-linux-gnu",
        .windows => "pc-windows-msvc",
        else => return error.UnsupportedOS,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "i686",
        .arm => "arm",
        else => return error.UnsupportedCPU,
    };

    if (builtin.target.os.tag == .windows) {
        return std.fmt.comptimePrint("{s}-{s}.zip", .{ arch, os });
    }

    return std.fmt.comptimePrint("{s}-{s}.tar.gz", .{ arch, os });
}
