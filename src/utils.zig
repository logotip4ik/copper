const std = @import("std");
const builtin = @import("builtin");
const buildOptions = @import("build_options");
const consts = @import("consts");

const Store = @import("./store.zig");
const common = @import("./config/common.zig");

const logger = std.log.scoped(.utils);

pub fn availableCommands(comptime T: type) []const u8 {
    const typeInfo = @typeInfo(T);
    const fields = typeInfo.@"enum".fields;

    return comptime string: {
        const length = blk: {
            var numberOfFields: u16 = 0;
            var summedFieldsLength: u16 = 0;

            for (fields) |field| {
                numberOfFields += 1;
                summedFieldsLength += field.name.len;
            }

            break :blk summedFieldsLength + (numberOfFields - 1) * 2;
        };
        var string: [length]u8 = undefined;

        var w = std.io.Writer.fixed(&string);
        defer w.flush() catch unreachable;

        for (fields, 0..) |field, i| {
            if (i == 0) {
                w.print("{s}", .{field.name}) catch unreachable;
            } else {
                w.print(", {s}", .{field.name}) catch unreachable;
            }
        }

        const final = string;

        break :string &final;
    };
}

pub fn getTargetFile(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    store: *const Store,
    tarball: []const u8,
) !std.fs.File {
    const filename = std.fs.path.basename(tarball);

    var hasCached = true;
    var downloadFile = store.tmpDir.openFile(filename, .{ .mode = .read_write }) catch |err| blk: switch (err) {
        error.FileNotFound => {
            hasCached = false;

            const file = store.tmpDir.createFile(filename, .{}) catch return error.UnableToOpenDownloadFile;
            file.close();

            break :blk store.tmpDir.openFile(filename, .{ .mode = .read_write }) catch return error.UnableToOpenDownloadFile;
        },
        else => return error.UnableToOpenDownloadFile,
    };
    errdefer downloadFile.close();

    if (hasCached and try downloadFile.getEndPos() != 0) {
        logger.info("using cached file from {f}", .{
            std.fs.path.fmtJoin(&[_][]const u8{
                store.tmpDirPath,
                filename,
            }),
        });
        return downloadFile;
    }

    try downloadFile.seekTo(0);

    const buffer = alloc.alloc(u8, 32 * 1024 * 1024) catch return error.FailedAllocatingDownloadBuffer;
    defer alloc.free(buffer);

    var fileWriter = downloadFile.writer(buffer);
    defer fileWriter.interface.flush() catch unreachable;

    logger.info("downloading to: {f}", .{
        std.fs.path.fmtJoin(&[_][]const u8{
            store.tmpDirPath,
            filename,
        }),
    });

    const res = client.fetch(.{
        .location = .{ .url = tarball },
        .headers = consts.DEFAULT_HEADERS,
        .keep_alive = false,
        .response_writer = &fileWriter.interface,
    }) catch return error.FailedWhileFetching;

    if (res.status != .ok) {
        return error.NotOkResponse;
    }

    return downloadFile;
}

