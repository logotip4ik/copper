const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");

const common = @import("./common.zig");

const logger = std.log.scoped(.jq);

const GITHUB_API_URL = "https://api.github.com/repos/jqlang/jq/releases";

pub const interface: common.ConfInterface = .{
    .getDownloadTargets = fetchVersions,
    .decompressTargetFile = decompressTargetFile,
};

fn jqVersionToSemVer(allocator: std.mem.Allocator, jq_version: []const u8) ![]const u8 {
    // Ensure the input starts with "jq-"
    if (!std.mem.startsWith(u8, jq_version, "jq-")) {
        return error.InvalidJqVersion;
    }

    // Strip "jq-" prefix
    const version = jq_version[3..];

    var iter = std.mem.splitScalar(u8, version, '.');

    const major = try std.fmt.parseUnsigned(u32, iter.next() orelse return error.InvalidJqVersion, 10);

    var minor: ?u32 = null;
    var patch: ?u32 = null;
    var prerelease: ?[]const u8 = null;

    while (iter.next()) |component| {
        var componentWithoutPrerelease = component;

        // Handle rc, beta, etc. (prerelease identifiers)
        if (std.mem.indexOfAny(u8, component, "abr")) |idx| {
            componentWithoutPrerelease = component[0..idx];
            prerelease = component[idx..];
        }

        const int = std.fmt.parseUnsigned(u32, componentWithoutPrerelease, 10) catch return error.InvalidJqVersion;

        if (minor == null) {
            minor = int;
            continue;
        }

        if (patch == null) {
            patch = int;
            break;
        }
    }

    if (prerelease) |pre| {
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}-{s}", .{
            major,
            minor orelse 0,
            patch orelse 0,
            pre,
        });
    }

    return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{
        major,
        minor orelse 0,
        patch orelse 0,
    });
}

test "jqVersionToSemVer" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "jq-1.8.1", "1.8.1" },
        .{ "jq-1.8.0", "1.8.0" },
        .{ "jq-1.7.1", "1.7.1" },
        .{ "jq-1.7", "1.7.0" },
        .{ "jq-1.7rc2", "1.7.0-rc2" },
        .{ "jq-1.7rc1", "1.7.0-rc1" },
        .{ "jq-1.6", "1.6.0" },
        .{ "jq-1.5", "1.5.0" },
        .{ "jq-1.5rc2", "1.5.0-rc2" },
        .{ "jq-1.5rc1", "1.5.0-rc1" },
        .{ "jq-1.4", "1.4.0" },
        .{ "jq-1.3", "1.3.0" },
        .{ "jq-1.2", "1.2.0" },
        .{ "jq-1.1", "1.1.0" },
        .{ "jq-1.0", "1.0.0" },
    };

    const testing = std.testing;
    for (cases) |case| {
        const version, const expected = case;
        const actual = try jqVersionToSemVer(testing.allocator, version);
        defer testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

const DownloadTarget = common.DownloadTarget;
fn toDownloadTarget(
    alloc: std.mem.Allocator,
    release: std.json.ObjectMap,
) !?DownloadTarget {
    const tagNameValue = release.get("tag_name") orelse return null;

    const versionString = try jqVersionToSemVer(alloc, tagNameValue.string);
    errdefer alloc.free(versionString);

    const version = std.SemanticVersion.parse(versionString) catch |err| {
        logger.warn("Failed to parse version '{s}': {}", .{ versionString, err });
        alloc.free(versionString);
        return null;
    };

    const assetsValue = release.get("assets") orelse return null;
    const targetFilename = comptime try getTargetFilename();

    for (assetsValue.array.items) |asset| {
        const name = asset.object.get("name") orelse continue;

        if (!std.mem.eql(u8, name.string, targetFilename)) {
            continue;
        }

        const downloadUrlValue = asset.object.get("browser_download_url") orelse continue;
        const downloadUrl = downloadUrlValue.string;

        const tarball = try alloc.dupe(u8, downloadUrl);
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
    std.debug.assert(compression == .uncompressed);

    const readerBuf = alloc.alloc(u8, 16 * 1024 * 1024) catch return error.FailedAllocatingBuffer;
    defer alloc.free(readerBuf);

    var reader = targetFile.reader(readerBuf);

    const exeName = if (builtin.target.os.tag == .windows) "jq.exe" else "jq";
    const copy = tmpDir.createFile(exeName, .{}) catch return error.FailedCreatingCopyFile;
    defer copy.close();

    var writer = copy.writer(&.{});

    _ = reader.interface.streamRemaining(&writer.interface) catch return error.FailedCopying;

    if (builtin.target.os.tag != .windows) {
        // Make it executable by adding execute permissions for user, group, and others
        // 0o755 means: rwxr-xr-x (user: read+write+execute, group: read+execute, others: read+execute)
        copy.chmod(0o755) catch return error.FailedCopying;
    }

    return tmpDir;
}

fn getTargetFilename() ![]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return error.UnsupportedOS,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .x86 => "i386",
        .s390x => "s390x",
        .mips => "mips",
        .mips64 => "mips64",
        .mips64el => "mips64el",
        .powerpc64le => "ppc64el",
        else => return error.UnsupportedCPU,
    };

    if (builtin.target.os.tag == .windows) {
        return std.fmt.comptimePrint("jq-{s}-{s}.exe", .{ os, arch });
    }

    return std.fmt.comptimePrint("jq-{s}-{s}", .{ os, arch });
}
