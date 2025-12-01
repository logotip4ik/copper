const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const minisign = @import("minisign");

const common = @import("./common.zig");

const MINISIGN_KEY = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";

const MIRRORS_URL = "https://ziglang.org/download/community-mirrors.txt";
const ZIG_DOWNLOADS = "https://ziglang.org/download";
const ZIG_BUILDS = "https://ziglang.org/builds";

const logger = std.log.scoped(.zig);

pub const interface: common.ConfInterface = .{
    .name = "zig",
    .type = .Runtime,
    .getDownloadTargets = fetchVersions,
    .decompressTargetFile = decompressTargetFile,
};

fn toDownloadTarget(
    alloc: std.mem.Allocator,
    noalias key: []const u8,
    value: *std.json.Value,
    noalias mirror: []const u8,
) !?DownloadTarget {
    const targetFilename = comptime getTargetString() orelse return null;

    const target = value.object.get(targetFilename) orelse return null;

    const versionValue = value.object.get("version");
    const versionString = try alloc.dupe(u8, if (versionValue) |v| v.string else key);
    errdefer alloc.free(versionString);

    const version = try std.SemanticVersion.parse(versionString);

    const shasumValue = target.object.get("shasum") orelse return error.NoShasumField;
    const shasum = try alloc.dupe(u8, shasumValue.string);
    errdefer alloc.free(shasum);

    const tarballValue = target.object.get("tarball") orelse return error.NoTarballField;
    const tarballName = std.fs.path.basename(tarballValue.string);

    const tarball = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ mirror, tarballName });
    errdefer alloc.free(tarball);

    return DownloadTarget{
        .version = version,
        .versionString = versionString,
        .shasum = shasum,
        .tarball = tarball,
    };
}

const MirrorList = std.array_list.Aligned([]const u8, null);
fn downloadMirrors(alloc: std.mem.Allocator, client: *std.http.Client) !MirrorList {
    var stream: std.Io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    var mirrors: std.array_list.Aligned([]const u8, null) = .empty;
    errdefer {
        for (mirrors.items) |mirror| alloc.free(mirror);
        mirrors.deinit(alloc);
    }

    const res = client.fetch(.{
        .method = .GET,
        .keep_alive = false,
        .headers = consts.DEFAULT_HEADERS,
        .location = .{ .url = MIRRORS_URL },
        .response_writer = &stream.writer,
    }) catch {
        logger.err("Failed fetching mirrors", .{});
        return DownloadTargetError.FailedFetchingVersionJson;
    };

    if (res.status != .ok or stream.written().len == 0) {
        logger.err("mirrors endpoint returned non ok status: {s}", .{@tagName(res.status)});
        return DownloadTargetError.FailedFetchingVersionJson;
    }

    var lineIter = std.mem.splitScalar(u8, stream.written(), '\n');
    while (lineIter.next()) |line| {
        if (line.len == 0) {
            continue;
        }

        try mirrors.append(alloc, try alloc.dupe(u8, line));
    }

    var r: std.Random.DefaultPrng = .init(@intCast(std.time.timestamp()));
    const random = r.random();

    random.shuffle([]const u8, mirrors.items);

    return mirrors;
}

const PUBKEY = minisign.PublicKey.decodeFromBase64(MINISIGN_KEY) catch unreachable;

const VerifyVersionJsonMinisignError = error{
    FailedFetching,
    FailedDecodingMinisig,
} || std.mem.Allocator.Error;
fn verifyVersionJsonMinisign(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    noalias minisigUrl: []const u8,
    noalias versionJsonBytes: []const u8,
) VerifyVersionJsonMinisignError!bool {
    var stream: std.Io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    logger.debug("fetching minisig for versions json file: {s}", .{minisigUrl});
    const res = client.fetch(.{
        .method = .GET,
        .keep_alive = false,
        .headers = consts.DEFAULT_HEADERS,
        .location = .{ .url = minisigUrl },
        .response_writer = &stream.writer,
    }) catch |err| {
        logger.err("{any}", .{err});
        return error.FailedFetching;
    };

    const written = stream.written();
    if (res.status != .ok or written.len == 0) {
        logger.err("status: {s}, written: {d}", .{ @tagName(res.status), written.len });
        return error.FailedFetching;
    }

    var sig = minisign.Signature.decode(alloc, written) catch return error.FailedDecodingMinisig;
    defer sig.deinit();

    logger.debug("verifing version json file...", .{});

    var verifier = PUBKEY.verifier(&sig) catch return false;

    // Chunks are important piece of this code...
    var chunker = std.mem.window(u8, versionJsonBytes, std.heap.page_size_max, std.heap.page_size_max);
    while (chunker.next()) |chunk| {
        verifier.update(chunk);
    }

    verifier.verify(alloc) catch return false;

    return true;
}

