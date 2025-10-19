const std = @import("std");
const builtin = @import("builtin");

const consts = @import("./consts.zig");
const configs = @import("./config/configs.zig");
const common = @import("./config/common.zig");
const store = @import("./store.zig");

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
    const tmpDirname = store.getTmpDirname(alloc);
    defer alloc.free(tmpDirname);

    var dirBuf: [std.fs.max_path_bytes]u8 = undefined;
    const copperTmpDirname = std.fmt.bufPrint(&dirBuf, "{s}{s}", .{
        tmpDirname,
        consts.EXE_NAME,
    }) catch return error.TmpDirTooLong;

    var tmpDir = std.fs.openDirAbsolute(copperTmpDirname, .{}) catch |err| blk: switch (err) {
        error.FileNotFound => {
            std.fs.makeDirAbsolute(copperTmpDirname) catch return error.UnableToCreateTmpDir;
            break :blk std.fs.openDirAbsolute(copperTmpDirname, .{}) catch return error.UnableToOpenTmpDir;
        },
        else => return error.UnableToOpenTmpDir,
    };
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

    var fileWriter = downloadFile.writerStreaming(buffer);

    var http = std.http.Client{ .allocator = alloc };
    defer http.deinit();

    std.log.info("downloading to: {s}\n", .{copperTmpDirname});

    const res = http.fetch(.{
        .location = .{ .url = target.tarball },
        .headers = .{ .user_agent = .{ .override = consts.EXE_NAME } },
        .keep_alive = false,
        .response_writer = &fileWriter.interface,
    }) catch return error.FailedWhileFetching;

    try fileWriter.interface.flush();

    if (res.status != .ok) {
        return error.NonOkResponse;
    }

    return downloadFile;
}

pub fn handleAdd(alloc: std.mem.Allocator, progress: std.Progress.Node, itemName: []const u8, target: common.DownloadTarget) !void {
    var downloadProgress = progress.start("downloading tarfile", 0);
    const file = try downloadTar(alloc, target);
    defer file.close();
    downloadProgress.end();

    var verifyingShasumProgress = progress.start("verifying shasum", 0);
    var sha256: std.crypto.hash.sha2.Sha256 = .init(.{});

    const shaFileBuffer = try alloc.alloc(u8, 16 * 1024 * 1024);
    defer alloc.free(shaFileBuffer);

    while (true) {
        const read = try file.read(shaFileBuffer);
        if (read == 0) break;

        sha256.update(shaFileBuffer[0..read]);
    }

    const shasum = std.fmt.bytesToHex(sha256.finalResult(), .lower);

    if (!std.mem.eql(u8, &shasum, target.shasum)) {
        try file.setEndPos(0);
        return error.ShaNotMathcing;
    }

    verifyingShasumProgress.end();

    std.debug.print("{s} {f} {s} shasum: {s} size: {s}\n", .{
        itemName,
        target.version,
        target.tarball,
        target.shasum,
        target.size,
    });
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
