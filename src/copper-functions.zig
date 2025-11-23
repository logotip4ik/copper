const std = @import("std");
const consts = @import("consts");

const Store = @import("./store.zig");
const common = @import("./config/common.zig");
const configs = @import("./config/configs.zig");

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

    req.sendBodiless() catch |err| {
        std.log.err("failed sending request {s}", .{@errorName(err)});
        return error.FailedWhileFetching;
    };

    const redirectBuf = alloc.alloc(u8, 8 * 1024) catch return error.FailedAllocatingDownloadBuffer;
    defer alloc.free(redirectBuf);

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

    const filename: []const u8 = tarballName orelse std.fmt.allocPrint(alloc, "{s}{s}", .{
        target.versionString,
        std.fs.path.basename(target.tarball),
    }) catch unreachable;
    errdefer alloc.free(filename);

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

    _ = reader.streamRemaining(&fileWriter.interface) catch |err| {
        std.log.err("failed writting reponse file with {s}", .{@errorName(err)});
        return error.FailedWhileFetching;
    };

    if (res.head.status != .ok) {
        return error.NotOkResponse;
    }

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
