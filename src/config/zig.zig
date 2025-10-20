const std = @import("std");
const builtin = @import("builtin");
const common = @import("./common.zig");

const Alloc = std.mem.Allocator;

const MIRROR_URLS = [_][]const u8{
    "https://pkg.machengine.org/zig",
    "https://zigmirror.hryx.net/zig",
    "https://zig.linus.dev/zig",
    "https://zig.squirl.dev",
    "https://zig.florent.dev",
    "https://zig.mirror.mschae23.de/zig",
    "https://zigmirror.meox.dev",
    "https://ziglang.org/download",
};

const logger = std.log.scoped(.zig);

pub const interface: common.ConfInterface = .{
    .getDownloadTargets = fetchVersions,
    .decompressTargetFile = decompressTargetFile,
};

fn toDownloadTarget(alloc: Alloc, key: *const []const u8, value: *std.json.Value) !?DownloadTarget {
    const target = value.object.get(try getTargetString()) orelse return null;

    const versionValue = value.object.get("version");
    const resolvedVersion = try alloc.dupe(u8, if (versionValue) |v| v.string else key.*);

    const shasum = target.object.get("shasum") orelse return error.NoShasumField;
    const size = target.object.get("size") orelse return error.NoSizeField;
    const tarball = target.object.get("tarball") orelse return error.NoTarballField;

    return DownloadTarget{
        .version = try std.SemanticVersion.parse(resolvedVersion),
        .versionString = resolvedVersion,
        .shasum = try alloc.dupe(u8, shasum.string),
        .size = try alloc.dupe(u8, size.string),
        .tarball = try alloc.dupe(u8, tarball.string),
    };
}

fn shaffledMirrors() [MIRROR_URLS.len][]const u8 {
    var mirrors: [MIRROR_URLS.len][]const u8 = undefined;

    inline for (MIRROR_URLS, 0..) |mirror, i| {
        mirrors[i] = mirror;
    }

    var r: std.Random.DefaultPrng = .init(@intCast(std.time.timestamp()));
    const random = r.random();

    random.shuffle([]const u8, &mirrors);

    return mirrors;
}

const DownloadTarget = common.DownloadTarget;
const DownloadTargets = common.DownloadTargets;
const DownloadTargetError = common.DownloadTargetError;
const VersionsMap = std.json.ArrayHashMap(std.json.Value);
fn fetchVersions(
    alloc: Alloc,
    client: *std.http.Client,
    progress: std.Progress.Node,
) DownloadTargetError!DownloadTargets {
    var stream: std.io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    var versionMapUrlBuf: [64]u8 = undefined;
    var maybeJson: ?std.json.Parsed(VersionsMap) = null;

    const mirrors = shaffledMirrors();
    for (mirrors) |mirror| {
        stream.clearRetainingCapacity();

        const versionMapUrl = std.fmt.bufPrint(&versionMapUrlBuf, "{s}/index.json", .{mirror}) catch unreachable;

        const res = client.fetch(.{
            .method = .GET,
            .keep_alive = false,
            .headers = .{ .user_agent = .{ .override = "copper" } },
            .location = .{ .url = versionMapUrl },
            .response_writer = &stream.writer,
        }) catch {
            logger.warn("Failed fetching versions json from {s}", .{versionMapUrl});
            continue;
        };

        progress.completeOne();

        if (res.status == .ok and stream.written().len > 0) {
            maybeJson = std.json.parseFromSlice(VersionsMap, alloc, stream.written(), .{}) catch {
                logger.warn("Failed parsing versions json from {s}", .{versionMapUrl});
                continue;
            };

            break;
        }
    } else return error.FailedFetchingVersionJson;

    const versionsMapJson = maybeJson orelse return error.FailedFetchingVersionJson;
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

    std.sort.heap(DownloadTarget, targets.items, {}, common.compareVersionField(DownloadTarget));

    return targets;
}

const DecompressError = common.DecompressError;
const DecompressResult = common.DecompressResult;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    {
        var walker = tmpDir.walk(alloc) catch return error.FailedCreatingWalker;
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind == .directory) {
                logger.info("using cached unzipped {s}", .{entry.path});

                return tmpDir.openDir(entry.path, .{}) catch error.DirNotExists;
            }
        }
    }

    var decompressed = std.compress.xz.decompress(alloc, targetFile.deprecatedReader()) catch return error.FailedCreatingDecompressor;
    defer decompressed.deinit();

    var reader = decompressed.reader();

    const outwriterBuf = alloc.alloc(u8, 64 * 1024 * 1024) catch return error.FailedAllocatingBuffer;
    defer alloc.free(outwriterBuf);
    var newreader = reader.adaptToNewApi(outwriterBuf);

    std.tar.pipeToFileSystem(tmpDir, &newreader.new_interface, .{
        .mode_mode = .executable_bit_only,
    }) catch return error.FailedUnzipping;

    var walker = tmpDir.walk(alloc) catch return error.FailedCreatingWalker;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind == .directory) {
            logger.info("unzipped {s}", .{entry.path});
            return tmpDir.openDir(entry.path, .{}) catch error.DirNotExists;
        }
    }

    return error.FailedUnzipping;
}

fn getTargetString() ![]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .windows => "windows",
        .linux => "linux",
        .freebsd => "freebsd",
        .netbsd => "netbsd",
        else => return error.UnsupportedOS,
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
        else => return error.UnsupportedCPU,
    };

    return std.fmt.comptimePrint("{s}-{s}", .{ arch, os });
}
