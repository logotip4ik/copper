const std = @import("std");
const consts = @import("consts");
const compress = @import("compress");

pub const RunOptions = struct {
    cwdDir: ?std.fs.Dir = null,
    envMap: ?*const std.process.EnvMap = null,
    stderrBehaivor: std.process.Child.StdIo = .Inherit,
};
pub const RunError = error{ FailedSpawning, FailedRunning } || std.mem.Allocator.Error;
pub fn run(
    alloc: std.mem.Allocator,
    args: []const []const u8,
    options: RunOptions,
) RunError!void {
    const argsString = std.mem.join(alloc, " ", args) catch unreachable;
    defer alloc.free(argsString);

    std.log.info("executing - {s}", .{argsString});

    var runProcess: std.process.Child = .init(args, alloc);
    runProcess.stdin_behavior = .Ignore;
    runProcess.stdout_behavior = .Ignore;
    runProcess.stderr_behavior = options.stderrBehaivor;
    runProcess.create_no_window = true;
    runProcess.cwd_dir = options.cwdDir;
    runProcess.env_map = options.envMap;

    const res = runProcess.spawnAndWait() catch return RunError.FailedSpawning;

    switch (res) {
        .Exited => |e| if (e != 0) return RunError.FailedRunning,
        .Signal, .Stopped, .Unknown => return RunError.FailedRunning,
    }
}

pub fn isMakeInstalled(alloc: std.mem.Allocator) bool {
    run(alloc, &.{ "make", "-v" }, .{}) catch return false;

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
    const source = alloc.dupe(u8, sourceTarballString) catch return DownloadTargetError.FailedConvertingToDownloadTarget;
    errdefer alloc.free(source);

    return DownloadTarget{
        .versionString = versionString,
        .version = version,
        .source = source,
        .tarball = null,
    };
}

const GithubReleaseToDownloadTargetError = error{
    NoMatchingTarget,
    InvalidJson,
    InvalidVersion,
} || std.mem.Allocator.Error;
pub fn githubReleaseToDownloadTarget(
    alloc: std.mem.Allocator,
    comptime logger: @TypeOf(std.log),
    release: std.json.ObjectMap,
    comptime toSemverString: *const fn (alloc: std.mem.Allocator, source: []const u8) ?[]const u8,
    comptime matchingAsset: *const fn (assetName: []const u8) bool,
) GithubReleaseToDownloadTargetError!DownloadTarget {
    const tagNameValue = release.get("tag_name") orelse return error.InvalidJson;

    const versionString = toSemverString(alloc, tagNameValue.string) orelse {
        logger.warn("Failed converting tag_name to semver version '{s}'", .{tagNameValue.string});
        return error.InvalidVersion;
    };
    errdefer alloc.free(versionString);

    const version = std.SemanticVersion.parse(versionString) catch |err| {
        logger.warn("Failed parsing version '{s}', converted versionString '{s}', error {s}", .{
            tagNameValue.string,
            versionString,
            @errorName(err),
        });
        return error.InvalidVersion;
    };

    const assetsValue = release.get("assets") orelse {
        alloc.free(versionString);
        return error.InvalidJson;
    };

    for (assetsValue.array.items) |asset| {
        const name = asset.object.get("name") orelse continue;

        if (!matchingAsset(name.string)) {
            continue;
        }

        const downloadUrl = asset.object.get("browser_download_url") orelse continue;
        const tarball = try alloc.dupe(u8, downloadUrl.string);
        errdefer alloc.free(tarball);

        const digest = asset.object.get("digest") orelse return error.InvalidJson;
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

    const source: ?[]const u8 = blk: {
        if (release.get("tarball_url")) |sourceValue| {
            break :blk try alloc.dupe(u8, sourceValue.string);
        }
        break :blk null;
    };
    errdefer if (source) |x| alloc.free(x);


    return DownloadTarget{
        .versionString = versionString,
        .version = version,
        .source = source,
        .tarball = null,
    };
}

pub fn fetchGithubReleases(
    alloc: std.mem.Allocator,
    comptime logger: @TypeOf(std.log),
    progress: std.Progress.Node,
    client: *std.http.Client,
    comptime githubLatestReleaseUrl: []const u8,
    comptime toSemverString: *const fn (alloc: std.mem.Allocator, source: []const u8) ?[]const u8,
    comptime matchingAsset: *const fn (assetName: []const u8) bool,
) DownloadTargetError!DownloadTargets {
    var stream: std.Io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    progress.setEstimatedTotalItems(1);

    const result = client.fetch(.{
        .method = .GET,
        .location = .{ .url = githubLatestReleaseUrl },
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

    var targets: DownloadTargets = try .initCapacity(alloc, 1);
    errdefer {
        for (targets.items) |item| item.deinit(alloc);
        targets.deinit(alloc);
    }

    switch (json.value) {
        .object => |release| {
            const target = githubReleaseToDownloadTarget(
                alloc,
                logger,
                release,
                toSemverString,
                matchingAsset,
            ) catch |err| switch (err) {
                error.NoMatchingTarget, error.InvalidVersion => return targets,
                else => return error.FailedConvertingToDownloadTarget,
            };

            targets.appendAssumeCapacity(target);
        },
        .array => |releases| {
            for (releases.items) |item| {
                const release = switch (item) {
                    .object => |o| o,
                    else => continue,
                };

                const target = githubReleaseToDownloadTarget(
                    alloc,
                    logger,
                    release,
                    toSemverString,
                    matchingAsset,
                ) catch |err| switch (err) {
                    error.NoMatchingTarget, error.InvalidVersion => continue,
                    else => return error.FailedConvertingToDownloadTarget,
                };

                try targets.append(alloc, target);
            }
        },
        else => {
            logger.warn("release api returned invalid json", .{});
            json.value.dump();
            return error.FailedConvertingToDownloadTarget;
        }
    }


    return targets;
}

pub const DownloadTarget = struct {
    versionString: []const u8,
    version: std.SemanticVersion,

    // can be null if no matching pre built binary exists
    tarball: ?[]const u8,

    /// use getTarballShasum function from ConfInterface if null
    shasum: ?[]const u8 = null,

    // used for building from source, is a link to archive
    source: ?[]const u8 = null,

    pub fn deinit(self: DownloadTarget, alloc: std.mem.Allocator) void {
        alloc.free(self.versionString);
        if (self.tarball) |tarball| alloc.free(tarball);
        if (self.shasum) |shasum| alloc.free(shasum);
        if (self.source) |source| alloc.free(source);
    }

    pub fn lessThan(_: void, a: DownloadTarget, b: DownloadTarget) bool {
        return a.version.order(b.version) == .gt;
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
    FailedOpeningFile,
} || std.mem.Allocator.Error;

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
} || std.mem.Allocator.Error;

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
        compression: compress.Compression,
        target: std.fs.File,
        tmpDir: std.fs.Dir,
    ) DecompressError!std.fs.Dir,

    getTarballShasum: ?*const fn (
        alloc: std.mem.Allocator,
        client: *std.http.Client,
        target: DownloadTarget,
        progress: std.Progress.Node,
    ) GetTarballShasumError!?[]const u8 = null,

    /// returns "loose" version string that would later be parsed by "parseUserVersion"
    resolveVersionFromFile: ?*const fn (
        alloc: std.mem.Allocator,
        filename: []const u8,
        file: std.fs.File,
    ) ?[]const u8 = null,

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
