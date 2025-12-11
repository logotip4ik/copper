const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.python);

const GITHUB_API_URL = "https://api.github.com/repos/indygreg/python-build-standalone/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "python",
    .type = .Runtime,
    .binPath = "bin",
    .fileHooks = &.{
        ".python-version",
    },

    .getDownloadTargets = fetchVersions,
    .decompressTargetFile = decompressTargetFile,
    .resolveVersionFromFile = resolveVersionFromFile,
};

fn extractVersionFromAssetName(alloc: std.mem.Allocator, assetName: []const u8) ?[]const u8 {
    // Asset name format: cpython-{version}+{build}+{os}-{arch}-install_only.{ext}
    // Example: cpython-3.12.0+20231002-x86_64-apple-darwin-install_only.tar.gz

    // Must start with cpython- or python-
    if (!std.mem.startsWith(u8, assetName, "cpython-") and !std.mem.startsWith(u8, assetName, "python-")) {
        return null;
    }

    const afterPrefix = if (std.mem.startsWith(u8, assetName, "cpython-"))
        assetName["cpython-".len..]
    else
        assetName["python-".len..];

    // Find the end of version (before '+')
    const plusIdx = std.mem.indexOfScalar(u8, afterPrefix, '+') orelse return null;
    const versionStr = afterPrefix[0..plusIdx];

    // Parse versionStr which should be like "3.12.0" or "3.12.0rc1"
    var iter = std.mem.splitScalar(u8, versionStr, '.');

    const major = iter.next() orelse return null;
    const minor = iter.next() orelse return null;
    const patch = iter.next() orelse return null;

    if (std.mem.indexOfAny(u8, patch, "abrc")) |idx| {
        return std.fmt.allocPrint(alloc, "{s}.{s}.{s}-{s}", .{
            major,
            minor,
            patch[0..idx],
            patch[idx..],
        }) catch null;
    }

    return std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{
        major,
        minor,
        patch,
    }) catch null;
}

test "extractVersionFromAssetName" {
    const allocator = std.testing.allocator;

    const testCases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "cpython-3.12.0+20231002-x86_64-apple-darwin-install_only.tar.gz", .expected = "3.12.0" },
        .{ .input = "cpython-3.12.0rc1+20231002-x86_64-apple-darwin-install_only.tar.gz", .expected = "3.12.0-rc1" },
        .{ .input = "cpython-3.11.5+20231002-x86_64-apple-darwin-install_only.tar.gz", .expected = "3.11.5" },
        .{ .input = "python-3.10.13+20231002-x86_64-apple-darwin-install_only.tar.gz", .expected = "3.10.13" },
        .{ .input = "cpython-3.9.18+20231002-x86_64-apple-darwin-install_only.tar.gz", .expected = "3.9.18" },
    };

    for (testCases) |tc| {
        const result = extractVersionFromAssetName(allocator, tc.input) orelse {
            std.debug.print("Failed to parse: {s}\n", .{tc.input});
            return error.FailedParsing;
        };
        defer allocator.free(result);

        try std.testing.expectEqualStrings(tc.expected, result);
    }
}

fn matchingAsset(name: []const u8) bool {
    // Must be an install_only tarball/zip
    if (!std.mem.containsAtLeast(u8, name, 1, "install_only")) {
        return false;
    }

    const targetSuffix = comptime getTargetSuffix();

    return std.mem.endsWith(u8, name, targetSuffix orelse return false);
}

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

    const assets = json.value.object.get("assets") orelse {
        logger.warn("No assets found in latest release", .{});
        return targets;
    };

    for (assets.array.items) |asset| {
        const nameValue = asset.object.get("name") orelse continue;
        const assetName = nameValue.string;

        if (!matchingAsset(assetName)) continue;

        const versionString = extractVersionFromAssetName(alloc, assetName) orelse {
            logger.warn("Failed to extract version from asset name: {s}", .{assetName});
            continue;
        };
        errdefer alloc.free(versionString);

        const version = std.SemanticVersion.parse(versionString) catch |err| {
            logger.warn("Failed parsing version '{s}' from asset '{s}': {s}", .{
                versionString, assetName, @errorName(err),
            });
            alloc.free(versionString);
            continue;
        };

        const urlValue = asset.object.get("browser_download_url") orelse {
            alloc.free(versionString);
            continue;
        };
        const tarball = alloc.dupe(u8, urlValue.string) catch unreachable;
        errdefer alloc.free(tarball);

        const digest = asset.object.get("digest") orelse {
            alloc.free(versionString);
            continue;
        };

        const shasum = switch (digest) {
            .string => alloc.dupe(u8, digest.string["sha256:".len..]) catch unreachable,
            else => null,
        };
        errdefer if (shasum) |s| alloc.free(s);

        const space = targets.addOne(alloc) catch unreachable;
        space.* = common.DownloadTarget{
            .versionString = versionString,
            .version = version,
            .tarball = tarball,
            .shasum = shasum,
        };
    }

    std.sort.pdq(DownloadTarget, targets.items, {}, DownloadTarget.lessThan);

    return targets;
}

const DecompressError = common.DecompressError;

fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: compress.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    if (common.openFirstDirWithLog(tmpDir, logger, "using cached decompressed {s}") catch null) |dir| {
        return dir;
    }

    switch (compression) {
        .gz => try compress.decompressGzDir(alloc, targetFile, tmpDir),
        .zip => try compress.decompressZipDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    const dir = common.openFirstDirWithLog(tmpDir, logger, "decompressed {s}") catch return error.FailedUnzipping;
    return dir orelse error.FailedUnzipping;
}

fn getTargetSuffix() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "apple-darwin",
        .linux => "unknown-linux-gnu",
        .windows => "pc-windows-msvc",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "i686",
        else => return null,
    };

    const extension = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("{s}-{s}-install_only.{s}", .{ arch, os, extension });
}

fn resolveVersionFromFile(
    alloc: std.mem.Allocator,
    filename: []const u8,
    file: std.fs.File,
) ?[]const u8 {
    _ = filename;

    var versionBuf: [256]u8 = undefined;

    const read = file.read(&versionBuf) catch return null;
    if (read == 0) return null;

    const versionString = std.mem.trimEnd(
        u8,
        std.mem.trimEnd(u8, versionBuf[0..read], " \t"),
        "\r\n",
    );

    return alloc.dupe(u8, versionString) catch null;
}
