const std = @import("std");
const builtin = @import("builtin");
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

pub fn runAndGetStdout(
    alloc: std.mem.Allocator,
    args: []const []const u8,
    options: RunOptions,
) RunError![]const u8 {
    const argsString = std.mem.join(alloc, " ", args) catch unreachable;
    defer alloc.free(argsString);

    std.log.info("executing - {s}", .{argsString});

    var runProcess: std.process.Child = .init(args, alloc);
    runProcess.stdin_behavior = .Ignore;
    runProcess.stdout_behavior = .Pipe;
    runProcess.stderr_behavior = options.stderrBehaivor;
    runProcess.create_no_window = true;
    runProcess.cwd_dir = options.cwdDir;
    runProcess.env_map = options.envMap;

    runProcess.spawn() catch return RunError.FailedSpawning;
    errdefer _ = runProcess.kill() catch {};

    var stream: std.Io.Writer.Allocating = .init(alloc);
    errdefer stream.deinit();

    var stdout = runProcess.stdout.?.reader(&.{});
    _ = stdout.interface.streamRemaining(&stream.writer) catch return RunError.FailedRunning;

    const res = runProcess.wait() catch |err| {
        std.log.err("failed spawning with {s}", .{@errorName(err)});
        return RunError.FailedSpawning;
    };

    switch (res) {
        .Exited => |e| if (e != 0) return RunError.FailedRunning,
        .Signal, .Stopped, .Unknown => return RunError.FailedRunning,
    }

    return alloc.realloc(stream.writer.buffer, stream.writer.end);
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
        std.mem.trim(u8, v, &std.ascii.whitespace),
    ) catch null;
}

pub fn markExecutablesInDir(dir: std.fs.Dir) void {
    var iter = dir.iterate();
    const targetExt = if (builtin.os.tag == .windows) "exe" else "";

    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;

        const ext = std.fs.path.extension(entry.name);
        if (!std.mem.eql(u8, ext, targetExt)) {
            continue;
        }

        const file = dir.openFile(entry.name, .{}) catch continue;
        defer file.close();

        // Make it executable by adding execute permissions for user, group, and others
        // 0o755 means: rwxr-xr-x (user: read+write+execute, group: read+execute, others: read+execute)
        file.chmod(0o755) catch {};
    }
}

