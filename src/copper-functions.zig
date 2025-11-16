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
) !std.fs.File {
    const tarballName = std.fs.path.basename(target.tarball);

    var nameBuf: [std.fs.max_name_bytes]u8 = undefined;
    const filename = std.fmt.bufPrint(&nameBuf, "{s}{s}", .{ target.versionString, tarballName }) catch unreachable;

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
        return downloadFile;
    }

    try downloadFile.seekTo(0);

    const buffer = alloc.alloc(u8, 32 * 1024 * 1024) catch return error.FailedAllocatingDownloadBuffer;
    defer alloc.free(buffer);

    var fileWriter = downloadFile.writer(buffer);
    defer fileWriter.interface.flush() catch unreachable;

    std.log.info("downloading to: {f}", .{
        std.fs.path.fmtJoin(&[_][]const u8{
            store.tmpDirPath,
            filename,
        }),
    });

    const res = client.fetch(.{
        .location = .{ .url = target.tarball },
        .headers = consts.DEFAULT_HEADERS,
        .keep_alive = false,
        .response_writer = &fileWriter.interface,
    }) catch return error.FailedWhileFetching;

    if (res.status != .ok) {
        return error.NotOkResponse;
    }

    return downloadFile;
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
        @branchHint(.unlikely);
        std.log.err("Faield fetching download targets for {s} with {s}", .{configName, @errorName(err)});
        return;
    };
    defer {
        for (remote.items) |item| item.deinit(alloc);
        remote.deinit(alloc);
    }

    const local = store.getConfInstallations(configName) catch |err| {
        @branchHint(.unlikely);
        std.log.err("Faield retriving installed targets for {s} with {s}", .{configName, @errorName(err)});
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
