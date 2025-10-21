const std = @import("std");
const builtin = @import("builtin");

const consts = @import("./consts.zig");
const configs = @import("./config/configs.zig");
const common = @import("./config/common.zig");
const shell = @import("./shell.zig");
const Store = @import("./store.zig");

const Command = enum {
    install,
    add,
    use,
    list,
    installed,
    uninstall,
    remote,
    @"list-installed",
    @"list-remote",
    remove,
    shell,
    store,
    help,
};

const Configs = std.meta.DeclEnum(configs);

pub fn getTargetFile(alloc: std.mem.Allocator, client: *std.http.Client, target: common.DownloadTarget) !std.fs.File {
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

    std.log.info("downloading to: {s}{c}{s}", .{ copperTmpDirname, std.fs.path.sep, filename });

    const res = client.fetch(.{
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
        .shell => {
            const shellType = std.meta.stringToEnum(
                shell.Shell,
                args.next() orelse return error.NoShellProvided,
            ) orelse return error.UnsupportedShell;

            var store = try Store.init(alloc);
            defer store.deinit();

            const installed = try store.getInstalledConfs();
            defer {
                for (installed.items) |item| alloc.free(item);
                installed.deinit();
            }

            for (installed.items) |*item| {
                const conf = configs.configs.get(item.*) orelse {
                    std.log.err("Unknown config: {s}", .{item.*});
                    return error.UnknownConfig;
                };

                const newPath = try std.fs.path.join(alloc, &[_][]const u8{ store.dirPath, item.*, conf.binPath });

                alloc.free(item.*);

                item.* = newPath;
            }

            const out = std.fs.File.stdout();
            var buf: [128]u8 = undefined;

            var outwriter = out.writer(&buf);

            try shell.writePathExtentions(
                &outwriter.interface,
                shellType,
                installed.items,
            );
            return;
        },
        .list => {
            std.log.err("`list` is not specific enough, use `list-remote` or `list-installed` instead. `remote` and `installed` are aliases respectively", .{});
            return;
        },
        .store => {
            const StoreCommands = enum {
                dir,
                @"clear-cache",
                @"remove-cache",
                @"delete-cache",
            };
            const subcommand: StoreCommands = std.meta.stringToEnum(
                StoreCommands,
                args.next() orelse return error.NoSubcommandProvided,
            ) orelse return error.UnrecognisedSubcommand;

            var store = try Store.init(alloc);
            defer store.deinit();

            switch (subcommand) {
                .dir => {
                    const stdout = std.fs.File.stdout();
                    var buf: [256]u8 = undefined;
                    const w = stdout.writer(&buf);

                    var writer = w.interface;
                    defer writer.flush() catch {};

                    writer.print("{s}\n", .{store.dirPath}) catch {};
                },
                .@"clear-cache", .@"remove-cache", .@"delete-cache" => {
                    store.clearTmpdir();
                },
            }
            return;
        },
        else => {},
    }

    const configName = args.next() orelse return error.NoConfigProvided;
    const conf = configs.configs.get(configName) orelse return error.UnrecognisedConfig;

    switch (command) {
        .add, .install => {
            var progressNameBuf: [32]u8 = undefined;
            var p = std.Progress.start(.{
                .root_name = std.fmt.bufPrint(&progressNameBuf, "resolving {s}", .{configName}) catch unreachable,
            });
            defer p.end();

            const looseVersion = args.next() orelse return error.NoVersionProvided;
            const allowedVersions = try common.parseUserVersion(looseVersion);

            var client = std.http.Client{ .allocator = alloc };
            defer client.deinit();

            var downloadProgress = p.start("downloading versions", 0);
            var versions = try conf.getDownloadTargets(alloc, &client, downloadProgress);
            downloadProgress.end();
            defer {
                for (versions.items) |item| item.deinit(alloc);
                versions.deinit(alloc);
            }

            var matching: ?*common.DownloadTarget = null;
            for (versions.items) |*item| {
                if (allowedVersions.includesVersion(item.version)) {
                    matching = item;
                    break;
                }
            }

            var target = matching orelse return error.NoMatchingTargetFound;

            std.log.info("resolved to {f}", .{target.version});

            downloadProgress = p.start("downloading target file", 0);
            const targetFile = try getTargetFile(alloc, &client, target.*);
            defer targetFile.close();
            downloadProgress.end();

            if (target.shasum) |_| {} else {
                var fetchingShasumProgress = p.start("fetching shasum", 0);
                defer fetchingShasumProgress.end();

                target.shasum = conf.getTarballShasum(
                    alloc,
                    &client,
                    target.*,
                    fetchingShasumProgress,
                ) catch return error.FailedFetchingShasum;
            }

            const shasum = target.shasum.?;

            var verifyingShasumProgress = p.start("verifying shasum", 0);
            if (!try Store.verifyShasum(alloc, &targetFile, shasum)) {
                try targetFile.setEndPos(0);
                return error.IncorrectShasum;
            }
            verifyingShasumProgress.end();
            std.log.info("successfully verified shasum", .{});

            var store = try Store.init(alloc);
            defer store.deinit();

            var existingDir = store.getConfVersionDir(configName, target.versionString);
            if (existingDir) |*dir| {
                dir.close();
                std.log.info("{s} - {f} already installed", .{ configName, target.version });
                return;
            }

            const tmpDir = try store.prepareTmpDirForDecompression(configName, target.version);

            var decompressProgress = p.start("decompressing", 0);
            var outDir = try conf.decompressTargetFile(alloc, targetFile, tmpDir);
            defer outDir.close();
            decompressProgress.end();

            const savedDirPath = try store.saveOutDir(outDir, configName, target.versionString);
            defer alloc.free(savedDirPath);

            var defaultVersionDir = store.getConfVersionDir(configName, "default");
            if (defaultVersionDir) |*dir| {
                dir.close();
                return;
            }

            try store.useAsDefault(configName, target.versionString);
        },
        .installed, .@"list-installed" => {
            var store = try Store.init(alloc);
            defer store.deinit();

            var confDir = store.getConfDir(configName) orelse {
                std.log.err("no {s}'s versions installed", .{configName});
                return;
            };
            defer confDir.close();

            std.log.info("installed {s} versions:", .{configName});

            const installed = try store.getConfInstallations(configName);
            defer {
                for (installed.items) |i| i.deinit();
                installed.deinit();
            }

            var buf: [2048]u8 = undefined;
            var stdoutWriter = std.fs.File.stdout().writer(&buf);
            var stdout = &stdoutWriter.interface;
            defer stdout.flush() catch {};

            const range: ?std.SemanticVersion.Range = blk: {
                const looseVersion = args.next() orelse break :blk null;
                break :blk try common.parseUserVersion(looseVersion);
            };

            for (installed.items) |item| {
                const matchesVersionRange = if (range) |r| r.includesVersion(item.version) else true;
                if (!matchesVersionRange) {
                    continue;
                }

                if (item.default) {
                    stdout.print("{s} - default\n", .{item.versionString}) catch unreachable;
                } else {
                    stdout.print("{s}\n", .{item.versionString}) catch unreachable;
                }
            }
        },
        .remote, .@"list-remote" => {
            var progressNameBuf: [32]u8 = undefined;
            var p = std.Progress.start(.{
                .root_name = std.fmt.bufPrint(&progressNameBuf, "resolving {s}", .{configName}) catch unreachable,
            });

            var client = std.http.Client{ .allocator = alloc };
            defer client.deinit();

            var downloadProgress = p.start("downloading versions", 0);
            var versions = try conf.getDownloadTargets(alloc, &client, downloadProgress);
            defer {
                for (versions.items) |item| item.deinit(alloc);
                versions.deinit(alloc);
            }
            downloadProgress.end();
            p.end();

            var buf: [2048]u8 = undefined;
            var stdout = std.fs.File.stdout().writer(&buf);
            const writer = &stdout.interface;
            defer writer.flush() catch {};

            const range: ?std.SemanticVersion.Range = blk: {
                const looseVersion = args.next() orelse break :blk null;
                break :blk try common.parseUserVersion(looseVersion);
            };

            for (versions.items) |item| {
                const matchesVersionRange = if (range) |r| r.includesVersion(item.version) else true;
                if (matchesVersionRange) {
                    try writer.print("{f}\n", .{item.version});
                }
            }
        },
        .use => {
            const looseVersion = args.next() orelse return error.NoVersionProvided;
            const range = try common.parseUserVersion(looseVersion);

            var store = try Store.init(alloc);
            defer store.deinit();

            store.useAsDefaultWithRange(configName, range) catch |err| switch (err) {
                error.NoMatchingVersionFound => std.log.err(
                    "no installed version matching {s} for {s} was found",
                    .{ looseVersion, configName },
                ),
                else => return err,
            };
        },
        .remove, .uninstall => {
            const versionString = args.next() orelse return error.NoVersionProvided;

            var store = try Store.init(alloc);
            defer store.deinit();

            var versionDir = store.getConfVersionDir(configName, versionString) orelse {
                std.log.err("{s} - {s} not installed", .{ configName, versionString });
                return;
            };
            versionDir.close();

            const confDir = store.getConfDir(configName).?;
            try confDir.deleteTree(versionString);

            std.log.info("removed {s} - {s}", .{ configName, versionString });

            confDir.access("default", .{
                .mode = .read_only,
            }) catch |err| switch (err) {
                error.FileNotFound => {
                    confDir.deleteTree("default") catch return;

                    std.log.info("removed default symlink for {s}", .{configName});

                    var nextVersionDir = common.openFirstDirWithLog(confDir, std.log, "") catch null;
                    if (nextVersionDir) |*dir| {
                        defer dir.close();

                        var nextVersionDirPathBuf: [std.fs.max_path_bytes]u8 = undefined;
                        const nextVersionDirPath = try dir.realpath(".", &nextVersionDirPathBuf);

                        const nextVersionString = std.fs.path.basename(nextVersionDirPath);

                        store.useAsDefault(configName, nextVersionString) catch return;
                    }
                },
                else => {},
            };
        },
        else => unreachable,
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
    std.testing.refAllDecls(shell);
}
