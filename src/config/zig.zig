const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");

const common = @import("./common.zig");

const MIRRORS_URL = "https://ziglang.org/download/community-mirrors.txt";

const logger = std.log.scoped(.zig);

pub const interface: common.ConfInterface = .{
    .name = "zig",
    .type = .Runtime,
    .getDownloadTargets = fetchVersions,
    .decompressTargetFile = decompressTargetFile,
};

fn toDownloadTarget(
    alloc: std.mem.Allocator,
    key: *const []const u8,
    value: *std.json.Value,
) !?DownloadTarget {
    const target = value.object.get(comptime getTargetString()) orelse return null;

    const versionValue = value.object.get("version");
    const versionString = try alloc.dupe(u8, if (versionValue) |v| v.string else key.*);
    errdefer alloc.free(versionString);

    const version = try std.SemanticVersion.parse(versionString);

    const shasumValue = target.object.get("shasum") orelse return error.NoShasumField;
    const shasum = try alloc.dupe(u8, shasumValue.string);
    errdefer alloc.free(shasum);

    const tarballValue = target.object.get("tarball") orelse return error.NoTarballField;
    const tarball = try alloc.dupe(u8, tarballValue.string);
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

    // this will ensure ziglang is used only as last resort
    try mirrors.append(alloc, try alloc.dupe(u8, "https://ziglang.org/download"));

    return mirrors;
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

    var mirrors = try downloadMirrors(alloc, client);
    defer {
        for (mirrors.items) |mirror| alloc.free(mirror);
        mirrors.deinit(alloc);
    }
    progress.completeOne();

    var stream: std.Io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    var versionMapUrlBuf: [128]u8 = undefined;
    var versionsMapJson: std.json.Parsed(VersionsMap) = undefined;

    for (mirrors.items) |mirror| {
        stream.clearRetainingCapacity();

        const versionMapUrl = std.fmt.bufPrint(&versionMapUrlBuf, "{s}/index.json?source={s}", .{
            mirror,
            consts.EXE_NAME,
        }) catch unreachable;

        const res = client.fetch(.{
            .method = .GET,
            .keep_alive = false,
            .headers = consts.DEFAULT_HEADERS,
            .location = .{ .url = versionMapUrl },
            .response_writer = &stream.writer,
        }) catch {
            logger.warn("Failed fetching versions json from {s}", .{versionMapUrl});
            continue;
        };

        progress.completeOne();

        if (res.status == .ok and stream.written().len > 0) {
            versionsMapJson = std.json.parseFromSlice(VersionsMap, alloc, stream.written(), .{}) catch {
                logger.warn("Failed parsing versions json from {s}", .{versionMapUrl});
                continue;
            };

            break;
        }
    } else return error.FailedFetchingVersionJson;

    defer versionsMapJson.deinit();

    var targets: DownloadTargets = .empty;
    errdefer {
        for (targets.items) |item| item.deinit(alloc);
        targets.deinit(alloc);
    }

    var verIter = versionsMapJson.value.map.iterator();

    while (verIter.next()) |entry| {
        const target = toDownloadTarget(
            alloc,
            entry.key_ptr,
            entry.value_ptr,
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

fn getTargetString() []const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .windows => "windows",
        .linux => "linux",
        .freebsd => "freebsd",
        .netbsd => "netbsd",
        else => @compileError("Unsupported OS"),
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
        else => @compileError("Unsupported CPU"),
    };

    return std.fmt.comptimePrint("{s}-{s}", .{ arch, os });
}
