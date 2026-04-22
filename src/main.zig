const std = @import("std");
const builtin = @import("builtin");
const buildOptions = @import("build_options");
const consts = @import("consts");

const Store = @import("./store.zig");
const shell = @import("./shell.zig");
const utils = @import("./utils.zig");
const mem = @import("./mem.zig");

const configs = @import("./config/configs.zig");
const CopperConfig = @import("./config/copper.zig");

const Command = enum {
    install,
    add,
    use,
    ls,
    list,
    outdated,
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
    @"file-hook",
    store,
    version,
    confs,
    configs,
    help,
};

const StoreCommands = enum {
    dir,
    installations,
    @"installations-dir",
    @"cache-dir",
    @"clean-cache",
    @"clear-cache",
    @"remove-cache",
    @"delete-cache",
    @"prune-aliases",
    @"prune-symlinks",
};

var stdoutBuf: [2048]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
    const heap = comptime mem.getHeap();
    const alloc: std.mem.Allocator = heap.allocator();
    defer _ = heap.deinit();

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    const io = threaded.io();

    var stdoutWriter = std.Io.File.stdout().writer(io, &stdoutBuf);
    const stdout = &stdoutWriter.interface;
    defer stdout.flush() catch {};

    var args = try init.args.iterateAllocator(alloc);
    defer args.deinit();

    // skip executable
    _ = args.next() orelse return error.NoExecutableArg;

    const commandArg = args.next() orelse "help";
    const command = std.meta.stringToEnum(Command, commandArg) orelse {
        stdout.print("{s} is not a command.\nRun `{s} help` to see available commands\n", .{ commandArg, consts.EXE_NAME }) catch {};
        return;
    };

    switch (command) {
        .version => try utils.printVersion(stdout),
        .help => try utils.printHelp(stdout),
        .shell => {
            const shellsString = comptime utils.concatComptime(std.meta.fieldNames(shell.Shell), ", ");
            const shellArg = args.next() orelse {
                stdout.print("expected shell argument is missing. Please provide one of shell arguments: {s}\n", .{shellsString}) catch {};
                return;
            };

            const shellType = std.meta.stringToEnum(shell.Shell, shellArg) orelse {
                stdout.print("{s} is not as a shell.\nChoose one of available shells: {s}\n", .{ shellArg, shellsString }) catch {};
                return;
            };

            var store = try Store.init(alloc, io, &init.environ);
            defer store.deinit();

            var configsWithFileHooks: std.array_list.Aligned(struct { []const u8, []const []const u8 }, null) = .empty;
            defer configsWithFileHooks.deinit(alloc);

            var installedConfigs = try store.getInstalledConfs(alloc);
            defer {
                for (installedConfigs.items) |conf| alloc.free(conf);
                installedConfigs.deinit(alloc);
            }

            for (installedConfigs.items) |configName| {
                const conf = configs.configs.get(configName) orelse continue;

                if (conf.fileHooks) |hooks| {
                    try configsWithFileHooks.append(alloc, .{ conf.name, hooks });
                }
            }

            try shell.addPathExtention(
                stdout,
                shellType,
                store.aliasesDirPath,
            );

            if (builtin.target.os.tag != .windows) {
                try shell.addManpathExtention(
                    stdout,
                    shellType,
                    store.manDirPath,
                );
            }

            try shell.addUseOnPathChange(
                stdout,
                shellType,
                configsWithFileHooks.items,
            );

            const commandsWithoutConf = &[_][]const u8{
                "update-self",
                "self-update",
                "shell",
                "store",
                "version",
                "confs",
                "configs",
                "help",
            };

            try shell.addAutocomplete(
                stdout,
                shellType,
                std.meta.fieldNames(Command),
                configs.configs.keys(),
                std.meta.fieldNames(StoreCommands),
                commandsWithoutConf,
            );
        },
        .@"file-hook" => {
            var store = try Store.init(alloc, io, &init.environ);
            defer store.deinit();

            const cwd = std.Io.Dir.cwd();

            while (args.next()) |confName| {
                const conf = configs.configs.get(confName) orelse {
                    std.log.warn("{s} is not recognized as config. skipping...", .{confName});
                    continue;
                };

                const fileHooks = conf.fileHooks orelse continue;
                const resolveVersionFromFile = conf.resolveVersionFromFile orelse continue;

                var versionString: []const u8 = undefined;
                var fileHook: []const u8 = undefined;
                for (fileHooks) |filename| {
                    const file = cwd.openFile(io, filename, .{}) catch continue;
                    defer file.close(io);

                    versionString = resolveVersionFromFile(alloc, io, filename, file) orelse continue;
                    fileHook = filename;

                    break;
                } else continue;
                defer alloc.free(versionString);

                const range = utils.parseUserVersion(versionString) catch continue;

                const choosenVersion = store.useAsDefaultWithRange(conf.name, range, conf.binPath) catch |err| switch (err) {
                    error.NoMatchingVersionFound, error.NoConfDir => {
                        try stdout.print("{s} {s} (required by {s}) is not installed. Run `{s} add {s} {s}` to install\n", .{
                            conf.name,
                            versionString,
                            fileHook,
                            consts.EXE_NAME,
                            conf.name,
                            versionString,
                        });
                        continue;
                    },
                    else => continue,
                } orelse continue;
                defer alloc.free(choosenVersion);

                if (conf.manPages) |pages| store.linkManPages(conf.name, choosenVersion, pages) catch {
                    @branchHint(.unlikely);
                    stdout.print("failed linking man pages for {s}\n", .{conf.name}) catch {};
                };

                stdout.print("using {s} {s}\n", .{ conf.name, choosenVersion }) catch continue;
            }
        },
        .@"self-update", .@"update-self" => {
            var p = std.Progress.start(io, .{ .root_name = "updating copper" });
            defer p.end();

            var store = try Store.init(alloc, io, &init.environ);
            defer store.deinit();

            var client = std.http.Client{ .io = io, .allocator = alloc };
            defer client.deinit();

            const currentVersion = buildOptions.version;
            const target = CopperConfig.latestVersion(alloc, io, &client, p) catch |err| {
                std.log.err("failed fetching versions with {s}", .{@errorName(err)});
                return;
            };
            defer target.deinit(alloc);

            if (target.version.order(currentVersion) != .gt) {
                std.log.info("already using latest available {f} version", .{currentVersion});
                return;
            }

            std.log.info("newer version {f} is available", .{target.version});

            const targetFilename, const targetFile = try utils.getTargetFile(alloc, io, &client, &store, &target);
            defer alloc.free(targetFilename);
            defer targetFile.close(io);

            const tmpDir = try store.prepareTmpDirForDecompression(consts.EXE_NAME, target.version);

            const compression = utils.guessCompression(targetFilename) orelse return;

            const file = try CopperConfig.decompressCopper(alloc, io, compression, targetFile, tmpDir);
            defer file.close(io);

            var selfPathBuf: [std.fs.max_path_bytes]u8 = undefined;
            const selfPathLen = try std.process.executablePath(io, &selfPathBuf);
            const selfPath = selfPathBuf[0..selfPathLen];

            var filePathBuf: [std.fs.max_path_bytes]u8 = undefined;
            const filePathLen = try file.realPathFile(io, ".", &filePathBuf);
            const filePath = filePathBuf[0..filePathLen];

            try std.Io.Dir.deleteFileAbsolute(io, selfPath);
            try std.Io.Dir.renameAbsolute(filePath, selfPath, io);

            std.log.info("updated {s} to {f}", .{ consts.EXE_NAME, target.version });
        },
        .store => {
            const storeSubcommands = comptime utils.concatComptime(std.meta.fieldNames(StoreCommands), ", ");
            const storeSubcommandArg = args.next() orelse {
                std.log.info("expected subcommand argument is missing. Please provide one of arguments: {s}", .{storeSubcommands});
                return;
            };

            const subcommand: StoreCommands = std.meta.stringToEnum(StoreCommands, storeSubcommandArg) orelse {
                stdout.print("{s} is not as a store subcommand.\nRun `{s} help` to see available commands\n", .{
                    storeSubcommandArg,
                    storeSubcommands,
                }) catch {};
                return;
            };

            var store = try Store.init(alloc, io, &init.environ);
            defer store.deinit();

            switch (subcommand) {
                .dir => {
                    _ = stdout.write(store.rootPath) catch unreachable;
                    _ = stdout.write("\n") catch unreachable;
                },
                .installations, .@"installations-dir" => {
                    _ = stdout.write(store.installationsDirPath) catch unreachable;
                    _ = stdout.write("\n") catch unreachable;
                },
                .@"cache-dir" => {
                    _ = stdout.write(store.tmpDirPath) catch unreachable;
                    _ = stdout.write("\n") catch unreachable;
                },
                .@"clear-cache", .@"remove-cache", .@"delete-cache", .@"clean-cache" => {
                    store.clearTmpdir();
                },
                .@"prune-aliases", .@"prune-symlinks" => {
                    try store.removeDeadSymlinks();
                },
            }
        },
        .configs, .confs => {
            stdout.print("supported configs:\n", .{}) catch unreachable;

            for (configs.configs.keys()) |conf| {
                stdout.print("- {s}\n", .{conf}) catch unreachable;
            }
        },
        .outdated => {
            const filter = args.next();

            const p = std.Progress.start(io, .{ .root_name = "checking outdated" });
            defer p.end();

            defer {
                _ = std.debug.lockStderr(&.{});
                defer std.debug.unlockStderr();

                stdout.flush() catch {};
            }

            var store = try Store.init(alloc, io, &init.environ);
            defer store.deinit();

            var installed = try store.getInstalledConfs(alloc);
            defer {
                for (installed.items) |item| alloc.free(item);
                defer installed.deinit(alloc);
            }

            if (installed.items.len == 0) {
                return;
            }

            p.setEstimatedTotalItems(installed.items.len);

            var client = std.http.Client{ .io = io, .allocator = alloc };
            defer client.deinit();

            var group: std.Io.Group = .init;
            errdefer group.cancel(io);

            for (installed.items) |configName| {
                if (filter) |f| if (!std.mem.eql(u8, configName, f)) {
                    continue;
                };

                const conf = configs.configs.get(configName) orelse {
                    @branchHint(.cold);
                    std.log.warn("{s} config is not supported", .{configName});
                    return;
                };

                group.async(io, utils.printOutdated, .{ alloc, io, conf, &client, p, &store, stdout });
            }

            group.await(io) catch |err| {
                std.log.err("failed waiting for outdated with {t}", .{err});
            };
        },
        .add, .install => {
            const configName = args.next() orelse {
                std.log.info("please provide config to install", .{});
                return;
            };
            const conf = utils.resolveConfig(configName, stdout) orelse return;

            var progress = std.Progress.start(io, .{ .root_name = "installing", .estimated_total_items = 3 });
            defer progress.end();

            var client = std.http.Client{ .io = io, .allocator = alloc };
            defer client.deinit();

            const targetVersion: utils.TargetVersion = if (args.next()) |looseVersion| switch (conf.type) {
                .Runtime => .{ .loose = looseVersion },
                .Package => .{ .latest = true },
            } else .{ .latest = true };

            var store = try Store.init(alloc, io, &init.environ);
            defer store.deinit();

            const target, var saveDir = utils.fetchAndDecompress(alloc, io, &init.environ, conf, targetVersion, .{
                .client = &client,
                .output = stdout,
                .progress = progress,
                .store = &store,
            }) catch |err| switch (err) {
                error.UnknownCompression, error.Aborted => return,
                error.TargetAlreadyInstalled => {
                    std.log.info("latest version already installed", .{});
                    return;
                },
                else => return err,
            };
            defer target.deinit(alloc);
            defer saveDir.close(io);

            const saveDirPath = store.generateSaveOutDirPath(alloc, conf.name, target.versionString);
            defer alloc.free(saveDirPath);

            try store.saveOutDir(saveDir, saveDirPath);

            store.useAsDefault(conf.name, target.versionString, conf.binPath) catch |err| switch (err) {
                error.PathAlreadyExists => return,
                else => {
                    std.log.err("failed creating symlinks for {s} {f} with {s}", .{
                        conf.name,
                        target.version,
                        @errorName(err),
                    });
                    return;
                },
            };
            if (conf.manPages) |manPages| {
                store.linkManPages(conf.name, target.versionString, manPages) catch |err| {
                    std.log.warn("failed symlinking manpages for {s} with {s}", .{
                        conf.name,
                        @errorName(err),
                    });
                };
            }

            std.log.info("using {f} as default for {s}", .{ target.version, conf.name });
        },
        .update => {
            const configName = args.next() orelse {
                std.log.info("please provide config to update", .{});
                return;
            };
            const conf = utils.resolveConfig(configName, stdout) orelse return;

            var store = try Store.init(alloc, io, &init.environ);
            defer store.deinit();

            var installed = try store.getConfInstallations(alloc, conf.name);
            defer {
                for (installed.items) |item| item.deinit();
                installed.deinit(alloc);
            }

            const defaultInstall = blk: {
                for (installed.items) |item| {
                    if (item.default) {
                        break :blk item;
                    }
                } else {
                    std.log.info("no default installation found for {s}. Maybe symlinks are broken...", .{conf.name});
                    return;
                }
            };

            var client = std.http.Client{ .io = io, .allocator = alloc };
            defer client.deinit();

            const targetVersion: utils.TargetVersion = if (args.next()) |looseVersion|
                switch (conf.type) {
                    .Runtime => .{ .loose = looseVersion },
                    .Package => .{ .latest = true },
                }
            else
                .{ .latest = true };

            // const target = blk: {
            //     for (versions.items) |*item| {
            //         if (defaultInstall.version.order(item.version) == .lt) {
            //             break :blk item;
            //         }
            //     } else {
            //         std.log.info("latest version is alredy installed", .{});
            //         return;
            //     }
            // };

            var progressNameBuf: [128]u8 = undefined;
            var progress = std.Progress.start(io, .{
                .root_name = std.fmt.bufPrint(&progressNameBuf, "updating {s}", .{conf.name}) catch unreachable,
                .estimated_total_items = 3,
            });
            defer progress.end();

            const target, var saveDir = utils.fetchAndDecompress(alloc, io, &init.environ, conf, targetVersion, .{
                .client = &client,
                .output = stdout,
                .progress = progress,
                .store = &store,
            }) catch |err| switch (err) {
                error.UnknownCompression, error.Aborted => return,
                error.TargetAlreadyInstalled => {
                    std.log.info("latest version already installed", .{});
                    return;
                },
                else => return err,
            };
            defer target.deinit(alloc);
            defer saveDir.close(io);

            const saveDirPath = store.generateSaveOutDirPath(alloc, conf.name, target.versionString);
            defer alloc.free(saveDirPath);

            try store.saveOutDir(saveDir, saveDirPath);

            var confDir = store.getConfDir(conf.name).?;
            defer confDir.close(io);
            try confDir.deleteTree(io, defaultInstall.versionString);
            std.log.info("removed {s} - {s}", .{ conf.name, defaultInstall.versionString });

            try store.removeDeadSymlinks();

            store.useAsDefault(conf.name, target.versionString, conf.binPath) catch |err| switch (err) {
                error.PathAlreadyExists => return,
                else => {
                    std.log.err("failed creating symlinks for {s} {f} with {s}", .{
                        conf.name,
                        target.version,
                        @errorName(err),
                    });
                    return;
                },
            };
            if (conf.manPages) |manPages| {
                store.linkManPages(conf.name, target.versionString, manPages) catch |err| {
                    std.log.warn("failed symlinking manpages for {s} with {s}", .{
                        conf.name,
                        @errorName(err),
                    });
                };
            }

            std.log.info("updated {s} to {f}", .{ conf.name, target.version });
        },
        .ls, .list, .installed, .@"list-installed" => {
            var store = try Store.init(alloc, io, &init.environ);
            defer store.deinit();

            const configName = args.next() orelse {
                var installed = try store.getInstalledConfs(alloc);
                defer {
                    for (installed.items) |item| alloc.free(item);
                    installed.deinit(alloc);
                }

                if (installed.items.len == 0) {
                    std.log.info("provide config name to list installed versions.", .{});
                    return;
                } else {
                    std.log.info("listing installed configs, provide config name to list installed versions.", .{});
                }

                for (installed.items) |conf| {
                    stdout.print("- {s}\n", .{conf}) catch unreachable;
                }
                return;
            };

            const conf = utils.resolveConfig(configName, stdout) orelse return;
            var confDir = store.getConfDir(conf.name) orelse {
                std.log.info("no {s}'s versions installed", .{conf.name});
                return;
            };
            defer confDir.close(io);

            std.log.info("installed {s} versions:", .{conf.name});

            var installed = try store.getConfInstallations(alloc, conf.name);
            defer {
                for (installed.items) |i| i.deinit();
                installed.deinit(alloc);
            }

            for (installed.items) |item| {
                if (item.default) {
                    stdout.print("{s} - default\n", .{item.versionString}) catch unreachable;
                } else {
                    stdout.print("{s}\n", .{item.versionString}) catch unreachable;
                }
            }
        },
        .remote, .@"list-remote" => {
            const configName = args.next() orelse {
                std.log.info("please provide config to list remote versions", .{});
                return;
            };

            const conf = utils.resolveConfig(configName, stdout) orelse return;

            var progressNameBuf: [128]u8 = undefined;
            var p = std.Progress.start(io, .{
                .root_name = std.fmt.bufPrint(&progressNameBuf, "resolving {s}", .{conf.name}) catch unreachable,
            });

            var client = std.http.Client{ .io = io, .allocator = alloc };
            defer client.deinit();

            var downloadProgress = p.start("downloading versions", 0);
            var versions = conf.getDownloadTargets(alloc, io, &client, downloadProgress) catch |err| {
                std.log.err("failed fetching versions file with {s}", .{@errorName(err)});
                return;
            };
            defer {
                for (versions.items) |item| item.deinit(alloc);
                versions.deinit(alloc);
            }
            downloadProgress.end();
            p.end();

            var store = try Store.init(alloc, io, &init.environ);
            defer store.deinit();

            var installed: std.array_list.Aligned(Store.Install, null) = store.getConfInstallations(alloc, conf.name) catch .empty;
            defer {
                for (installed.items) |item| item.deinit();
                installed.deinit(alloc);
            }

            const range: ?std.SemanticVersion.Range = blk: {
                const looseVersion = args.next() orelse break :blk null;
                break :blk try utils.parseUserVersion(looseVersion);
            };

            for (versions.items) |item| {
                const matchesVersionRange = if (range) |r| r.includesVersion(item.version) else true;
                if (!matchesVersionRange) {
                    continue;
                }

                var isInstalled = false;
                for (installed.items) |installation| {
                    if (installation.version.order(item.version) == .eq) {
                        isInstalled = true;
                        break;
                    }
                }

                const requiresSourceBuilding = item.tarball == null and conf.buildTarget != null;
                if (isInstalled) {
                    try stdout.print("{f} - installed\n", .{item.version});
                } else if (requiresSourceBuilding) {
                    try stdout.print("{f} - requires source build (no prebuilt {s} binary)\n", .{
                        item.version,
                        @tagName(builtin.target.os.tag),
                    });
                } else {
                    try stdout.print("{f}\n", .{item.version});
                }
            }
        },
        .use => {
            const configName = args.next() orelse {
                std.log.info("please provide config to change version of", .{});
                return;
            };

            const conf = utils.resolveConfig(configName, stdout) orelse return;

            if (conf.type == .Package) {
                std.log.info("use command is not supported for {s}", .{conf.name});
                return;
            }

            const looseVersion = args.next() orelse {
                std.log.info("please provide version of config to use (eg. 22 or 0.15 or 1.2.3)", .{});
                return;
            };
            const range = try utils.parseUserVersion(looseVersion);

            var store = try Store.init(alloc, io, &init.environ);
            defer store.deinit();

            const pickedVersionString = store.useAsDefaultWithRange(conf.name, range, conf.binPath) catch |err| switch (err) {
                error.NoMatchingVersionFound => {
                    std.log.err(
                        "no installed version matching {s} for {s} was found",
                        .{ looseVersion, conf.name },
                    );

                    return;
                },
                else => return err,
            } orelse return;
            defer alloc.free(pickedVersionString);

            if (conf.manPages) |pages| store.linkManPages(conf.name, pickedVersionString, pages) catch {
                @branchHint(.unlikely);
                stdout.print("failed linking manpages for {s}\n", .{conf.name}) catch {};
            };

            std.log.info("using {s} as default for {s}", .{ pickedVersionString, configName });
        },
        .remove, .uninstall, .delete => {
            const configName = args.next() orelse {
                std.log.info("please provide config to delete", .{});
                return;
            };

            const conf = utils.resolveConfig(configName, stdout) orelse return;

            var store = try Store.init(alloc, io, &init.environ);
            defer store.deinit();

            var installed = try store.getConfInstallations(alloc, conf.name);
            defer {
                for (installed.items) |item| item.deinit();
                installed.deinit(alloc);
            }

            if (installed.items.len == 0) {
                std.log.info("no versions installed for {s}", .{conf.name});
                return;
            }

            var versionsToRemove: std.array_list.Aligned([]const u8, null) = .empty;
            defer versionsToRemove.deinit(alloc);

            switch (conf.type) {
                .Runtime => {
                    if (args.next()) |looseVersion| {
                        const versionRange = utils.parseUserVersion(looseVersion) catch |err| {
                            std.log.err("failed parsing version string {s} with {s} error", .{
                                looseVersion,
                                @errorName(err),
                            });
                            return;
                        };

                        for (installed.items) |item| {
                            if (versionRange.includesVersion(item.version)) {
                                try versionsToRemove.append(alloc, item.versionString);
                            }
                        }

                        if (versionsToRemove.items.len == 0) {
                            std.log.info("no {s} installations matching {s} version were found", .{
                                conf.name,
                                looseVersion,
                            });
                            return;
                        }
                    } else {
                        for (installed.items) |item| {
                            if (item.default) {
                                try versionsToRemove.append(alloc, item.versionString);
                                break;
                            }
                        } else {
                            try versionsToRemove.append(alloc, installed.items[0].versionString);
                        }
                    }
                },
                .Package => {
                    for (installed.items) |item| {
                        try versionsToRemove.append(alloc, item.versionString);
                    }
                },
            }
            std.debug.assert(versionsToRemove.items.len > 0);

            var confDir = store.getConfDir(conf.name).?;
            defer confDir.close(io);

            var removedDefaultOne = false;
            for (versionsToRemove.items) |versionToRemove| {
                confDir.deleteTree(io, versionToRemove) catch |err| {
                    std.log.warn("failed removing {s} version from installations/{s} with {s} error", .{
                        versionToRemove,
                        conf.name,
                        @errorName(err),
                    });
                    continue;
                };

                for (installed.items, 0..) |item, i| {
                    if (!std.mem.eql(u8, item.versionString, versionToRemove)) {
                        continue;
                    }

                    const removed = installed.swapRemove(i);
                    defer removed.deinit();

                    if (removed.default) {
                        removedDefaultOne = true;
                    }

                    std.log.info("removed {s} - {s}", .{ conf.name, versionToRemove });

                    break;
                }
            }

            try store.removeDeadSymlinks();

            if (!removedDefaultOne) {
                return;
            }

            const installationToUse = if (installed.items.len > 0) installed.items[0] else null;

            if (installationToUse) |installation| {
                const pickedVersionString = try store.useAsDefaultWithRange(conf.name, std.SemanticVersion.Range{
                    .max = installation.version,
                    .min = installation.version,
                }, conf.binPath) orelse return;
                defer alloc.free(pickedVersionString);

                std.log.info("using {s} as default for {s}", .{ pickedVersionString, conf.name });
            } else {
                // it doesn't really matter if empty installation folder will exists or not for copper
                const installationsDir = store.getDir(.installations) catch return;
                installationsDir.deleteTree(io, conf.name) catch return;
                std.log.info("removed {s} installations folder", .{conf.name});
            }
        },
    }
}

test {
    _ = @import("./config/common.zig");

    std.testing.refAllDecls(@This());
}
