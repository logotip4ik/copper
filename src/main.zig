const std = @import("std");
const builtin = @import("builtin");

const consts = @import("./consts.zig");
const configs = @import("./config/configs.zig");
const common = @import("./config/common.zig");
const Store = @import("./store.zig");

const Command = enum {
    alias,
    add,
    use,
    list,
    installed,
    @"list-installed",
    remove,
    help,
};

const Configs = std.meta.DeclEnum(configs);

pub fn downloadTar(alloc: std.mem.Allocator, target: common.DownloadTarget) !std.fs.File {
    const tmpDirname = Store.getTmpDirname(alloc);
    defer alloc.free(tmpDirname);

    var dirBuf: [std.fs.max_path_bytes]u8 = undefined;
    const copperTmpDirname = std.fmt.bufPrint(&dirBuf, "{s}{s}", .{
        tmpDirname,
        consts.EXE_NAME,
    }) catch return error.TmpDirTooLong;

    var tmpDir = try Store.openOrMakeDir(copperTmpDirname, .{});
    defer tmpDir.close();

    const filename = std.fs.path.basename(target.tarball);

    var hasCached = true;
    var downloadFile = tmpDir.openFile(filename, .{ .mode = .read_write }) catch |err| blk: switch (err) {
        error.FileNotFound => {
            hasCached = false;

            const file = tmpDir.createFile(filename, .{}) catch return error.UnableToOpenDownloadFile;
            file.close();

            break :blk tmpDir.openFile(filename, .{ .mode = .read_write }) catch return error.UnableToOpenDownloadFile;
        },
        else => return error.UnableToOpenDownloadFile,
    };
    errdefer downloadFile.close();

    if (hasCached and try downloadFile.getEndPos() != 0) {
        std.log.info("using cached file from {s}{c}{s}", .{
            copperTmpDirname,
            std.fs.path.sep,
            filename,
        });
        return downloadFile;
    }

    try downloadFile.seekTo(0);

    const buffer = alloc.alloc(u8, 32 * 1024 * 1024) catch return error.FailedAllocatingDownloadBuffer;
    defer alloc.free(buffer);

    var fileWriter = downloadFile.writer(buffer);
    defer fileWriter.interface.flush() catch unreachable;

    var http = std.http.Client{ .allocator = alloc };
    defer http.deinit();

    std.log.info("downloading to: {s}{c}{s}", .{ copperTmpDirname, std.fs.path.sep, filename });

    const res = http.fetch(.{
        .location = .{ .url = target.tarball },
        .headers = .{ .user_agent = .{ .override = consts.EXE_NAME } },
        .keep_alive = false,
        .response_writer = &fileWriter.interface,
    }) catch return error.FailedWhileFetching;

    if (res.status != .ok) {
        return error.NonOkResponse;
    }

    return downloadFile;
}

pub fn handleAdd(alloc: std.mem.Allocator, progress: std.Progress.Node, conf: []const u8, target: common.DownloadTarget) !void {
    var downloadProgress = progress.start("downloading tarfile", 0);
    const targetFile = try downloadTar(alloc, target);
    defer targetFile.close();
    downloadProgress.end();

    {
        var verifyingShasumProgress = progress.start("verifying shasum", 0);
        const shaBuf = try alloc.alloc(u8, 16 * 1024 * 1024);
        defer alloc.free(shaBuf);

        const shasum = try Store.computeShasum(&targetFile, shaBuf);

        if (!std.mem.eql(u8, &shasum, target.shasum)) {
            try targetFile.setEndPos(0);
            return error.ShaNotMatching;
        }

        verifyingShasumProgress.end();
    }

    var store = try Store.init(alloc);
    defer store.deinit();

    var decompressProgress = progress.start("Decompressing", 0);
    try store.saveTargetFile(conf, target, targetFile);
    decompressProgress.end();

    std.debug.print("{s} {f} {s} shasum: {s} size: {s}\n", .{
        conf,
        target.version,
        target.tarball,
        target.shasum,
        target.size,
    });
}

test "s" {
    const testing = std.testing;

    const alloc = testing.allocator;
    const in = try std.fs.openFileAbsolute("/var/folders/xd/11t8qcts453blpnstzrvbz0m0000gn/T/copper/zig-aarch64-macos-0.15.2.tar.xz", .{ .mode = .read_write });
    defer in.close();

    const out = try std.fs.cwd().openFile("testing.help", .{ .mode = .read_write });
    defer out.close();

    const inreaderBuf = try alloc.alloc(u8, 16 * 1024 * 1024);
    defer alloc.free(inreaderBuf);

    const inreader = in.reader(inreaderBuf);
    var inreaderInterface = inreader.interface;

    const outwriterBuf = try alloc.alloc(u8, 16 * 1024 * 1024);
    defer alloc.free(outwriterBuf);

    var outwriter = out.writer(outwriterBuf);
    defer outwriter.interface.flush() catch unreachable;

    const decompressBuf = try alloc.alloc(u8, 16 * 1024 * 1024);
    defer alloc.free(decompressBuf);

    var decompress = try std.compress.xz.decompress(alloc, inreaderInterface.adaptToOldInterface());
    var reader = decompress.in_reader.adaptToNewApi(&.{}).new_interface;
    const n = try reader.streamRemaining(&outwriter.interface);
    std.debug.print("{d}\n", .{n});
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    const alloc = debug.allocator();
    defer _ = debug.deinit();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    // skip executable
    _ = args.next() orelse return error.NoExecutableArg;

    const command = std.meta.stringToEnum(
        Command,
        args.next() orelse "help",
    ) orelse return error.UnrecognisedCommand;

    switch (command) {
        .help => {
            std.debug.print("Help menu\n", .{});
            return;
        },
        .installed, .@"list-installed" => {
            std.debug.print("installed\n", .{});
            return;
        },
        .alias => {
            std.debug.print("installed\n", .{});
            return;
        },
        else => {},
    }

    const config = std.meta.stringToEnum(
        Configs,
        args.next() orelse return error.NoConfig,
    ) orelse return error.UnrecognisedConfig;

    var progressNameBuf: [32]u8 = undefined;
    var p = std.Progress.start(.{
        .root_name = std.fmt.bufPrint(&progressNameBuf, "resolving {s}", .{@tagName(config)}) catch unreachable,
    });
    defer p.end();

    inline for (@typeInfo(configs).@"struct".decls) |decl| blk: {
        if (std.mem.eql(u8, @tagName(config), decl.name)) {
            var conf = @field(configs, decl.name).init(alloc, p);
            defer conf.deinit();

            var runner = &conf.runner;

            switch (command) {
                .add => {
                    const downloadTarget: common.DownloadTarget = runner.add(runner, &args) orelse break :blk;
                    defer downloadTarget.deinit(alloc);

                    const storeProgress = p.start("adding to store", 0);
                    defer storeProgress.end();

                    try handleAdd(alloc, storeProgress, decl.name, downloadTarget);
                },
                .use => runner.use(runner),
                .list => runner.list(runner),
                .remove => runner.remove(runner),
                else => unreachable,
            }
        }
    }
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}

test {
    std.testing.refAllDecls(common);
}
