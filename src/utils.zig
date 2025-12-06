const std = @import("std");
const builtin = @import("builtin");
const buildOptions = @import("build_options");
const consts = @import("consts");

const Store = @import("./store.zig");
const common = @import("./config/common.zig");
const configs = @import("./config/configs.zig");

const logger = std.log.scoped(.utils);

pub fn concatComptime(comptime strings: []const []const u8, comptime sep: []const u8) []const u8 {
    return comptime blk: {
        var length: usize = 0;
        for (strings) |string| {
            length += string.len;
        }
        length += sep.len * (strings.len - 1);

        var buf: [length]u8 = undefined;
        var writer: std.io.Writer = .fixed(&buf);

        for (strings, 0..) |string, i| {
            if (i == 0) {
                try writer.print("{s}", .{string});
            } else {
                try writer.print("{s}{s}", .{ sep, string });
            }
        }

        const final = buf;
        break :blk &final;
    };
}

pub fn resolveConfig(configName: []const u8) ?common.ConfInterface {
    return configs.configs.get(configName) orelse {
        var buf: [128]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        const stdout = &w.interface;
        defer stdout.flush() catch {};

        stdout.print("available configs: ", .{}) catch unreachable;

        const available = comptime configs.configs.keys();
        inline for (available, 0..) |conf, i| {
            if (i == 0) {
                stdout.print("{s}", .{available[0]}) catch unreachable;
            } else {
                stdout.print(", {s}", .{conf}) catch unreachable;
            }
        }
        stdout.writeByte('\n') catch unreachable;

        return null;
    };
}

