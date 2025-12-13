const std = @import("std");
const builtin = @import("builtin");
const buildOptions = @import("build_options");
const consts = @import("consts");
const compress = @import("compress");

const Store = @import("./store.zig");
const common = @import("./config/common.zig");
const configs = @import("./config/configs.zig");

const logger = std.log.scoped(.utils);

pub fn concatComptime(comptime strings: []const []const u8, comptime sep: []const u8) []const u8 {
    return comptime blk: {
        var a: []const u8 = "";

        for (strings, 0..) |string, i| {
            if (i == 0) {
                a = a ++ string;
            } else {
                const chunk = sep ++ string;
                a = a ++ chunk;
            }
        }

        break :blk a;
    };
}

pub fn resolveConfig(configName: []const u8, writer: *std.Io.Writer) ?common.ConfInterface {
    return configs.configs.get(configName) orelse {
        writer.print("available configs: ", .{}) catch unreachable;

        const available = comptime configs.configs.keys();
        inline for (available, 0..) |conf, i| {
            if (i == 0) {
                writer.print("{s}", .{available[0]}) catch unreachable;
            } else {
                writer.print(", {s}", .{conf}) catch unreachable;
            }
        }
        writer.writeByte('\n') catch unreachable;

        return null;
    };
}

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
    const major = std.fmt.parseUnsigned(u32, majorStr, 10) catch return error.InvalidMajorNumber;

    var minor: ?u32 = null;
    if (iter.next()) |minorStr| {
        minor = std.fmt.parseUnsigned(u32, minorStr, 10) catch return error.InvalidMinorNumber;
    }

    var patch: ?u32 = null;
    if (iter.next()) |patchStr| {
        patch = std.fmt.parseUnsigned(u32, patchStr, 10) catch return error.InvalidPatchNumber;
    }

    return SemanticVersion.Range{
        .min = SemanticVersion{
            .major = major,
            .minor = minor orelse 0,
            .patch = patch orelse 0,
        },
        .max = SemanticVersion{
            .major = major,
            .minor = minor orelse std.math.maxInt(usize),
            .patch = patch orelse std.math.maxInt(usize),
        },
    };
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

/// ext - result of running `std.fs.path.extension`
pub fn guessCompression(filepath: []const u8) ?compress.Compression {
    const ext = std.fs.path.extension(filepath);

    return std.meta.stringToEnum(
        compress.Compression,
        if (ext.len == 0) "uncompressed" else ext[1..],
    ) orelse {
        @branchHint(.unlikely);

        logger.err("unrecognised compression for {s}", .{filepath});
        return null;
    };
}