const COPPER_LATEST_RELEASE = "https://api.github.com/repos/logotip4ik/copper/releases/latest";
pub fn updateSelf(
    alloc: std.mem.Allocator,
    store: *const Store,
    progress: std.Progress.Node
) !void {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var stream: std.io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    var fetchingRelease = progress.start("fetching latest release", 0);
    const res = client.fetch(.{
        .headers = consts.DEFAULT_HEADERS,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "Accept", .value = "application/vnd.github+json" },
            .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
        },
        .keep_alive = false,
        .location = .{ .url = COPPER_LATEST_RELEASE },
        .method = .GET,
        .response_writer = &stream.writer,
    }) catch return error.FailedFetchingLatestRelease;
    fetchingRelease.end();

    const writen = stream.written();

    if (res.status != .ok or writen.len == 0) {
        return error.FailedFetchingLatestRelease;
    }

    const json: std.json.Parsed(std.json.Value) = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        writen,
        .{},
    ) catch return error.FailedParsingReleaseJson;
    defer json.deinit();

    const latestTag = json.value.object.get("tag_name") orelse return error.InvalidReleaseJson;
    const latestVersion = try std.SemanticVersion.parse(latestTag.string[1..]);

    const currentVersion = buildOptions.version;

    if (latestVersion.order(currentVersion) != .gt) {
        logger.info("already using latest available {f} version", .{currentVersion});
        return;
    }

    logger.info("newer version {f} is available", .{latestVersion});

    const assets = json.value.object.get("assets") orelse return error.InvalidReleaseJson;
    const filename = try getCopperTarget();

    var target: common.DownloadTarget = undefined;

    for (assets.array.items) |asset| {
        const assetName = asset.object.get("name") orelse return error.InvalidReleaseJson;
        if (std.mem.eql(u8, filename, assetName.string)) {
            const assetDownload = asset.object.get("browser_download_url") orelse return error.InvalidReleaseJson;
            const tarball = try alloc.dupe(u8, assetDownload.string);
            errdefer alloc.free(tarball);

            const digest = asset.object.get("digest") orelse return error.InvalidReleaseJson;
            const shasum = try alloc.dupe(u8, digest.string[("sha256:".len)..]);
            errdefer alloc.free(shasum);

            const versionString = try alloc.dupe(u8, latestTag.string[1..]);
            errdefer alloc.free(versionString);

            const version = try std.SemanticVersion.parse(versionString);

            target = .{
                .tarball = tarball,
                .shasum = shasum,
                .versionString = versionString,
                .version = version,
            };
            break;
        }
    } else {
        return error.UnsupportedTarget;
    }

    defer target.deinit(alloc);

    const targetFile = try getTargetFile(alloc, &client, store, target.tarball);

    var verifyingShasumProgress = progress.start("verifying shasum", 0);
    if (!try Store.verifyShasum(alloc, &targetFile, target.shasum.?)) {
        try targetFile.setEndPos(0);
        return error.IncorrectShasum;
    }
    verifyingShasumProgress.end();
    std.log.info("shasum matches expected", .{});

    const tmpDir = try store.prepareTmpDirForDecompression(consts.EXE_NAME, target.version);

    const file = try decompressCopper(
        alloc,
        std.meta.stringToEnum(
            common.Compression,
            std.fs.path.extension(target.tarball)[1..],
        ) orelse return error.UnknownCompression,
        targetFile,
        tmpDir
    );
    defer alloc.free(file);

    var selfPathBuf: [std.fs.max_path_bytes]u8 = undefined;
    const selfPath = try std.fs.selfExePath(&selfPathBuf);

    try std.fs.deleteFileAbsolute(selfPath);
    try std.fs.renameAbsolute(file, selfPath);

    logger.info("updated {s} to {f}", .{consts.EXE_NAME, latestVersion});
}

fn decompressCopper(
    alloc: std.mem.Allocator,
    compression: common.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) ![]const u8 {
    var iter = tmpDir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "copper")) {
            logger.info("using already decompressed {s}", .{entry.name});
            return tmpDir.realpathAlloc(alloc, entry.name);
        }
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

        .gz => {
            const fileBuf = try alloc.alloc(u8, 32 * 1024 * 1024);
            defer alloc.free(fileBuf);

            var fileReader = targetFile.reader(fileBuf);

            const decompressBuf = try alloc.alloc(u8, 32 * 1024 * 1024);
            defer alloc.free(decompressBuf);
            var decompressed = std.compress.flate.Decompress.init(&fileReader.interface, .gzip, decompressBuf);

            const outwriterBuf = alloc.alloc(u8, 64 * 1024 * 1024) catch return error.FailedAllocatingBuffer;
            defer alloc.free(outwriterBuf);

            std.tar.pipeToFileSystem(tmpDir, &decompressed.reader, .{
                .mode_mode = .executable_bit_only,
            }) catch return error.FailedUnzipping;
        },

        .zip => {
            const fileBuf = try alloc.alloc(u8, 32 * 1024 * 1024);
            defer alloc.free(fileBuf);

            var fileReader = targetFile.reader(fileBuf);

            std.zip.extract(tmpDir, &fileReader, .{}) catch return error.FailedUnzipping;
        }
    }

    iter = tmpDir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "copper")) {
            logger.info("decompressed {s}", .{entry.name});
            return tmpDir.realpathAlloc(alloc, entry.name);
        }
    }

    return error.FailedUnzipping;
}

fn getCopperTarget() ![]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return error.UnsupportedTarget,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return error.UnsupportedTarget,
    };

    const ext = switch (builtin.target.os.tag) {
        .windows => ".zip",
        else => ".tar.gz",
    };

    return std.fmt.comptimePrint("copper-{s}-{s}{s}", .{ os, arch, ext });
}
