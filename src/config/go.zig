const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");

const common = @import("./common.zig");

const logger = std.log.scoped(.go);

const MIRROR_URLS = .{"https://go.dev/dl"};

pub const interface: common.ConfInterface = .{
    .binPath = "bin",
    .getDownloadTargets = fetchVersions,
    .decompressTargetFile = decompressTargetFile,
};

fn goVersionToSemVer(allocator: std.mem.Allocator, go_version: []const u8) ![]const u8 {
    // Ensure the input starts with "go"
    if (!std.mem.startsWith(u8, go_version, "go")) {
        return error.InvalidGoVersion;
    }

    // strip "go" prefix
    const version = go_version[2..];

    var iter = std.mem.splitScalar(u8, version, '.');

    const major = try std.fmt.parseUnsigned(u32, iter.next() orelse return error.InvalidGoVersion, 10);

    var minor: ?u32 = null;
    var patch: ?u32 = null;
    var prerelease: ?[]const u8 = null;

    while (iter.next()) |component| {
        var componentWithoutPrerelease = component;

        // alpha, beta, rcX
        if (std.mem.indexOfAny(u8, component, "abr")) |idx| {
            componentWithoutPrerelease = component[0..idx];
            prerelease = component[idx..];
        }

        const int = std.fmt.parseUnsigned(u32, componentWithoutPrerelease, 10) catch return error.InvalidGoVersion;

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

test "goVersionToSemVer" {
    const allocator = std.testing.allocator;

    const testCases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "go1.21.0", .expected = "1.21.0" },
        .{ .input = "go1.21rc2", .expected = "1.21.0-rc2" },
        .{ .input = "go1.21.1rc1", .expected = "1.21.1-rc1" },
        .{ .input = "go1.21", .expected = "1.21.0" },
        .{ .input = "go1.21beta1", .expected = "1.21.0-beta1" },
        .{ .input = "go1", .expected = "1.0.0" },
    };

    for (testCases) |tc| {
        const result = try goVersionToSemVer(allocator, tc.input);
        defer allocator.free(result);
        try std.testing.expectEqualStrings(tc.expected, result);
    }

    // Test invalid inputs
    try std.testing.expectError(error.InvalidGoVersion, goVersionToSemVer(allocator, "go1.21.x"));
}

const DownloadTarget = common.DownloadTarget;
fn toDownloadTarget(
    alloc: std.mem.Allocator,
    object: std.json.ObjectMap,
) !?DownloadTarget {
    const versionValue = object.get("version") orelse return null;

    // Go versions start with "go" prefix (e.g., "go1.21.0")
    const versionString = try goVersionToSemVer(alloc, versionValue.string);
    errdefer alloc.free(versionString);

    const version = try std.SemanticVersion.parse(versionString);

    const filesValue = object.get("files") orelse return error.NoFilesField;

    const targetOs = comptime try getTargetOs();
    const targetArch = comptime try getTargetArch();

    for (filesValue.array.items) |fileValue| {
        const fileObj = fileValue.object;

        const kindValue = fileObj.get("kind") orelse continue;
        const kind = kindValue.string;

        if (!std.mem.eql(u8, kind, "archive")) continue;

        const osValue = fileObj.get("os") orelse continue;
        const archValue = fileObj.get("arch") orelse continue;

        // Check if this file matches our target OS and architecture
        if (std.mem.eql(u8, osValue.string, targetOs) and std.mem.eql(u8, archValue.string, targetArch)) {
            const filenameValue = fileObj.get("filename") orelse continue;
            const filename = filenameValue.string;

            const shasumValue = fileObj.get("sha256") orelse return error.NoShasumField;
            const shasum = try alloc.dupe(u8, shasumValue.string);
            errdefer alloc.free(shasum);

            const tarball = try std.fmt.allocPrint(
                alloc,
                "{s}/{s}",
                .{ MIRROR_URLS[0], filename },
            );
            errdefer alloc.free(tarball);

            return DownloadTarget{
                .versionString = versionString,
                .version = version,
                .tarball = tarball,
                .shasum = shasum,
            };
        }
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
    const mirror = MIRROR_URLS[0];
    const url = std.fmt.comptimePrint("{s}/?mode=json&include=all", .{mirror});

    var stream: std.io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    const result = client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .response_writer = &stream.writer,
        .headers = consts.DEFAULT_HEADERS,
        .keep_alive = false,
    }) catch |err| {
        logger.err("Error while fetching: {s}", .{@errorName(err)});
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

            const outwriterBuf = alloc.alloc(u8, 64 * 1024 * 1024) catch return error.FailedAllocatingBuffer;
            defer alloc.free(outwriterBuf);

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
        .xz => unreachable,
    }

    const dir = common.openFirstDirWithLog(tmpDir, logger, "unzipped {s}") catch return error.FailedUnzipping;
    return dir orelse error.FailedUnzipping;
}

fn getTargetOs() ![]const u8 {
    return switch (builtin.target.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "windows",
        .freebsd => "freebsd",
        .netbsd => "netbsd",
        .openbsd => "openbsd",
        .solaris, .illumos => "solaris",
        .aix => "aix",
        .dragonfly => "dragonfly",
        else => error.UnsupportedOS,
    };
}

fn getTargetArch() ![]const u8 {
    return switch (builtin.target.cpu.arch) {
        .x86 => "386",
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .arm => "armv6l",
        .powerpc64 => "ppc64",
        .powerpc64le => "ppc64le",
        .riscv64 => "riscv64",
        .s390x => "s390x",
        .loongarch64 => "loong64",
        else => error.UnsupportedCPU,
    };
}