const DownloadTarget = common.DownloadTarget;
const DownloadTargets = common.DownloadTargets;
const DownloadTargetError = common.DownloadTargetError;
const VersionsMap = std.json.ArrayHashMap(std.json.Value);
fn fetchVersions(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    progress: std.Progress.Node,
) DownloadTargetError!DownloadTargets {
    progress.setEstimatedTotalItems(2);

    var stream: std.Io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    const versionMapUrl = std.fmt.comptimePrint("{s}/index.json?source={s}", .{
        ZIG_DOWNLOADS,
        consts.EXE_NAME,
    });

    const res = client.fetch(.{
        .method = .GET,
        .keep_alive = false,
        .headers = consts.DEFAULT_HEADERS,
        .location = .{ .url = versionMapUrl },
        .response_writer = &stream.writer,
    }) catch {
        logger.warn("Failed fetching versions json from {s}", .{versionMapUrl});
        return DownloadTargetError.FailedFetchingVersionJson;
    };
    progress.completeOne();

    const versionFileBytes = stream.written();
    if (res.status != .ok or versionFileBytes.len == 0) {
        logger.info("failed fetching versions file from {s}, status: {s}", .{
            ZIG_DOWNLOADS,
            @tagName(res.status),
        });
        return DownloadTargetError.FailedFetchingVersionJson;
    }

    const versionsMapJson: std.json.Parsed(VersionsMap) = std.json.parseFromSlice(
        VersionsMap,
        alloc,
        versionFileBytes,
        .{},
    ) catch {
        logger.warn("Failed parsing versions json from {s}", .{versionMapUrl});
        return DownloadTargetError.FailedParsingJson;
    };
    defer versionsMapJson.deinit();

    const masterTarget = versionsMapJson.value.map.get("master") orelse {
        logger.warn("versions file from {s} is missing \"master\" field", .{ZIG_DOWNLOADS});
        return DownloadTargetError.InvalidJson;
    };
    const masterVersion = masterTarget.object.get("version") orelse {
        logger.warn("versions file from {s} is missing \"master.version\" field", .{ZIG_DOWNLOADS});
        return DownloadTargetError.InvalidJson;
    };

    var urlBuf: [512]u8 = undefined;
    const minisigUrl = std.fmt.bufPrint(&urlBuf, "{s}/zig-{s}-index.json.minisig?source={s}", .{
        ZIG_BUILDS,
        masterVersion.string,
        consts.EXE_NAME,
    }) catch unreachable;

    const isVersionJsonValid = verifyVersionJsonMinisign(
        alloc,
        client,
        minisigUrl,
        versionFileBytes,
    ) catch |err| switch (err) {
        error.FailedFetching => {
            logger.warn("{s} failed fetching minisig for versions json file, trying next mirror", .{minisigUrl});
            return DownloadTargetError.FailedFetchingVersionJson;
        },
        error.FailedDecodingMinisig => {
            logger.warn("failed decoding minisig for versions json returned from {s}", .{minisigUrl});
            return DownloadTargetError.FailedFetchingVersionJson;
        },
        else => return @errorCast(err),
    };

    if (!isVersionJsonValid) {
        logger.err("minisig verification failed", .{});
        return DownloadTargetError.FailedFetchingVersionJson;
    }

    var mirrors = try downloadMirrors(alloc, client);
    defer {
        for (mirrors.items) |mirror| alloc.free(mirror);
        mirrors.deinit(alloc);
    }
    progress.completeOne();

    const mirrorToDownloadFrom = mirrors.items[0];

    var targets: DownloadTargets = .empty;
    errdefer {
        for (targets.items) |item| item.deinit(alloc);
        targets.deinit(alloc);
    }

    var verIter = versionsMapJson.value.map.iterator();

    // skip master version
    _ = verIter.next() orelse return targets;

    while (verIter.next()) |entry| {
        const target = toDownloadTarget(
            alloc,
            entry.key_ptr.*,
            entry.value_ptr,
            mirrorToDownloadFrom,
        ) catch return error.FailedConvertingToDownloadTarget;

        if (target) |t| {
            try targets.append(alloc, t);
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
    if (common.openFirstDirWithLog(tmpDir, logger, "using cached decompressed {s}") catch null) |dir| {
        return dir;
    }

    switch (compression) {
        .xz => try common.decompressXzDir(alloc, targetFile, tmpDir),
        .zip => try common.decompressZipDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    const dir = common.openFirstDirWithLog(tmpDir, logger, "decompressed {s}") catch return error.FailedUnzipping;
    return dir orelse error.FailedUnzipping;
}

fn getTargetString() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .windows => "windows",
        .linux => "linux",
        .freebsd => "freebsd",
        .netbsd => "netbsd",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86 => "x86",
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .loongarch64 => "loongarch64",
        .powerpc64 => "powerpc",
        .powerpc64le => "powerpc64le",
        .arm => "arm",
        .riscv64 => "riscv64",
        else => return null,
    };

    return std.fmt.comptimePrint("{s}-{s}", .{ arch, os });
}
