const std = @import("std");

const SemanticVersion = std.SemanticVersion;
pub fn parseUserVersion(input: []const u8) !SemanticVersion.Range {
    if (SemanticVersion.parse(input)) |specificVersion| {
        return SemanticVersion.Range{
            .min = specificVersion,
            .max = specificVersion,
        };
    } else |_| {}

    var iter = std.mem.splitScalar(u8, input, '.');

    const majorStr = iter.next() orelse input;
    const major = std.fmt.parseUnsigned(u32, majorStr, 10) catch return error.InvalidMajor;

    var minor: ?u32 = null;
    if (iter.next()) |minorStr| {
        minor = std.fmt.parseUnsigned(u32, minorStr, 10) catch return error.InvalidMinor;
    }

    var patch: ?u32 = null;
    if (iter.next()) |patchStr| {
        patch = std.fmt.parseUnsigned(u32, patchStr, 10) catch return error.InvalidPatch;
    }

    return SemanticVersion.Range{ .min = SemanticVersion{
        .major = major,
        .minor = minor orelse 0,
        .patch = patch orelse 0,
    }, .max = SemanticVersion{
        .major = major,
        .minor = minor orelse std.math.maxInt(usize),
        .patch = patch orelse std.math.maxInt(usize),
    } };
}

test "parseUserVersion" {
    const testing = std.testing;

    try testing.expectEqual(SemanticVersion.Range{
        .min = SemanticVersion{ .major = 22, .minor = 0, .patch = 0 },
        .max = SemanticVersion{
            .major = 22,
            .minor = std.math.maxInt(usize),
            .patch = std.math.maxInt(usize),
        },
    }, try parseUserVersion("22"));

    try testing.expectEqual(SemanticVersion.Range{
        .min = SemanticVersion{ .major = 0, .minor = 15, .patch = 0 },
        .max = SemanticVersion{
            .major = 0,
            .minor = 15,
            .patch = std.math.maxInt(usize),
        },
    }, try parseUserVersion("0.15"));
}

pub fn compareVersionField(comptime T: type) fn (void, T, T) bool {
    std.debug.assert(@hasField(T, "version"));

    const t = @FieldType(T, "version");
    if (t == std.SemanticVersion) {
        return struct {
            pub fn inner(_: void, a: T, b: T) bool {
                return std.SemanticVersion.order(a.version, b.version) == .gt;
            }
        }.inner;
    } else if (t == *std.SemanticVersion) {
        return struct {
            pub fn inner(_: void, a: T, b: T) bool {
                return std.SemanticVersion.order(a.version.*, b.version.*) == .gt;
            }
        }.inner;
    } else {
        @compileError(t ++ " unresolved type for version field");
    }
}

pub fn concat(alloc: std.mem.Allocator, strings: []const []const u8, comptime sep: []const u8) ![]const u8 {
    var length: usize = 0;
    for (strings) |string| {
        length += string.len;
    }
    length += sep.len * (strings.len - 1);

    const buf = try alloc.alloc(u8, length);
    var writer: std.io.Writer = .fixed(buf);

    for (strings, 0..) |string, i| {
        if (i == 0) {
            try writer.print("{s}", .{string});
        } else {
            try writer.print("{s}{s}", .{ sep, string });
        }
    }

    return buf;
}

pub const RunError = error{ FailedSpawning, FailedRunning };
pub fn run(
    alloc: std.mem.Allocator,
    args: []const []const u8,
    cwdDir: ?std.fs.Dir,
) RunError!void {
    const argsString = concat(alloc, args, " ") catch unreachable;
    defer alloc.free(argsString);

    std.log.info("executing - {s}", .{argsString});

    var runProcess: std.process.Child = .init(args, alloc);
    runProcess.stdin_behavior = .Ignore;
    runProcess.stdout_behavior = .Ignore;
    runProcess.stderr_behavior = .Inherit;
    runProcess.create_no_window = true;
    runProcess.cwd_dir = cwdDir;

    const res = runProcess.spawnAndWait() catch return RunError.FailedSpawning;

    switch (res) {
        .Exited => |e| if (e != 0) return RunError.FailedRunning,
        .Signal, .Stopped, .Unknown => return RunError.FailedRunning,
    }
}