/// ext - result of running `std.fs.path.extension`
pub fn guessCompression(filepath: []const u8) ?common.Compression {
    const ext = std.fs.path.extension(filepath);

    return std.meta.stringToEnum(
        common.Compression,
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
    var req = client.request(
        .GET,
        try std.Uri.parse(target.tarball),
        .{
            .headers = consts.DEFAULT_HEADERS,
            .keep_alive = false,
        },
    ) catch |err| {
        logger.err("failed creating request {s}", .{@errorName(err)});
        return error.CreatingRequest;
    };
    defer req.deinit();

    logger.debug("sending request {s}", .{target.tarball});

    req.sendBodiless() catch |err| {
        logger.err("failed sending request {s}", .{@errorName(err)});
        return error.FailedWhileFetching;
    };

    const redirectBuf = alloc.alloc(u8, 8 * 1024) catch return error.FailedAllocatingDownloadBuffer;
    defer alloc.free(redirectBuf);

    logger.debug("receiving head...", .{});
    var res = req.receiveHead(redirectBuf) catch |err| {
        logger.err("failed sending request {s}", .{@errorName(err)});
        return error.FailedWhileFetching;
    };

    if (res.head.status != .ok) {
        logger.err("failed fetching {s}, response status: {s}", .{
            target.tarball,
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
            std.fs.path.basename(target.tarball),
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

    const downloadFile = store.tmpDir.createFile(downloadFilename, .{ .read = true, .truncate = true }) catch {
        logger.err("failed opening {s} file in {s}", .{ downloadFilename, store.tmpDirPath });
        return error.FailedCreatingDownloadFile;
    };
    errdefer downloadFile.close();

    logger.debug("opened download file {s}", .{downloadFilename});

    var fileWriter = downloadFile.writer(&.{});
    defer fileWriter.interface.flush() catch unreachable;

    const decompress_buffer: []u8 = switch (res.head.content_encoding) {
        .identity => &.{},
        .zstd => try alloc.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try alloc.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer alloc.free(decompress_buffer);

    const transfer_buffer = try alloc.alloc(u8, 16 * 1024 * 1024);
    defer alloc.free(transfer_buffer);

    var decompress: std.http.Decompress = undefined;
    const reader = res.readerDecompressing(transfer_buffer, &decompress, decompress_buffer);

    logger.debug("fetching {s} stream, transfer_encoding {s}, content_length {d}", .{
        @tagName(res.head.content_encoding),
        @tagName(res.head.transfer_encoding),
        res.head.content_length orelse 0,
    });

    const streamBuf = try alloc.alloc(u8, 16 * 1024 * 1024);
    defer alloc.free(streamBuf);

    const contentLength = res.head.content_length.?;
    var offset: usize = 0;

    while (true) {
        // readSliceShort will fail if it buffer is larger than remeaining content to read, so we
        // need to manually handle sizing down buffer when we approach ending of the stream
        const buf = if (offset + streamBuf.len < contentLength)
            streamBuf
        else
            streamBuf[0..(contentLength - offset)];

        // TODO: should be replaced with stream, to omit allocating yet another buffer, but
        // in 0.15.2 it can still be buggy. `mongodb-database-tools` always fails streaming...
        const read = try reader.readSliceShort(buf);
        try fileWriter.interface.writeAll(buf[0..read]);

        offset += read;

        const progress: usize = @intFromFloat(@as(f64, @floatFromInt(offset)) / @as(f64, @floatFromInt(contentLength)) * 100);
        logger.debug("downloaded {d}% ({d} of {d})", .{ progress, offset, contentLength });

        if (offset == contentLength) {
            break;
        }
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

pub fn printOutdated(
    alloc: std.mem.Allocator,
    configName: []const u8,
    client: *std.http.Client,
    progress: std.Progress.Node,
    store: *const Store,
    writer: *std.Io.Writer,
) void {
    var confP = progress.start(configName, 0);
    defer confP.end();

    const conf = configs.configs.get(configName) orelse {
        @branchHint(.unlikely);
        logger.warn("{s} config is not supported", .{configName});
        return;
    };

    var remote = conf.getDownloadTargets(alloc, client, confP) catch |err| {
        logger.err("Faield fetching download targets for {s} with {s}", .{ configName, @errorName(err) });
        return;
    };
    defer {
        for (remote.items) |item| item.deinit(alloc);
        remote.deinit(alloc);
    }

    const local = store.getConfInstallations(configName) catch |err| {
        @branchHint(.unlikely);
        logger.err("Faield retriving installed targets for {s} with {s}", .{ configName, @errorName(err) });
        return;
    };
    defer {
        for (local.items) |item| item.deinit();
        local.deinit();
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

    writer.print("{s} {f} < {f} +{d}\n", .{
        configName,
        latestLocal.version,
        latestRemote.version,
        releasesBehind,
    }) catch {};
}

pub fn printVersion() !void {
    var w = std.fs.File.stdout().writer(&.{});
    const writer = &w.interface;
    defer writer.flush() catch {};

    try writer.print("{f} {s}\n", .{
        buildOptions.version,
        @tagName(builtin.mode),
    });
}

pub fn printHelp() !void {
    try std.fs.File.stdout().writeAll(
        \\copper - utility to handle installation of packages. Some examples of execution:
        \\
        \\  copper list-remote|remote node 22          - list all node 22.*.* versions which are available for installation on your machine. You can also omit `22` to see all available versions.
        \\  copper add|install node 22                 - fetch most recent node with matches 22.*.* version.
        \\  copper list-installed|installed node       - show installed node versions (you can also provide version to narrow log down)
        \\  copper remove|uninstall|delete node 22.*.* - remove node version 22.*.* if is installed.
        \\  copper use node 24                         - change default node version to 24.*.*
        \\  copper update node                         - update default node installation to latest available version
        \\
        \\To provide installed packages, copper needs to patch "$PATH" - do so call in your shell:
        \\
        \\  copper shell zsh|bash|fish|pwsh
        \\
        \\  Copper will add a hook for current cwd change, which will check current dir for trigger
        \\  files, like .nvmrc, .python-version etc (if you have installed supported configs). This
        \\  allows to dynamically change working version of config without user input (like fnm does)
        \\
        \\You can also interact with copper store via:
        \\
        \\  copper store dir|cache-dir|clear-cache|remove-cache|delete-cache
        \\
        \\Update copper with
        \\
        \\  copper update-self
        \\
    );
}
