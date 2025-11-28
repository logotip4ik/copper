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

pub fn resolveConfig(configName: []const u8) !common.ConfInterface {
    return configs.configs.get(configName) orelse {
        const stdoutFile = std.fs.File.stdout();
        defer stdoutFile.close();

        var buf: [128]u8 = undefined;
        var w = stdoutFile.writer(&buf);
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

        return error.UnrecognisedConfig;
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

        std.log.err("unrecognised compression for {s}", .{filepath});
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
        .{ .headers = consts.DEFAULT_HEADERS },
    ) catch |err| {
        std.log.err("failed creating request {s}", .{@errorName(err)});
        return error.CreatingRequest;
    };
    defer req.deinit();

    std.log.debug("sending request {s}", .{target.tarball});

    req.sendBodiless() catch |err| {
        std.log.err("failed sending request {s}", .{@errorName(err)});
        return error.FailedWhileFetching;
    };

    const redirectBuf = alloc.alloc(u8, 8 * 1024) catch return error.FailedAllocatingDownloadBuffer;
    defer alloc.free(redirectBuf);

    std.log.debug("receiving head...", .{});
    var res = req.receiveHead(redirectBuf) catch |err| {
        std.log.err("failed sending request {s}", .{@errorName(err)});
        return error.FailedWhileFetching;
    };

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
            if (char == '.') versionStringWithoutDots[i] = '_'
            else versionStringWithoutDots[i] = char;
        }

        break :blk std.fmt.allocPrint(alloc, "{s}{s}", .{
            versionStringWithoutDots,
            std.fs.path.basename(target.tarball),
        }) catch unreachable;
    };
    errdefer alloc.free(filename);

    std.log.debug("resolved filename to: {s}", .{filename});

    var hasCached = true;
    var downloadFile = store.tmpDir.openFile(filename, .{ .mode = .read_write }) catch |err| blk: switch (err) {
        error.FileNotFound => {
            hasCached = false;

            const file = store.tmpDir.createFile(filename, .{}) catch return error.UnableToOpenDownloadFile;
            file.close();

            break :blk store.tmpDir.openFile(filename, .{ .mode = .read_write }) catch return error.UnableToOpenDownloadFile;
        },
        else => return error.UnableToOpenDownloadFile,
    };
    errdefer downloadFile.close();

    std.log.debug("opened download file", .{});

    if (hasCached and try downloadFile.getEndPos() != 0) {
        std.log.info("using cached file from {f}", .{
            std.fs.path.fmtJoin(&[_][]const u8{
                store.tmpDirPath,
                filename,
            }),
        });
        return .{ filename, downloadFile };
    }

    downloadFile.seekTo(0) catch {};
    std.log.debug("reseted download file size", .{});

    var fileWriter = downloadFile.writer(&.{});
    defer fileWriter.interface.flush() catch unreachable;

    const decompress_buffer: []u8 = switch (res.head.content_encoding) {
        .identity => &.{},
        .zstd => try alloc.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try alloc.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer alloc.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = res.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    std.log.info("downloading to: {f}", .{
        std.fs.path.fmtJoin(&[_][]const u8{
            store.tmpDirPath,
            filename,
        }),
    });

    std.log.debug("decompressing downloaded stream...", .{});
    _ = reader.streamRemaining(&fileWriter.interface) catch |err| {
        std.log.err("failed writting reponse file with {s}", .{@errorName(err)});
        return error.FailedWhileFetching;
    };

    if (res.head.status != .ok) {
        return error.NotOkResponse;
    }

    std.log.debug("successfully downloaded target file {s}", .{filename});

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
        std.log.warn("{s} config is not supported", .{configName});
        return;
    };

    var remote = conf.getDownloadTargets(alloc, client, confP) catch |err| {
        std.log.err("Faield fetching download targets for {s} with {s}", .{ configName, @errorName(err) });
        return;
    };
    defer {
        for (remote.items) |item| item.deinit(alloc);
        remote.deinit(alloc);
    }

    const local = store.getConfInstallations(configName) catch |err| {
        @branchHint(.unlikely);
        std.log.err("Faield retriving installed targets for {s} with {s}", .{ configName, @errorName(err) });
        return;
    };
    defer {
        for (local.items) |item| item.deinit();
        local.deinit();
    }

    const latestLocal = local.items[0];

    for (remote.items) |item| {
        if (latestLocal.version.order(item.version) == .lt) {
            // clear previous line (could be progress...)
            // writer.print("\x1B[2K{s} {f} < {f}\n", .{
            writer.print("\r\n{s} {f} < {f}", .{
                configName,
                latestLocal.version,
                item.version,
            }) catch {};
        }
    }
}
