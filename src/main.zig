const std = @import("std");
const builtin = @import("builtin");
const buildOptions = @import("build_options");
const consts = @import("consts");

const Store = @import("./store.zig");
const shell = @import("./shell.zig");
const utils = @import("./utils.zig");

const configs = @import("./config/configs.zig");
const common = @import("./config/common.zig");

const Command = enum {
    install,
    add,
    use,
    list,
    installed,
    uninstall,
    delete,
    remote,
    @"list-installed",
    @"list-remote",
    update,
    @"update-self",
    @"self-update",
    remove,
    shell,
    store,
    version,
    help,
};

const Configs = std.meta.DeclEnum(configs);

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
    ) orelse {
        const stdout = std.fs.File.stdout();
        defer stdout.close();

        const commands = comptime utils.availableCommands(Command);
        _ = stdout.write("available commands: " ++ commands ++ "\n") catch unreachable;

        return error.UnrecognisedCommand;
    };

    switch (command) {
        .version => {
            const stdout = std.fs.File.stdout();
            defer stdout.close();

            var w = stdout.writer(&.{});
            const writer = &w.interface;
            defer writer.flush() catch {};

            try writer.print("{f}\n", .{buildOptions.version});

            return;
        },
        .shell => {
            const shellType = std.meta.stringToEnum(
                shell.Shell,
                args.next() orelse return error.NoShellProvided,
            ) orelse {
                const stdout = std.fs.File.stdout();
                defer stdout.close();

                const shells = comptime utils.availableCommands(shell.Shell);
                _ = stdout.write("available shells: " ++ shells ++ "\n") catch unreachable;

                return error.UnsupportedShell;
            };

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

                const newPath = try std.fs.path.join(alloc, &[_][]const u8{ store.dirPath, item.*, Store.defaultUseFolderName, conf.binPath });

                alloc.free(item.*);

                item.* = newPath;
            }

            const out = std.fs.File.stdout();
            defer out.close();
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
            std.log.err("'list' is not specific enough, use 'list-remote' or 'list-installed' instead. 'remote' and 'installed' are aliases respectively", .{});
            return;
        },
        .update => {
            std.log.err("'update' is not specific enough, use 'update-self' or 'self-update' instead.", .{});
            return;
        },
        .@"self-update", .@"update-self" => {
            var p = std.Progress.start(.{ .root_name = "updating copper" });
            defer p.end();

            var store = try Store.init(alloc);
            defer store.deinit();

            try utils.updateSelf(alloc, &store, p);

            return;
        },
        .store => {
            const StoreCommands = enum {
                dir,
                @"cache-dir",
                @"clear-cache",
                @"remove-cache",
                @"delete-cache",
            };
            const subcommand: StoreCommands = std.meta.stringToEnum(
                StoreCommands,
                args.next() orelse return error.NoSubcommandProvided,
            ) orelse {
                const stdout = std.fs.File.stdout();
                defer stdout.close();

                const commands = comptime utils.availableCommands(StoreCommands);
                _ = stdout.write("available commands: " ++ commands ++ "\n") catch unreachable;

                return error.UnrecognisedSubcommand;
            };

            var store = try Store.init(alloc);
            defer store.deinit();

            switch (subcommand) {
                .dir => {
                    const stdout = std.fs.File.stdout();
                    defer stdout.close();

                    _ = stdout.write(store.dirPath) catch unreachable;
                    _ = stdout.write("\n") catch unreachable;
                },
                .@"cache-dir" => {
                    const stdout = std.fs.File.stdout();
                    defer stdout.close();

                    _ = stdout.write(store.tmpDirPath) catch unreachable;
                    _ = stdout.write("\n") catch unreachable;
                },
                .@"clear-cache", .@"remove-cache", .@"delete-cache" => {
                    store.clearTmpdir();
                },
            }
            return;
        },
        .help => {
            const stdout = std.fs.File.stdout();
            defer stdout.close();

            var buf: [2048]u8 = undefined;
            var w = stdout.writer(&buf);
            const writer = &w.interface;
            defer writer.flush() catch {};

            try writer.writeAll(
                \\copper - utility to handle installation of packages. Currently it can
                \\install only zig and node packages. Some examples of execution:
                \\
                \\  copper list-remote|remote node 22          - list all node 22.*.* versions which are available for installation on your machine. You can also omit `22` to see all available versions.
                \\  copper add|install node 22                 - fetch most recent node with matches 22.*.* version.
                \\  copper list-installed|installed node       - show installed node versions (you can also provide version to narrow log down)
                \\  copper remove|uninstall|delete node 22.*.* - remove node version 22.*.* if is installed.
                \\  copper use node 24                         - change default node version to 24.*.*
                \\
                \\To provide installed packages, copper needs to patch "$PATH" - do so call in your shell:
                \\
                \\  copper shell zsh|bash|fish
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

            return;
        },
        else => {},
    }

    const configName = args.next() orelse return error.NoConfigProvided;
    const conf = configs.configs.get(configName) orelse {
        const stdoutFile = std.fs.File.stdout();
        defer stdoutFile.close();

        var buf: [128]u8 = undefined;
        var w = stdoutFile.writer(&buf);
        const stdout = &w.interface;
        defer stdout.flush() catch {};

        stdout.print("available configs: ", .{}) catch unreachable;

        const available = comptime configs.configs.keys();
        stdout.print("{s}", .{available[0]}) catch unreachable;
        inline for (available[1..]) |conf| {
            stdout.print(", {s}", .{conf}) catch unreachable;
        }
        stdout.writeByte('\n') catch unreachable;

        return error.UnrecognisedConfig;
    };

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

            var store = try Store.init(alloc);
            defer store.deinit();

            downloadProgress = p.start("downloading target file", 0);
            const targetFile = try utils.getTargetFile(alloc, &client, &store, target.tarball);
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
            std.log.info("shasum matches expected", .{});

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

            var defaultVersionDir = store.getConfVersionDir(configName, Store.defaultUseFolderName);
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
                std.log.info("no {s}'s versions installed", .{configName});
                return;
            };
            defer confDir.close();

            std.log.info("installed {s} versions:", .{configName});

            const installed = try store.getConfInstallations(configName);
            defer {
                for (installed.items) |i| i.deinit();
                installed.deinit();
            }

            const stdoutFile = std.fs.File.stdout();
            defer stdoutFile.close();

            var buf: [2048]u8 = undefined;
            var stdoutWriter = stdoutFile.writer(&buf);
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

            const stdoutFile = std.fs.File.stdout();
            defer stdoutFile.close();

            var buf: [2048]u8 = undefined;
            var stdout = stdoutFile.writer(&buf);
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
        .remove, .uninstall, .delete => {
            const versionString = args.next() orelse return error.NoVersionProvided;

            var store = try Store.init(alloc);
            defer store.deinit();

            var versionDir = store.getConfVersionDir(configName, versionString) orelse {
                std.log.err("{s} - {s} not installed", .{ configName, versionString });
                return;
            };
            versionDir.close();

            var confDir = store.getConfDir(configName).?;
            defer confDir.close();
            try confDir.deleteTree(versionString);

            std.log.info("removed {s} - {s}", .{ configName, versionString });

            confDir.access(Store.defaultUseFolderName, .{
                .mode = .read_only,
            }) catch |err| switch (err) {
                error.FileNotFound => {
                    confDir.deleteTree(Store.defaultUseFolderName) catch return;

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