pub fn getTargetFile(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    store: *const Store,
    target: *const common.DownloadTarget,
) !struct { []const u8, std.fs.File } {
    const downloadUrl = target.tarball orelse target.source orelse {
        logger.err("both tarball and source fields are missing. Can't resolve download url", .{});
        return error.NoDownloadUrl;
    };

    var req = client.request(
        .GET,
        try std.Uri.parse(downloadUrl),
        .{
            .headers = consts.DEFAULT_HEADERS,
            .keep_alive = false,
        },
    ) catch |err| {
        logger.err("failed creating request {s}", .{@errorName(err)});
        return error.CreatingRequest;
    };
    defer req.deinit();

    logger.info("sending request {s}", .{downloadUrl});

    req.sendBodiless() catch |err| {
        logger.err("failed sending request {s}", .{@errorName(err)});
        return error.FailedWhileFetching;
    };

    logger.debug("receiving head...", .{});

    var redirectBuf: [2 * 1024]u8 = undefined;
    var res = req.receiveHead(&redirectBuf) catch |err| {
        logger.err("failed sending request {s}", .{@errorName(err)});
        return error.FailedWhileFetching;
    };

    if (res.head.status != .ok) {
        logger.err("failed fetching {s}, response status: {s}", .{
            downloadUrl,
            @tagName(res.head.status),
        });
        return error.NotOkResponse;
    }

    const tarballName: ?[]const u8 = if (res.head.content_disposition) |disposition| blk: {
        var chunksIter = std.mem.splitScalar(u8, disposition, ';');
        while (chunksIter.next()) |chunk| {
            var entryIter = std.mem.splitScalar(u8, std.mem.trim(u8, chunk, " "), '=');

            const name = entryIter.next() orelse continue;
            const value = entryIter.next() orelse continue;

            if (std.ascii.eqlIgnoreCase(name, "filename")) {
                break :blk try alloc.dupe(u8, value);
            }
        }

        break :blk null;
    } else null;

    const filename: []const u8 = tarballName orelse blk: {
        // we need to remove `.` from version string, because later, we can use `std.fs.extension`
        // on filename, but this will return something wrong, if we downloaded uncompressed file
        const versionStringWithoutDots = alloc.alloc(u8, target.versionString.len) catch unreachable;
        defer alloc.free(versionStringWithoutDots);
        for (target.versionString, 0..) |char, i| {
            if (char == '.') versionStringWithoutDots[i] = '_' else versionStringWithoutDots[i] = char;
        }

        break :blk std.fmt.allocPrint(alloc, "{s}{s}", .{
            versionStringWithoutDots,
            std.fs.path.basename(downloadUrl),
        }) catch unreachable;
    };
    errdefer alloc.free(filename);

    logger.debug("resolved filename to: {s}", .{filename});

    if (store.tmpDir.openFile(filename, .{ .mode = .read_write })) |file| {
        logger.info("using cached file from {f}", .{
            std.fs.path.fmtJoin(&[_][]const u8{
                store.tmpDirPath,
                filename,
            }),
        });
        return .{ filename, file };
    } else |_| {}

    var downloadFilenameBuf: [std.fs.max_name_bytes]u8 = undefined;
    const downloadFilename = std.fmt.bufPrint(&downloadFilenameBuf, "p_{s}", .{filename}) catch unreachable;

    const downloadFile = store.tmpDir.createFile(downloadFilename, .{ .read = true }) catch {
        logger.err("failed opening {s} file in {s}", .{ downloadFilename, store.tmpDirPath });
        return error.FailedCreatingDownloadFile;
    };
    errdefer downloadFile.close();

    logger.debug("opened download file {s}", .{downloadFilename});

    var fileWriter = downloadFile.writer(&.{});
    defer fileWriter.interface.flush() catch unreachable;

    var hasherBuffer: [64 * 1024]u8 = undefined;
    const hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    var hashedFileWriter = std.Io.Writer.hashed(&fileWriter.interface, hasher, &hasherBuffer);

    const decompress_buffer = try alloc.alloc(u8, res.head.content_encoding.minBufferCapacity());
    defer alloc.free(decompress_buffer);

    var transferBuf: [64 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = res.readerDecompressing(&transferBuf, &decompress, decompress_buffer);

    logger.debug("fetching {s} stream, transfer_encoding {s}, content_length {d}", .{
        @tagName(res.head.content_encoding),
        @tagName(res.head.transfer_encoding),
        res.head.content_length orelse 0,
    });

    while (true) {
        // TODO: should be replaced with stream, to omit allocating yet another buffer, but
        // in 0.15.2 it can still be buggy. `mongodb-database-tools` always fails streaming...
        const buf = reader.take(reader.buffer.len) catch |err| switch (err) {
            error.EndOfStream => {
                const rest = reader.buffered();
                try hashedFileWriter.writer.writeAll(rest);
                break;
            },
            else => {
                @branchHint(.unlikely);
                logger.err("failed fetching, check your internet connection maybe ?", .{});
                return error.FailedFetching;
            },
        };
        try hashedFileWriter.writer.writeAll(buf);
    }

    try hashedFileWriter.writer.flush();

    if (target.shasum) |expected| {
        const result = std.fmt.bytesToHex(hashedFileWriter.hasher.finalResult(), .lower);

        if (std.mem.eql(u8, expected, &result)) {
            logger.info("shasum matches expected", .{});
        } else {
            logger.err("shasum verification failed, try reruning add command", .{});
            return error.InvalidShasum;
        }
    } else {
        logger.info("skipping shasum verification, no target shasum were found", .{});
    }

    store.tmpDir.rename(downloadFilename, filename) catch |err| {
        logger.err("{s} failed renaming {s} to {s} in {s} dir", .{
            @errorName(err),
            downloadFilename,
            filename,
            store.tmpDirPath,
        });
        return error.FailedDownloadFinalization;
    };
    logger.debug("renamed pending download file {s} to {s}", .{ downloadFilename, filename });

    return .{ filename, downloadFile };
}

pub const TargetVersion = union(enum) {
    latest: bool,
    loose: []const u8,
};

pub fn fetchAndDecompress(
    alloc: std.mem.Allocator,
    progress: std.Progress.Node,
    client: *std.http.Client,
    store: *const Store,
    conf: common.ConfInterface,
    targetVersion: TargetVersion,
    output: *std.Io.Writer,
) anyerror!struct { common.DownloadTarget, std.fs.Dir } {
    var installed: std.array_list.Managed(Store.Install) = store.getConfInstallations(conf.name) catch .init(alloc);
    defer {
        for (installed.items) |item| item.deinit();
        installed.deinit();
    }

    switch (targetVersion) {
        .latest => {},
        .loose => |looseVersion| {
            const range = try parseUserVersion(looseVersion);
            for (installed.items) |item| {
                if (!range.includesVersion(item.version)) {
                    continue;
                }

                return error.TargetAlreadyInstalled;
            }
        },
    }

    var downloadProgress = progress.start("downloading versions", 0);
    var versions = conf.getDownloadTargets(alloc, client, downloadProgress) catch |err| {
        std.log.err("failed fetching versions file with {s}", .{@errorName(err)});
        return err;
    };
    downloadProgress.end();
    defer {
        for (versions.items) |item| item.deinit(alloc);
        versions.deinit(alloc);
    }

    if (versions.items.len == 0) {
        std.log.info("no download targets found for {s}", .{conf.name});
        return error.NoDownloadTargets;
    }

    const target = switch (targetVersion) {
        .latest => blk: {
            // select first "stable" build
            for (versions.items) |*item| {
                if (item.version.pre == null and item.version.build == null) {
                    break :blk item;
                }
            }

            // select latest one as a last resort
            break :blk &versions.items[0];
        },
        .loose => |loose| switch (conf.type) {
            .Package => &versions.items[0],
            .Runtime => blk: {
                const allowedVersions = try parseUserVersion(loose);

                for (versions.items) |*item| {
                    if (allowedVersions.includesVersion(item.version)) {
                        break :blk item;
                    }
                } else {
                    std.log.info("no target matching {s} version found", .{loose});
                    return error.NoMatchingTarget;
                }
            },
        },
    };
    logger.info("resolved {s} to {f}", .{ conf.name, target.version });

    if (installed.items.len > 0) switch (conf.type) {
        .Package => {
            const latestInstalled = installed.items[0];
            if (target.version.order(latestInstalled.version) != .gt) {
                return error.TargetAlreadyInstalled;
            }
        },
        .Runtime => {
            for (installed.items) |item| {
                if (item.version.order(target.version) == .eq) {
                    return error.TargetAlreadyInstalled;
                }
            }
        },
    };

    if (target.tarball == null) if (conf.buildTarget == null) {
        std.log.info(
            "unable to install {s}: no prebuilt tarball and no source build method available",
            .{conf.name},
        );
        return error.NoInstallMethods;
    } else {
        std.Progress.lockStdErr();
        defer std.Progress.unlockStdErr();

        try output.print("No prebuilt {s} binary for {s} is available. Build from source? [y/N] ", .{
            @tagName(builtin.target.os.tag),
            conf.name,
        });
        try output.flush();

        var ansBuf: [1]u8 = undefined;
        const read = try std.fs.File.stdin().read(&ansBuf);

        if (read == 0 or !std.ascii.eqlIgnoreCase(&ansBuf, "y")) {
            try output.print("aborting.\n", .{});
            return error.Aborted;
        }
    };

    if (conf.getTarballShasum) |getTarballShasum| {
        progress.increaseEstimatedTotalItems(1);
        var fetchingShasumProgress = progress.start("fetching shasum", 0);
        defer fetchingShasumProgress.end();

        target.shasum = getTarballShasum(
            alloc,
            client,
            target.*,
            fetchingShasumProgress,
        ) catch |err| {
            std.log.err("failed fething tarball shasum with {s} error", .{@errorName(err)});
            return err;
        };
    }

    downloadProgress = progress.start("downloading target file", 0);
    const targetFilename, const targetFile = try getTargetFile(alloc, client, store, target);
    defer alloc.free(targetFilename);
    defer targetFile.close();
    downloadProgress.end();

    const compression = guessCompression(targetFilename) orelse return error.UnknownCompression;

    const tmpDir = try store.prepareTmpDirForDecompression(conf.name, target.version);

    var decompressProgress = progress.start("decompressing", 0);
    var outDir = conf.decompressTargetFile(alloc, compression, targetFile, tmpDir) catch |err| {
        std.log.err("failed decompressing target file {s} with {s}", .{ targetFilename, @errorName(err) });
        return err;
    };
    decompressProgress.end();

    const buildTarget = conf.buildTarget orelse {
        return .{ try target.copy(alloc), outDir };
    };
    defer outDir.close();

    const buildDeps = conf.buildDeps orelse &.{};

    progress.increaseEstimatedTotalItems(1);
    var buildProgress = progress.start("building", 1 + buildDeps.len);
    defer buildProgress.end();

    var buildContext: common.BuildTargetContext = .{
        .targetDirPath = store.generateSaveOutDirPath(alloc, conf.name, target.versionString),
        .depsBinDirs = .empty,
    };
    defer buildContext.deinit(alloc);

    var donwloadNameBuf: [128]u8 = undefined;
    for (buildDeps) |dep| {
        const depConf = resolveConfig(dep, output) orelse unreachable;

        const depPrgoressName = std.fmt.bufPrint(&donwloadNameBuf, "fetching {s} build depenency", .{
            depConf.name,
        }) catch unreachable;
        const p = buildProgress.start(depPrgoressName, 0);
        defer p.end();

        const depTarget, var depDir = fetchAndDecompress(
            alloc,
            p,
            client,
            store,
            depConf,
            .{ .latest = true },
            output,
        ) catch |err| switch (err) {
            error.TargetAlreadyInstalled => continue,
            else => return err,
        };
        defer depTarget.deinit(alloc);
        defer depDir.close();

        const binPath = if (depConf.binPath.len == 0) "." else depConf.binPath;
        const depBinDirpath = try depDir.realpathAlloc(alloc, binPath);

        logger.debug("fetched {s} conf into {s}", .{ depConf.name, depBinDirpath });

        try buildContext.depsBinDirs.put(alloc, depConf.name, depBinDirpath);
    }

    const buildDir = buildTarget(alloc, buildProgress, outDir, buildContext) catch |err| {
        std.log.err("failed building with {s}", .{@errorName(err)});
        return err;
    };

    return .{ try target.copy(alloc), buildDir };
}

pub fn printOutdated(
    alloc: std.mem.Allocator,
    conf: common.ConfInterface,
    client: *std.http.Client,
    progress: std.Progress.Node,
    store: *const Store,
    writer: *std.Io.Writer,
) void {
    var confP = progress.start(conf.name, 0);
    defer confP.end();

    var remote = conf.getDownloadTargets(alloc, client, confP) catch |err| {
        logger.err("Faield fetching download targets for {s} with {s}", .{ conf.name, @errorName(err) });
        return;
    };
    defer {
        for (remote.items) |item| item.deinit(alloc);
        remote.deinit(alloc);
    }

    if (remote.items.len == 0) {
        return;
    }

    const local = store.getConfInstallations(conf.name) catch |err| {
        @branchHint(.unlikely);
        logger.err("Faield retriving installed targets for {s} with {s}", .{ conf.name, @errorName(err) });
        return;
    };
    defer {
        for (local.items) |item| item.deinit();
        local.deinit();
    }

    if (local.items.len == 0) {
        return;
    }

    const latestLocal = local.items[0];
    const latestRemote = remote.items[0];

    if (latestLocal.version.order(latestRemote.version) != .lt) {
        return;
    }

    var releasesBehind: u16 = 0;
    for (remote.items) |item| {
        if (item.version.order(latestLocal.version) == .gt) {
            releasesBehind += 1;
        }
    }

    std.Progress.lockStdErr();
    defer std.Progress.unlockStdErr();

    switch (conf.type) {
        .Runtime => {
            writer.print("{s} {f} < {f} +{d}\n", .{
                conf.name,
                latestLocal.version,
                latestRemote.version,
                releasesBehind,
            }) catch {};
        },
        .Package => {
            writer.print("{s} {f} < {f}\n", .{
                conf.name,
                latestLocal.version,
                latestRemote.version,
            }) catch {};
        },
    }
}

pub fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("{f} {s}\n", .{
        buildOptions.version,
        @tagName(builtin.mode),
    });
}

