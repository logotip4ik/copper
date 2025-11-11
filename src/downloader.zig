const std = @import("std");
const consts = @import("consts");

const Store = @import("./store.zig");
const common = @import("./config/common.zig");

pub fn getTargetFile(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    store: *const Store,
    target: *const common.DownloadTarget,
) !std.fs.File {
    const tarballName = std.fs.path.basename(target.tarball);

    var nameBuf: [std.fs.max_name_bytes]u8 = undefined;
    const filename = std.fmt.bufPrint(&nameBuf, "{s}{s}", .{target.versionString, tarballName}) catch unreachable;

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