pub fn isMakeInstalled(alloc: std.mem.Allocator) bool {
    run(alloc, &.{ "make", "-v" }, null) catch return false;

    return true;
}

pub fn stripV(alloc: std.mem.Allocator, version: []const u8) ?[]const u8 {
    if (version.len == 0) return null;

    const v = if (version[0] == 'v') version[1..] else version;

    return alloc.dupe(
        u8,
        std.mem.trim(u8, v, " \t\r\n"),
    ) catch null;
}

pub fn openFirstDirWithLog(
    dir: std.fs.Dir,
    comptime logger: anytype,
    comptime message: []const u8,
) !?std.fs.Dir {
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) {
            if (message.len > 0) {
                logger.info(message, .{entry.name});
            }
            return try dir.openDir(entry.name, .{});
        }
    }

    return null;
}

pub fn dirContainsFileWithLog(
    dir: std.fs.Dir,
    file: []const u8,
    comptime logger: anytype,
    comptime message: []const u8,
) bool {
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, file)) {
            logger.info(message, .{entry.name});
            return true;
        }
    }

    return false;
}

pub fn decompressZipDir(
    alloc: std.mem.Allocator,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!void {
    const fileBuf = alloc.alloc(u8, 32 * 1024 * 1024) catch return error.FailedAllocatingBuffer;
    defer alloc.free(fileBuf);

    var fileReader = targetFile.reader(fileBuf);

    var iter = tmpDir.iterate();
    while (iter.next() catch null) |entry| {
        tmpDir.deleteTree(entry.name) catch {};
    }

    std.zip.extract(tmpDir, &fileReader, .{}) catch return error.FailedUnzipping;
}

pub fn decompressGzDir(
    alloc: std.mem.Allocator,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!void {
    const fileBuf = alloc.alloc(u8, 32 * 1024 * 1024) catch return error.FailedAllocatingBuffer;
    defer alloc.free(fileBuf);

    var fileReader = targetFile.reader(fileBuf);

    const decompressBuf = alloc.alloc(u8, 32 * 1024 * 1024) catch return error.FailedAllocatingBuffer;
    defer alloc.free(decompressBuf);

    var decompressed = std.compress.flate.Decompress.init(&fileReader.interface, .gzip, decompressBuf);

    var iter = tmpDir.iterate();
    while (iter.next() catch null) |entry| {
        tmpDir.deleteTree(entry.name) catch {};
    }

    std.tar.pipeToFileSystem(tmpDir, &decompressed.reader, .{
        .mode_mode = .executable_bit_only,
    }) catch return error.FailedUnzipping;
}

pub fn decompressXzDir(
    alloc: std.mem.Allocator,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!void {
    var decompressed = std.compress.xz.decompress(alloc, targetFile.deprecatedReader()) catch return error.FailedCreatingDecompressor;
    defer decompressed.deinit();

    var decompressedReader = decompressed.reader();

    const outwriterBuf = alloc.alloc(u8, 64 * 1024 * 1024) catch return error.FailedAllocatingBuffer;
    defer alloc.free(outwriterBuf);
    var newreader = decompressedReader.adaptToNewApi(outwriterBuf);

    var iter = tmpDir.iterate();
    while (iter.next() catch null) |entry| {
        tmpDir.deleteTree(entry.name) catch {};
    }

    std.tar.pipeToFileSystem(tmpDir, &newreader.new_interface, .{
        .mode_mode = .executable_bit_only,
    }) catch return error.FailedUnzipping;
}

pub fn githubTagToDownloadTarget(
    alloc: std.mem.Allocator,
    comptime logger: @TypeOf(std.log),
    item: std.json.Value,
    comptime toSemverString: *const fn (alloc: std.mem.Allocator, source: []const u8) ?[]const u8,
) !DownloadTarget {
    const tag = switch (item) {
        .object => |obj| obj,
        else => return error.InvalidItemType,
    };

    const versionValue = tag.get("name") orelse return error.InvalidJson;
    const versionString = toSemverString(
        alloc,
        switch (versionValue) {
            .string => |s| s,
            else => return error.InvalidJson,
        },
    ) orelse {
        logger.warn("Failed converting tag_name to semver version '{s}'", .{versionValue.string});
        return error.InvalidTagName;
    };
    errdefer alloc.free(versionString);

    const version = std.SemanticVersion.parse(versionString) catch |err| {
        logger.err("failed converting {s} to semantic version with err {s}", .{ versionString, @errorName(err) });
        return DownloadTargetError.InvalidJson;
    };

    const sourceTarballValue = tag.get("tarball_url") orelse {
        logger.err("missing tarball_url field", .{});
        return DownloadTargetError.InvalidJson;
    };
    const sourceTarballString = switch (sourceTarballValue) {
        .string => |s| s,
        else => |v| {
            logger.err("invalid tarball_url field value, expected string, got: {any}", .{v});
            return DownloadTargetError.InvalidJson;
        },
    };
    const sourceTarball = alloc.dupe(u8, sourceTarballString) catch return DownloadTargetError.FailedConvertingToDownloadTarget;
    errdefer alloc.free(sourceTarball);

    return DownloadTarget{
        .versionString = versionString,
        .version = version,
        .tarball = sourceTarball,
    };
}

pub fn githubReleaseToDownloadTarget(
    alloc: std.mem.Allocator,
    comptime logger: @TypeOf(std.log),
    release: std.json.ObjectMap,
    comptime toSemverString: *const fn (alloc: std.mem.Allocator, source: []const u8) ?[]const u8,
    comptime matchingAsset: *const fn (assetName: []const u8) bool,
) !?DownloadTarget {
    const tagNameValue = release.get("tag_name") orelse return null;

    const versionString = toSemverString(alloc, tagNameValue.string) orelse {
        logger.warn("Failed converting tag_name to semver version '{s}'", .{tagNameValue.string});
        return null;
    };
    errdefer alloc.free(versionString);

    const version = std.SemanticVersion.parse(versionString) catch |err| {
        logger.warn("Failed parsing version '{s}', converted versionString '{s}', error {s}", .{
            tagNameValue.string,
            versionString,
            @errorName(err),
        });
        alloc.free(versionString);
        return null;
    };

    const assetsValue = release.get("assets") orelse {
        alloc.free(versionString);
        return null;
    };

    for (assetsValue.array.items) |asset| {
        const name = asset.object.get("name") orelse continue;

        if (!matchingAsset(name.string)) {
            continue;
        }

        const downloadUrl = asset.object.get("browser_download_url") orelse continue;
        const tarball = try alloc.dupe(u8, downloadUrl.string);
        errdefer alloc.free(tarball);

        const digest = asset.object.get("digest") orelse return error.InvalidReleaseJson;
        const shasum = switch (digest) {
            .string => try alloc.dupe(u8, digest.string[("sha256:".len)..]),
            else => null,
        };
        errdefer if (shasum) |sum| alloc.free(sum);

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

pub const DownloadTarget = struct {
    versionString: []const u8,
    version: std.SemanticVersion,
    tarball: []const u8,

    /// use getTarballShasum function from ConfInterface if null
    shasum: ?[]const u8 = null,

    pub fn copy(self: DownloadTarget, alloc: std.mem.Allocator) !DownloadTarget {
        return DownloadTarget{
            .versionString = try alloc.dupe(u8, self.versionString),
            .version = std.SemanticVersion{
                .major = self.version.major,
                .minor = self.version.minor,
                .patch = self.version.patch,
                .build = self.version.build,
                .pre = self.version.pre,
            },
            .shasum = try alloc.dupe(u8, self.shasum),
            .size = try alloc.dupe(u8, self.size),
            .tarball = try alloc.dupe(u8, self.tarball),
        };
    }

    pub fn deinit(self: DownloadTarget, alloc: std.mem.Allocator) void {
        alloc.free(self.versionString);
        alloc.free(self.tarball);
        if (self.shasum) |shasum| alloc.free(shasum);
    }
};
pub const DownloadTargets = std.array_list.Aligned(DownloadTarget, null);

pub const DownloadTargetError = error{
    FailedParsingJson,
    FailedFetchingVersionJson,
    FailedConvertingToDownloadTarget,
    InvalidJson,
} || std.mem.Allocator.Error;

pub const DecompressError = error{
    FailedCreatingDecompressor,
    FailedAllocatingBuffer,
    FailedUnzipping,
    DirNotExists,
    InvalidResultDir,
    FailedCreatingWalker,
    FailedCreatingCopyFile,
    FailedCopying,
};

pub const DecompressResult = struct {
    dir: std.fs.Dir,
    /// should be absolute path
    path: []const u8,
};

pub const GetTarballShasumError = error{
    FailedFetching,
    InvalidShasumFile,
    ShasumNotFound,
    FailedGeneratingTarballName,
};

pub const BuildFromSourceError = error{
    DepsNotInstalled,
    Unknown,
    FailedSpawinngProcess,
    FailedBuilding,
};

pub const ConfInterface = struct {
    pub const Type = enum { Runtime, Package };

    type: Type,

    name: []const u8,

    /// relative to root of extracted folder, so:
    /// `copper/node/default` + binPath = `copper/node/default/bin`
    binPath: []const u8 = "",

    fileHooks: ?[]const []const u8 = null,

    getDownloadTargets: *const fn (
        alloc: std.mem.Allocator,
        client: *std.http.Client,
        progress: std.Progress.Node,
    ) DownloadTargetError!DownloadTargets,
    decompressTargetFile: *const fn (
        alloc: std.mem.Allocator,
        compression: Compression,
        target: std.fs.File,
        tmpDir: std.fs.Dir,
    ) DecompressError!std.fs.Dir,

    /// can be noop function if `DownloadTarget` has already resolved `shasum` field
    getTarballShasum: *const fn (
        alloc: std.mem.Allocator,
        client: *std.http.Client,
        target: DownloadTarget,
        progress: std.Progress.Node,
    ) GetTarballShasumError!?[]const u8 = noopGetTarballShasum,

    resolveVersionFromFile: *const fn (
        alloc: std.mem.Allocator,
        filename: []const u8,
        file: std.fs.File,
    ) ?[]const u8 = noopResolveVersionFromFile,

    buildTarget: ?*const fn (
        alloc: std.mem.Allocator,
        progress: std.Progress.Node,
        sourceDir: std.fs.Dir,
        /// this should not be used to "precreate" target folder. It's used only for building
        /// purposes. `git` conf requires `prefix` at build time to point where git executable will
        /// live
        targetDirPath: []const u8,
    ) BuildFromSourceError!std.fs.Dir = null,
};

pub fn noopGetTarballShasum(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    target: DownloadTarget,
    progress: std.Progress.Node,
) GetTarballShasumError!?[]const u8 {
    _ = alloc;
    _ = client;
    _ = target;
    _ = progress;
    return null;
}

pub fn noopResolveVersionFromFile(
    alloc: std.mem.Allocator,
    filename: []const u8,
    file: std.fs.File,
) ?[]const u8 {
    _ = alloc;
    _ = filename;
    _ = file;
    unreachable;
}

pub const Compression = enum {
    xz,
    gz,
    zip,
    uncompressed,
};