pub fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\copper - A utility to handle the installation and management of packages.
        \\
        \\USAGE:
        \\    copper <COMMAND> [ARGUMENTS...]
        \\
        \\COMMON COMMANDS:
        \\    install (alias: add)
        \\        Install a package version.
        \\
        \\    uninstall (aliases: remove, delete)
        \\        Remove a locally installed package version.
        \\
        \\    use
        \\        Set the default version for a package.
        \\
        \\    list-installed (alias: installed)
        \\        List locally installed package versions.
        \\
        \\    list-remote (alias: remote)
        \\        List remote packages available for installation.
        \\
        \\    update
        \\        Update a package to the latest available version.
        \\
        \\UTILITY COMMANDS:
        \\    shell <SHELL>
        \\        Generates the shell script needed for setup.
        \\        (Shells: zsh, bash, fish, pwsh)
        \\
        \\    configs (aliases: confs)
        \\        List all supported configs
        \\
        \\    store <SUBCOMMAND>
        \\        Manage the copper data and cache directories.
        \\        (Subcommands: dir, cache-dir, clear-cache)
        \\
        \\    update-self
        \\        Update copper to the latest version.
        \\
        \\EXAMPLES OF HOW TO USE COPPER:
        \\    # List all available Node.js versions starting with v22
        \\    $ copper remote node 22
        \\
        \\    # Install the latest available Node.js v22
        \\    $ copper install node 22
        \\
        \\    # Set the default Node.js to the latest installed v24
        \\    $ copper use node 24
        \\
        \\    # Show all locally installed versions of Node.js
        \\    $ copper list-installed node
        \\
    );
}