pub fn openFirstDirWithLog(
    dir: std.fs.Dir,
    logger: @TypeOf(std.log),
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
    logger: @TypeOf(std.log),
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

pub fn BuildRustTarget(
    c: struct {
        logger: @TypeOf(std.log),
        executableName: []const u8,
    },
) @FieldType(ConfInterface, "buildTarget") {
    return struct {
        fn impl(
            alloc: std.mem.Allocator,
            progress: std.Progress.Node,
            sourceDir: std.fs.Dir,
            context: BuildTargetContext,
        ) BuildFromSourceError!std.fs.Dir {
            const logger = c.logger;
            const executableName = c.executableName;

            progress.setEstimatedTotalItems(6);

            sourceDir.makeDir(".cargo_home") catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    logger.err("failed creating .cargo_home dir with {s}", .{@errorName(err)});
                    return BuildFromSourceError.FailedBuilding;
                },
            };
            sourceDir.makeDir(".cargo") catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    logger.err("failed creating .cargo dir with {s}", .{@errorName(err)});
                    return BuildFromSourceError.FailedBuilding;
                },
            };
            progress.completeOne();

            var envMap = std.process.getEnvMap(alloc) catch |err| {
                logger.err("failed getting current env map with {s}", .{@errorName(err)});
                return BuildFromSourceError.FailedBuilding;
            };
            defer envMap.deinit();

            // reused multiple times
            var pathBuf: [std.fs.max_path_bytes]u8 = undefined;

            const cargoHomeDirpath = sourceDir.realpath(".cargo_home", &pathBuf) catch |err| {
                logger.err("failed reading realpath of .cargo_home folder with {s}", .{@errorName(err)});
                return BuildFromSourceError.FailedBuilding;
            };
            try envMap.put("CARGO_HOME", cargoHomeDirpath);

            const sourceDirPath = sourceDir.realpath(".", &pathBuf) catch |err| {
                logger.err("failed resolving realpath for source dir with {s}", .{@errorName(err)});
                return BuildFromSourceError.FailedBuilding;
            };
            try envMap.put("CWD", sourceDirPath);
            try envMap.put("PWD", sourceDirPath);

            var paths: std.array_list.Aligned([]const u8, null) = try .initCapacity(alloc, context.depsBinDirs.size);
            defer paths.deinit(alloc);

            var binsIter = context.depsBinDirs.valueIterator();
            while (binsIter.next()) |entry| paths.appendAssumeCapacity(entry.*);

            if (paths.items.len > 0) {
                const joinedPath = try std.mem.join(alloc, &.{std.fs.path.delimiter}, paths.items);
                defer alloc.free(joinedPath);

                if (envMap.get("PATH")) |currentPath| {
                    const expandedPath = try std.mem.join(alloc, &.{std.fs.path.delimiter}, &.{ joinedPath, currentPath });
                    defer alloc.free(expandedPath);

                    try envMap.put("PATH", expandedPath);
                } else {
                    try envMap.put("PATH", joinedPath);
                }
            }
            progress.completeOne();

            const cargo = if (context.depsBinDirs.get("rust")) |rustBinDirPath|
                std.fmt.bufPrint(&pathBuf, "{s}{c}{s}", .{
                    std.mem.trimEnd(u8, rustBinDirPath, &.{std.fs.path.sep}),
                    std.fs.path.sep,
                    "cargo",
                }) catch unreachable
            else
                "cargo"; // no rust in deps bin dirs means we already have rust installed

            const runOptions: RunOptions = .{
                .cwdDir = sourceDir,
                .envMap = &envMap,
                .stderrBehaivor = .Ignore,
            };

            logger.info("fetching cargo deps...", .{});
            const stdout = runAndGetStdout(alloc, &.{
                cargo,
                "vendor",
                "--locked",
                "--versioned-dirs",
            }, runOptions) catch |err| {
                logger.err("failed fetching cargo deps with {s}", .{@errorName(err)});
                return BuildFromSourceError.FailedBuilding;
            };
            defer alloc.free(stdout);
            progress.completeOne();

            const configToml = ".cargo/config.toml";
            sourceDir.writeFile(.{
                .data = stdout,
                .sub_path = configToml,
            }) catch |err| {
                logger.err("failed writing {s} file with {s}", .{ configToml, @errorName(err) });
                return BuildFromSourceError.FailedBuilding;
            };
            progress.completeOne();

            logger.info("building {s}...", .{executableName});
            run(alloc, &.{
                cargo,
                "build",
                "--release",
                "--offline",
                "--frozen",
            }, runOptions) catch |err| {
                logger.err("failed fetching cargo deps with {s}", .{@errorName(err)});
                return BuildFromSourceError.FailedBuilding;
            };
            progress.completeOne();

            var binDir = sourceDir.makeOpenPath("bin", .{}) catch |err| {
                logger.err("failed creating or opening bin dir with {s}", .{@errorName(err)});
                return BuildFromSourceError.FailedBuilding;
            };
            errdefer binDir.close();

            sourceDir.rename(
                std.fmt.comptimePrint("target/release/{s}", .{executableName}),
                std.fmt.comptimePrint("bin/{s}", .{executableName}),
            ) catch |err| {
                logger.err("failed moving ouch executable in bin folder with {s}", .{@errorName(err)});
                sourceDir.deleteTree("target") catch {};
                sourceDir.deleteTree("bin") catch {};
                return BuildFromSourceError.FailedBuilding;
            };
            progress.completeOne();

            return binDir;
        }
    }.impl;
}

