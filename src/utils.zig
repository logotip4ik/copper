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
                a = a ++ sep ++ string;
            }
        }

        break :blk a;
    };
}

fn countMatchingChars(noalias str1: []const u8, noalias str2: []const u8) u8 {
    const smallerOne = if (str1.len < str2.len) str1 else str2;
    const longerOne = if (str1.len < str2.len) str2 else str1;

    const maxI = @min(smallerOne.len, std.math.maxInt(u8));
    var sum: u8 = 0;
    for (0..maxI) |i| {
        if (longerOne[i] == smallerOne[i]) sum += 1;
    }

    return sum;
}

pub fn resolveConfig(configName: []const u8, writer: *std.Io.Writer) ?common.ConfInterface {
    return configs.configs.get(configName) orelse {
        const configNames = configs.configs.keys();

        var candidate = .{
            .value = configNames[0],
            .rank = countMatchingChars(configNames[0], configName),
        };

        for (configNames[1..]) |conf| {
            const rank = countMatchingChars(conf, configName);
            if (rank > candidate.rank) {
                candidate.value = conf;
                candidate.rank = rank;
            }
        }

        writer.print("{s} not found - did you mean {s}?\n", .{
            configName,
            candidate.value,
        }) catch unreachable;

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

    const minor = if (iter.next()) |x|
        std.fmt.parseUnsigned(u32, x, 10) catch return error.InvalidMinorNumber
    else
        null;

    const patch = if (iter.next()) |x|
        std.fmt.parseUnsigned(u32, x, 10) catch return error.InvalidPatchNumber
    else
        null;

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

const ProgressBar = struct {
    w: *std.Io.Writer,
    length_current: usize,
    length_total: ?usize,
    terminal_width: u16,

    pub fn init(io: std.Io, w: *std.Io.Writer, end: ?usize) !ProgressBar {
        const self = ProgressBar{
            .w = w,
            .length_current = 0,
            .length_total = end,
            .terminal_width = ProgressBar.getTerminalWidth(io) catch 1,
        };

        // hide cursor
        try w.writeAll("\x1B[?25l");

        return self;
    }

    pub fn finish(self: *ProgressBar) !void {
        try self.w.writeByte('\r');
        for (0..self.terminal_width) |_| try self.w.writeByte(' ');

        // show cursor
        try self.w.writeAll("\r\x1B[?25h");
        try self.w.flush();
    }

    pub fn advance(self: *ProgressBar, size: usize) !void {
        if (self.length_total) |length| {
            try self.advanceWidthLength(size, length);
        } else {
            try self.advanceUnknownLength();
        }
        try self.w.flush();
    }

    fn advanceWidthLength(self: *ProgressBar, advance_by: usize, total_length: usize) !void {
        self.length_current += advance_by;
        const progress = self.length_current * self.terminal_width / total_length;
        const clamped = @min(progress, self.terminal_width);

        try self.w.writeByte('\r');
        for (0..clamped) |_| try self.w.writeByte('#');
        for (clamped..self.terminal_width) |_| try self.w.writeByte(' ');
    }

    fn advanceUnknownLength(self: *ProgressBar) !void {
        const frames = [_]u8{ '-', '\\', '|', '/' };
        defer self.length_current = @rem(self.length_current + 1, frames.len);

        const frame = frames[self.length_current];
        try self.w.print("{c}\r", .{frame});
    }

    pub fn getTerminalWidth(io: std.Io) !u16 {
        if (builtin.target.os.tag == .windows) {
            const stdout = std.Io.File.stdout();
            var getInfo = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;

            switch (try getInfo.operate(io, stdout)) {
                .SUCCESS => {
                    const width: u16 = @intCast(@max(0, getInfo.Data.dwWindowSize.X));
                    return width;
                },
                else => {
                    return 0;
                },
            }
        }

        const winsize = extern struct {
            ws_row: u16,
            ws_col: u16,
            ws_xpixel: u16,
            ws_ypixel: u16,
        };
        var ws: winsize = std.mem.zeroes(winsize);
        const TIOCGWINSZ: u32 = comptime switch (@import("builtin").os.tag) {
            .macos, .ios, .tvos, .watchos => 0x40087468,
            else => 0x5413,
        };
        const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0) return error.IoctlFailed;
        if (ws.ws_col == 0) return error.NotATerminal;
        return ws.ws_col;
    }
};

pub fn getTargetFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    store: *Store,
    target: *const common.DownloadTarget,
) !struct { []const u8, std.Io.File } {
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
        @branchHint(.unlikely);
        logger.err("failed creating request {s}", .{@errorName(err)});
        return error.CreatingRequest;
    };
    defer req.deinit();

    logger.info("sending request {s}", .{downloadUrl});

    req.sendBodiless() catch |err| {
        @branchHint(.unlikely);
        logger.err("failed sending request {s}", .{@errorName(err)});
        return error.FailedWhileFetching;
    };

    logger.debug("receiving head...", .{});

    var redirectBuf: [2 * 1024]u8 = undefined;
    var res = req.receiveHead(&redirectBuf) catch |err| {
        @branchHint(.unlikely);
        logger.err("failed sending request {s}", .{@errorName(err)});
        return error.FailedWhileFetching;
    };

    if (res.head.status != .ok) {
        @branchHint(.unlikely);
        logger.err("failed fetching {s}, response status: {s}", .{
            downloadUrl,
            @tagName(res.head.status),
        });
        return error.NotOkResponse;
    }

    // we need to remove `.` from version string, because later, we can use `std.fs.extension`
    // on filename, but this will return something wrong, if we downloaded uncompressed file
    const versionStringWithoutDots = blk: {
        const string = alloc.alloc(u8, target.versionString.len) catch unreachable;
        for (target.versionString, 0..) |char, i| {
            string[i] = if (char == '.') '_' else char;
        }
        break :blk string;
    };
    defer alloc.free(versionStringWithoutDots);

    const tarballName: ?[]const u8 = if (res.head.content_disposition) |disposition| blk: {
        var chunksIter = std.mem.splitScalar(u8, disposition, ';');
        while (chunksIter.next()) |chunk| {
            var entryIter = std.mem.splitScalar(u8, std.mem.trim(u8, chunk, " "), '=');

            const name = entryIter.next() orelse continue;
            const value = entryIter.next() orelse continue;

            if (std.ascii.eqlIgnoreCase(name, "filename")) {
                break :blk try std.fmt.allocPrint(alloc, "{s}{s}", .{
                    versionStringWithoutDots,
                    value,
                });
            }
        }

        break :blk null;
    } else null;

    const filename: []const u8 = tarballName orelse blk: {
        break :blk std.fmt.allocPrint(alloc, "{s}{s}", .{
            versionStringWithoutDots,
            std.fs.path.basename(downloadUrl),
        }) catch unreachable;
    };
    errdefer alloc.free(filename);

    logger.debug("resolved filename to: {s}", .{filename});

    const tmpDir = try store.getDir(.tmp);
    if (tmpDir.openFile(io, filename, .{ .mode = .read_write })) |file| {
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

    const downloadFile = tmpDir.createFile(io, downloadFilename, .{ .read = true }) catch {
        @branchHint(.unlikely);
        logger.err("failed opening {s} file in {s}", .{ downloadFilename, store.tmpDirPath });
        return error.FailedCreatingDownloadFile;
    };
    errdefer downloadFile.close(io);

    logger.debug("opened download file {s}", .{downloadFilename});

    var fileWriter = downloadFile.writer(io, &.{});
    defer fileWriter.interface.flush() catch unreachable;

    const decompress_buffer = try alloc.alloc(u8, res.head.content_encoding.minBufferCapacity());
    defer alloc.free(decompress_buffer);

    var transferBuf: [64 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = res.readerDecompressing(&transferBuf, &decompress, decompress_buffer);

    logger.debug("fetching {t} stream, transfer_encoding {t}, content_length {?d}", .{
        res.head.content_encoding,
        res.head.transfer_encoding,
        res.head.content_length,
    });

    var progress_buf: [64]u8 = undefined;
    const lock = try io.lockStderr(&progress_buf, null);
    var bar: ProgressBar = try .init(io, &lock.file_writer.interface, res.head.content_length);

    while (true) {
        const buf = reader.take(reader.buffer.len) catch |err| {
            @branchHint(.cold);
            switch (err) {
                error.EndOfStream => {
                    const rest = reader.buffered();
                    try fileWriter.interface.writeAll(rest);
                    break;
                },
                else => {
                    logger.err("failed fetching, check your internet connection maybe ?", .{});
                    return error.FailedFetching;
                },
            }
        };
        try fileWriter.interface.writeAll(buf);
        try bar.advance(buf.len);
    }

    try fileWriter.interface.flush();
    try bar.finish();
    io.unlockStderr();

    tmpDir.rename(downloadFilename, tmpDir, filename, io) catch |err| {
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

const FetchAndDecompressContext = struct {
    progress: std.Progress.Node,
    client: *std.http.Client,
    store: *Store,
    output: *std.Io.Writer,
};

pub fn fetchAndDecompress(
    alloc: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ,
    conf: common.ConfInterface,
    targetVersion: TargetVersion,
    context: FetchAndDecompressContext,
) anyerror!struct { common.DownloadTarget, std.Io.Dir } {
    const progress = context.progress;
    const store = context.store;
    const client = context.client;
    const output = context.output;

    var installed: std.array_list.Aligned(Store.Install, null) = store.getConfInstallations(alloc, conf.name) catch .empty;
    defer {
        for (installed.items) |item| item.deinit();
        installed.deinit(alloc);
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
    var versions = conf.getDownloadTargets(alloc, io, client, downloadProgress) catch |err| {
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
        _ = try io.lockStderr(&.{}, null);
        defer io.unlockStderr();

        try output.print("No prebuilt {s} binary for {s} is available. Build from source? [y/N] ", .{
            @tagName(builtin.target.os.tag),
            conf.name,
        });
        try output.flush();

        const tty_path = switch (builtin.target.os.tag) {
            .windows => "\\\\.\\CON",
            else => "/dev/tty",
        };
        const tty = std.Io.Dir.openFileAbsolute(io, tty_path, .{ .mode = .read_only }) catch {
            try output.print("error: no interactive terminal available, cannot prompt.\n", .{});
            return error.Aborted;
        };
        defer tty.close(io);

        var ansBuf: [8]u8 = undefined;
        var reader = tty.reader(io, &ansBuf);
        const byte = reader.interface.takeByte() catch 'n';
        if (std.ascii.toLower(byte) != 'y') {
            try output.print("aborting.\n", .{});
            return error.Aborted;
        }
    };

    downloadProgress = progress.start("downloading target file", 0);
    const targetFilename, var targetFile = try getTargetFile(alloc, io, client, store, target);
    defer alloc.free(targetFilename);
    defer targetFile.close(io);
    downloadProgress.end();

    const verificationProgress = progress.start("verification", 1);
    const isTargetFileValid = try conf.verifyTargetFile(.{
        .alloc = alloc,
        .io = io,
        .client = client,
        .progress = verificationProgress,
    }, &targetFile, target);
    if (isTargetFileValid) |isValid| {
        if (isValid) {
            logger.info("verified target file", .{});
        } else {
            logger.err("verification failed, maybe try reruning add command", .{});
            return error.InvalidShasum;
        }
    } else {
        logger.warn("no verification method found, skipping", .{});
    }
    verificationProgress.end();

    const compression = guessCompression(targetFilename) orelse return error.UnknownCompression;

    const tmpDir = try store.prepareTmpDirForDecompression(conf.name, target.version);

    var decompressProgress = progress.start("decompressing", 0);
    var outDir = conf.decompressTargetFile(alloc, io, compression, targetFile, tmpDir) catch |err| {
        std.log.err("failed decompressing target file {s} with {s}", .{ targetFilename, @errorName(err) });
        return err;
    };
    decompressProgress.end();

    const buildTarget = conf.buildTarget orelse {
        return .{ try target.copy(alloc), outDir };
    };
    defer outDir.close(io);

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
        const depProgress = buildProgress.start(depPrgoressName, 0);
        defer depProgress.end();

        const depTarget, var depDir = fetchAndDecompress(alloc, io, environ, depConf, .{ .latest = true }, .{
            .progress = depProgress,
            .client = client,
            .store = store,
            .output = output,
        }) catch |err| switch (err) {
            error.TargetAlreadyInstalled, error.Aborted => continue,
            else => return err,
        };
        defer depTarget.deinit(alloc);
        defer depDir.close(io);

        const binPath = if (depConf.binPath.len == 0) "." else depConf.binPath;
        const depBinDirpath = try depDir.realPathFileAlloc(io, binPath, alloc);
        errdefer alloc.free(depBinDirpath);

        logger.debug("fetched {s} conf into {s}", .{ depConf.name, depBinDirpath });

        try buildContext.depsBinDirs.putNoClobber(alloc, depConf.name, depBinDirpath);
    }

    var envMap = try environ.createMap(alloc);
    defer envMap.deinit();

    const buildDir = buildTarget(alloc, io, &envMap, buildProgress, outDir, buildContext) catch |err| {
        std.log.err("failed building with {s}", .{@errorName(err)});
        return err;
    };

    return .{ try target.copy(alloc), buildDir };
}

pub fn printOutdated(
    alloc: std.mem.Allocator,
    io: std.Io,
    conf: common.ConfInterface,
    client: *std.http.Client,
    progress: std.Progress.Node,
    store: *Store,
    writer: *std.Io.Writer,
) void {
    var confP = progress.start(conf.name, 0);
    defer confP.end();

    var remote = conf.getDownloadTargets(alloc, io, client, confP) catch |err| {
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

    var local = store.getConfInstallations(alloc, conf.name) catch |err| {
        @branchHint(.unlikely);
        logger.err("Faield retriving installed targets for {s} with {s}", .{ conf.name, @errorName(err) });
        return;
    };
    defer {
        for (local.items) |item| item.deinit();
        local.deinit(alloc);
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

    _ = io.lockStderr(&.{}, null) catch {};
    defer io.unlockStderr();

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
    try writer.print("{s} {f} {s}\nzig {f}\n", .{
        consts.EXE_NAME,
        buildOptions.version,
        @tagName(builtin.mode),
        builtin.zig_version,
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
