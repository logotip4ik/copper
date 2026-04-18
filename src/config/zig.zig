const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const minisign = @import("minisign");
const compress = @import("compress");

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
    .decompressTargetFile = common.decompressFirstDir,
    .verifyTargetFile = verifyTargetFile,
};

const PUBKEY = minisign.PublicKey.decodeFromBase64(MINISIGN_KEY) catch unreachable;

const VerifyTargetFileError = common.VerifyTargetFileError;
fn verifyTargetFile(
    ctx: common.VerifyTargetFileContext,
    targetFile: *std.Io.File,
    downloadTarget: *const DownloadTarget,
) VerifyTargetFileError!?bool {
    var minisigUrlBuf: [512]u8 = undefined;
    const minisigUrl = std.fmt.bufPrint(&minisigUrlBuf, "{s}.minisig?source={s}", .{
        downloadTarget.tarball.?,
        consts.EXE_NAME,
    }) catch unreachable;

    var stream: std.Io.Writer.Allocating = .init(ctx.alloc);
    defer stream.deinit();

    const res = ctx.client.fetch(.{
        .method = .GET,
        .keep_alive = false,
        .headers = consts.DEFAULT_HEADERS,
        .location = .{ .url = minisigUrl },
        .response_writer = &stream.writer,
    }) catch {
        logger.err("Failed fetching minisig url for {s}", .{downloadTarget.tarball.?});
        return VerifyTargetFileError.FailedFetching;
    };

    const minisigBytes = stream.written();
    if (res.status != .ok or minisigBytes.len == 0) {
        logger.err("{s} failed with: {s} code, content length: {d}", .{
            minisigUrl,
            @tagName(res.status),
            minisigBytes.len,
        });
        return VerifyTargetFileError.FailedFetching;
    }

    var sig = minisign.Signature.decode(ctx.alloc, minisigBytes) catch return VerifyTargetFileError.FailedVerifying;
    defer sig.deinit();

    logger.debug("verifing target file...", .{});

    var verifier = PUBKEY.verifier(&sig) catch |err| {
        logger.debug("verifier creation failed with {t}", .{err});
        return false;
    };

    var fileReadingBuf: [std.heap.page_size_max]u8 = undefined;
    var fileReader = targetFile.reader(ctx.io, &fileReadingBuf);

    while (true) {
        // Chunks are important piece of this code...
        const chunk = fileReader.interface.take(std.heap.page_size_max) catch |err| switch (err) {
            error.EndOfStream => {
                verifier.update(fileReader.interface.buffered());
                break;
            },
            else => unreachable,
        };

        verifier.update(chunk);
    }

    verifier.verify(ctx.alloc) catch |err| {
        logger.debug("verify failed with {t}", .{err});
        return false;
    };

    logger.debug("verified successfully", .{});
    return true;
}

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
fn downloadMirrors(alloc: std.mem.Allocator, io: std.Io, client: *std.http.Client) !MirrorList {
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

    var r: std.Random.DefaultPrng = .init(
        @intCast(std.Io.Timestamp.now(io, .real).toMilliseconds()),
    );
    const random = r.random();

    random.shuffle([]const u8, mirrors.items);

    return mirrors;
}

const DownloadTarget = common.DownloadTarget;
const DownloadTargets = common.DownloadTargets;
const DownloadTargetError = common.DownloadTargetError;
const VersionsMap = std.json.ArrayHashMap(std.json.Value);
fn fetchVersions(
    alloc: std.mem.Allocator,
    io: std.Io,
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

    var mirrors = try downloadMirrors(alloc, io, client);
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