pub fn githubTagToDownloadTarget(
    alloc: std.mem.Allocator,
    logger: @TypeOf(std.log),
    item: std.json.Value,
    toSemverString: *const fn (alloc: std.mem.Allocator, source: []const u8) ?[]const u8,
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
    logger: @TypeOf(std.log),
    release: std.json.ObjectMap,
    toSemverString: *const fn (alloc: std.mem.Allocator, source: []const u8) ?[]const u8,
    matchingAsset: *const fn (assetName: []const u8) bool,
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

pub fn FetchGithubRelease(
    c: struct {
        relaseUrl: []const u8,
        logger: @TypeOf(std.log),
        toSemverString: *const fn (alloc: std.mem.Allocator, source: []const u8) ?[]const u8,
        matchingAsset: *const fn (assetName: []const u8) bool,
    },
) @FieldType(ConfInterface, "getDownloadTargets") {
    return struct {
        fn impl(
            alloc: std.mem.Allocator,
            client: *std.http.Client,
            progress: std.Progress.Node,
        ) DownloadTargetError!DownloadTargets {
            const logger = c.logger;

            var stream: std.Io.Writer.Allocating = .init(alloc);
            defer stream.deinit();

            progress.setEstimatedTotalItems(1);

            const result = client.fetch(.{
                .method = .GET,
                .location = .{ .url = c.relaseUrl },
                .response_writer = &stream.writer,
                .headers = consts.DEFAULT_HEADERS,
                .keep_alive = false,
            }) catch |err| {
                logger.err("Error while fetching: {s}", .{@errorName(err)});
                return error.FailedFetchingVersionJson;
            };

            progress.completeOne();

            if (result.status != .ok) {
                logger.err("unexpected result status: {s}", .{@tagName(result.status)});
                return error.FailedFetchingVersionJson;
            }

            const written = stream.written();
            if (written.len == 0) {
                logger.err("unexpected empty result", .{});
                return error.FailedFetchingVersionJson;
            }

            const json: std.json.Parsed(std.json.Value) = std.json.parseFromSlice(
                std.json.Value,
                alloc,
                written,
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
                        c.toSemverString,
                        c.matchingAsset,
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
                            c.toSemverString,
                            c.matchingAsset,
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
                },
            }

            return targets;
        }
    }.impl;
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

    pub fn copy(self: DownloadTarget, alloc: std.mem.Allocator) !DownloadTarget {
        const versionString = try alloc.dupe(u8, self.versionString);
        errdefer alloc.free(versionString);

        const tarball = if (self.tarball) |x| try alloc.dupe(u8, x) else null;
        errdefer if (tarball) |x| alloc.free(x);

        const shasum = if (self.shasum) |x| try alloc.dupe(u8, x) else null;
        errdefer if (shasum) |x| alloc.free(x);

        const source = if (self.source) |x| try alloc.dupe(u8, x) else null;
        errdefer if (source) |x| alloc.free(x);

        return DownloadTarget{
            .versionString = versionString,
            .version = std.SemanticVersion.parse(versionString) catch unreachable,
            .tarball = tarball,
            .shasum = shasum,
            .source = source,
        };
    }

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
} || std.mem.Allocator.Error;

pub const BuildTargetContext = struct {
    /// this should not be used to "precreate" target folder. It's used only for building
    /// purposes. `git` conf requires `prefix` at build time to point where git executable will
    /// live
    targetDirPath: []const u8,
    /// if conf says that it depends on `rust` for building, this would include `/path/to/rust` +
    /// rustConf.binPath
    depsBinDirs: std.hash_map.StringHashMapUnmanaged([]const u8),

    /// assumes that both targetDirPath and depsBinDirs are allocated using "alloc".
    /// assumes that depsBinDirs keys are statically allocated, so only map keys will be freed
    pub fn deinit(self: *BuildTargetContext, alloc: std.mem.Allocator) void {
        alloc.free(self.targetDirPath);

        var iter = self.depsBinDirs.iterator();
        while (iter.next()) |entry| alloc.free(entry.value_ptr.*);
        self.depsBinDirs.deinit(alloc);
    }
};

pub const ConfInterface = struct {
    type: enum { Runtime, Package },

    name: []const u8,

    /// relative to root of extracted folder, so:
    /// `copper/node/default` + binPath = `copper/node/default/bin`
    binPath: []const u8 = "",

    /// relative to root of extracted folder, same logic to binPath
    manPages: ?[]const []const u8 = null,

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

    /// these files will be checked on each cwd change and it if exists, related
    /// conf.resolveVersionFromFile will be called
    fileHooks: ?[]const []const u8 = null,

    /// returns "loose" version string that would later be parsed by "parseUserVersion"
    resolveVersionFromFile: ?*const fn (
        alloc: std.mem.Allocator,
        filename: []const u8,
        file: std.fs.File,
    ) ?[]const u8 = null,

    /// config names to install before build
    buildDeps: ?[]const []const u8 = null,

    buildTarget: ?*const fn (
        alloc: std.mem.Allocator,
        progress: std.Progress.Node,
        sourceDir: std.fs.Dir,
        context: BuildTargetContext,
    ) BuildFromSourceError!std.fs.Dir = null,
};
