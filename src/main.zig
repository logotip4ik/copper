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
const common = @import("./config/common.zig");

const Command = enum {
    install,
    add,
    use,
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
};

pub fn main() !void {
    const heap = comptime mem.getHeap();
    const alloc: std.mem.Allocator = heap.allocator();
    defer _ = heap.deinit();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    // skip executable
    _ = args.next() orelse return error.NoExecutableArg;

    const commandArg = args.next() orelse "help";
    const command = std.meta.stringToEnum(Command, commandArg) orelse {
        const stdout = std.fs.File.stdout();

        const commands = comptime utils.concatComptime(std.meta.fieldNames(Command), ", ");
        _ = stdout.write(commandArg) catch unreachable;
        _ = stdout.write(" is not recognized as a command.\navailable commands: " ++ commands ++ "\n") catch unreachable;

        return;
    };

    switch (command) {
        .version => try utils.printVersion(),
        .help => try utils.printHelp(),
        .shell => {
            const shellsString = comptime utils.concatComptime(std.meta.fieldNames(shell.Shell), ", ");
            const shellArg = args.next() orelse {
                std.log.info("please provide shell argument.\navailable shells: {s}", .{shellsString});
                return;
            };

            const shellType = std.meta.stringToEnum(shell.Shell, shellArg) orelse {
                const stdout = std.fs.File.stdout();

                _ = stdout.write(shellArg) catch unreachable;
                _ = stdout.write(" is not recognized as a shell.\navailable shells: " ++ shellsString ++ "\n") catch unreachable;

                return;
            };

            var store = try Store.init(alloc);
            defer store.deinit();

            var configsToCheck: std.array_list.Aligned([]const u8, null) = .empty;
            defer configsToCheck.deinit(alloc);

            var triggerFilesArray: std.array_list.Aligned([]const u8, null) = .empty;
            defer triggerFilesArray.deinit(alloc);

            var installedConfigs = try store.getInstalledConfs(alloc);
            defer {
                for (installedConfigs.items) |conf| alloc.free(conf);
                installedConfigs.deinit(alloc);
            }

            for (installedConfigs.items) |configName| {
                const conf = configs.configs.get(configName) orelse continue;

                if (conf.fileHooks) |fileHooks| {
                    try configsToCheck.append(alloc, configName);
                    try triggerFilesArray.appendSlice(alloc, fileHooks);
                }
            }

            var buf: [1024]u8 = undefined;
            var outwriter = std.fs.File.stdout().writer(&buf);
            defer outwriter.interface.flush() catch unreachable;

            try shell.addPathExtention(
                &outwriter.interface,
                shellType,
                store.aliasesDirPath,
            );

            try shell.addUseOnPathChange(
                &outwriter.interface,
                shellType,
                configsToCheck.items,
                triggerFilesArray.items,
            );

            const commandsWithoutConf = &[_][]const u8{
                "list",
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
                &outwriter.interface,
                shellType,
                std.meta.fieldNames(Command),
                configs.configs.keys(),
                std.meta.fieldNames(StoreCommands),
                commandsWithoutConf,
            );
        },
        .@"file-hook" => {
            var store = try Store.init(alloc);
            defer store.deinit();

            const cwd = std.fs.cwd();

            var outBuf: [256]u8 = undefined;
            var writer = std.fs.File.stdout().writer(&outBuf);
            defer writer.interface.flush() catch unreachable;

            while (args.next()) |confName| {
                const conf = configs.configs.get(confName) orelse {
                    std.log.warn("{s} is not recognized as config. skipping...", .{confName});
                    continue;
                };

                const fileHooks = conf.fileHooks orelse continue;
                const resolveVersionFromFile = conf.resolveVersionFromFile orelse continue;

                var versionString: []const u8 = undefined;
                for (fileHooks) |filename| {
                    const file = cwd.openFile(filename, .{}) catch continue;
                    defer file.close();

                    versionString = resolveVersionFromFile(alloc, filename, file) orelse continue;

                    break;
                } else continue;
                defer alloc.free(versionString);

                const range = common.parseUserVersion(versionString) catch continue;

                const changedVersion = store.useAsDefaultWithRange(confName, range, conf.binPath) catch |err| switch (err) {
                    error.NoMatchingVersionFound => {
                        try writer.interface.print("no installation was found for {s} version '{s}' to install run:\n{s} add {s} {s}\n", .{
                            confName,
                            versionString,
                            consts.EXE_NAME,
                            confName,
                            versionString,
                        });
                        continue;
                    },
                    else => continue,
                };

                const choosenVersion = changedVersion orelse continue;
                defer alloc.free(choosenVersion);

                writer.interface.print("using {s} {s}\n", .{ confName, choosenVersion }) catch continue;
            }
        },
        .@"self-update", .@"update-self" => {
            var p = std.Progress.start(.{ .root_name = "updating copper" });
            defer p.end();

            var store = try Store.init(alloc);
            defer store.deinit();

            var client = std.http.Client{ .allocator = alloc };
            defer client.deinit();

            const currentVersion = buildOptions.version;
            const target = try CopperConfig.latestVersion(alloc, &client, p);
            defer target.deinit(alloc);

            if (target.version.order(currentVersion) != .gt) {
                std.log.info("already using latest available {f} version", .{currentVersion});
                return;
            }

            std.log.info("newer version {f} is available", .{target.version});

            const targetFilename, const targetFile = try utils.getTargetFile(alloc, &client, &store, &target);
            defer alloc.free(targetFilename);
            defer targetFile.close();

            var verifyingShasumProgress = p.start("verifying shasum", 0);
            if (!try Store.verifyShasum(alloc, &targetFile, target.shasum.?)) {
                @branchHint(.unlikely);

                try targetFile.setEndPos(0);
                std.log.err("shasum verification failed, try reruning self-update command", .{});
                return;
            }
            verifyingShasumProgress.end();
            std.log.info("shasum matches expected", .{});

            const tmpDir = try store.prepareTmpDirForDecompression(consts.EXE_NAME, target.version);

            const compression = utils.guessCompression(targetFilename) orelse return;

            const file = try CopperConfig.decompressCopper(alloc, compression, targetFile, tmpDir);
            defer alloc.free(file);

            var selfPathBuf: [std.fs.max_path_bytes]u8 = undefined;
            const selfPath = try std.fs.selfExePath(&selfPathBuf);

            try std.fs.deleteFileAbsolute(selfPath);
            try std.fs.renameAbsolute(file, selfPath);

            std.log.info("updated {s} to {f}", .{ consts.EXE_NAME, target.version });
        },
        .store => {
            const storeSubcommands = comptime utils.concatComptime(std.meta.fieldNames(StoreCommands), ", ");
            const storeSubcommandArg = args.next() orelse {
                std.log.info("provide store subcommand.\navailable subcommands: {s}", .{storeSubcommands});
                return;
            };

            const stdout = std.fs.File.stdout();

            const subcommand: StoreCommands = std.meta.stringToEnum(StoreCommands, storeSubcommandArg) orelse {
                _ = stdout.write(storeSubcommandArg) catch unreachable;
                _ = stdout.write(" is not recognized as a store subcommand.\navailable subcommands: " ++ storeSubcommands ++ "\n") catch unreachable;

                return;
            };

            var store = try Store.init(alloc);
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
                .@"prune-aliases" => {
                    store.removeDeadSymlinks();
                },
            }
        },
        .configs, .confs => {
            var buf: [1024]u8 = undefined;
            var writer = std.fs.File.stdout().writer(&buf);
            defer writer.interface.flush() catch {};

            writer.interface.print("supported configs:\n", .{}) catch unreachable;

            for (configs.configs.keys()) |conf| {
                writer.interface.print("- {s}\n", .{conf}) catch unreachable;
            }
        },
        .outdated => {
            const p = std.Progress.start(.{ .root_name = "checking outdated" });
            defer p.end();

            var stdoutBuf: [512]u8 = undefined;
            var out = std.fs.File.stdout().writer(&stdoutBuf);

            var writer = &out.interface;
            defer {
                std.Progress.lockStdErr();
                defer std.Progress.unlockStdErr();

                writer.flush() catch {};
            }

            var store = try Store.init(alloc);
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

            var client = std.http.Client{ .allocator = alloc };
            defer client.deinit();

            var pool: std.Thread.Pool = undefined;
            try pool.init(.{
                .allocator = alloc,
                .n_jobs = @min(3, std.Thread.getCpuCount() catch 1),
            });
            defer pool.deinit();

            var waitGroup: std.Thread.WaitGroup = .{};
            defer waitGroup.wait();

            for (installed.items) |configName| {
                pool.spawnWg(
                    &waitGroup,
                    utils.printOutdated,
                    .{ alloc, configName, &client, p, &store, writer },
                );
            }
        },
        .add, .install => {
            const configName = args.next() orelse {
                std.log.info("please provide config to install", .{});
                return;
            };
            const conf = utils.resolveConfig(configName) orelse return;

            var p = std.Progress.start(.{ .root_name = "installing" });
            defer p.end();

            var client = std.http.Client{ .allocator = alloc };
            defer client.deinit();

            var downloadProgress = p.start("downloading versions", 0);
            var versions = conf.getDownloadTargets(alloc, &client, downloadProgress) catch |err| {
                std.log.err("failed fetching versions file with {s}", .{@errorName(err)});
                return;
            };
            downloadProgress.end();
            defer {
                for (versions.items) |item| item.deinit(alloc);
                versions.deinit(alloc);
            }

            if (versions.items.len == 0) {
                std.log.info("no download targets found for {s}", .{configName});
                return;
            }

            const target = switch (conf.type) {
                .Package => &versions.items[0],
                .Runtime => blk: {
                    if (args.next()) |looseVersion| {
                        const allowedVersions = try common.parseUserVersion(looseVersion);

                        for (versions.items) |*item| {
                            if (allowedVersions.includesVersion(item.version)) {
                                break :blk item;
                            }
                        } else {
                            std.log.info("no target matching {s} version found", .{looseVersion});
                            return;
                        }
                    }

                    // select first non alpha/beta version
                    for (versions.items) |*item| {
                        if (item.version.pre == null and item.version.build == null) {
                            break :blk item;
                        }
                    }

                    // select latest one as a last resort
                    break :blk &versions.items[0];
                },
            };

            std.log.info("resolved to {f}", .{target.version});

            var store = try Store.init(alloc);
            defer store.deinit();

            var existingDir = store.getConfVersionDir(configName, target.versionString, .{});
            if (existingDir) |*dir| {
                dir.close();
                std.log.info("{s} - {f} already installed", .{ configName, target.version });
                return;
            }

            downloadProgress = p.start("downloading target file", 0);
            const targetFilename, const targetFile = try utils.getTargetFile(alloc, &client, &store, target);
            defer alloc.free(targetFilename);
            defer targetFile.close();
            downloadProgress.end();

            if (conf.getTarballShasum) |getTarballShasum| {
                var fetchingShasumProgress = p.start("fetching shasum", 0);
                defer fetchingShasumProgress.end();

                target.shasum = getTarballShasum(
                    alloc,
                    &client,
                    target.*,
                    fetchingShasumProgress,
                ) catch |err| {
                    std.log.err("failed fething tarball shasum with {s} error", .{@errorName(err)});
                    return;
                };
            }

            if (target.shasum) |shasum| {
                var verifyingShasumProgress = p.start("verifying shasum", 0);
                if (!try Store.verifyShasum(alloc, &targetFile, shasum)) {
                    std.log.err("shasum verification failed, try reruning add command", .{});
                    try targetFile.setEndPos(0);
                    return;
                }
                verifyingShasumProgress.end();
                std.log.info("shasum matches expected", .{});
            } else {
                std.log.info("skipping shasum verification, no target shasum were found", .{});
            }

            const compression = utils.guessCompression(targetFilename) orelse return;

            const tmpDir = try store.prepareTmpDirForDecompression(configName, target.version);

            var decompressProgress = p.start("decompressing", 0);
            var outDir = conf.decompressTargetFile(alloc, compression, targetFile, tmpDir) catch |err| {
                std.log.err("failed decompressing target file {s} with {s}", .{ targetFilename, @errorName(err) });
                return;
            };
            defer outDir.close();
            decompressProgress.end();

            const saveDirPath = store.generateSaveOutDirPath(alloc, configName, target.versionString);
            defer alloc.free(saveDirPath);

            var builtDir: ?std.fs.Dir = null;
            defer if (builtDir) |*dir| dir.close();

            if (conf.buildTarget) |buildTarget| {
                var buildProgress = p.start("building", 0);
                defer buildProgress.end();

                builtDir = buildTarget(alloc, buildProgress, outDir, saveDirPath) catch |err| {
                    std.log.err("failed building with {s}", .{@errorName(err)});
                    return;
                };
            }

            try store.saveOutDir(builtDir orelse outDir, saveDirPath);

            store.useAsDefault(configName, target.versionString, conf.binPath) catch |err| switch (err) {
                error.PathAlreadyExists => return,
                else => {
                    std.log.err("failed creating symlinks for {s} {f}", .{ configName, target.version });
                    return;
                },
            };

            std.log.info("using {f} as default for {s}", .{ target.version, configName });
        },
        .update => {
            const configName = args.next() orelse {
                std.log.info("please provide config to update", .{});
                return;
            };
            const conf = utils.resolveConfig(configName) orelse return;

            var progressNameBuf: [32]u8 = undefined;
            var p = std.Progress.start(.{
                .root_name = std.fmt.bufPrint(&progressNameBuf, "updating {s}", .{configName}) catch unreachable,
            });
            defer p.end();

            var store = try Store.init(alloc);
            defer store.deinit();

            const installed = try store.getConfInstallations(configName);
            defer {
                for (installed.items) |item| item.deinit();
                installed.deinit();
            }

            var defaultInstall: Store.Install = undefined;
            for (installed.items) |item| {
                if (item.default) {
                    defaultInstall = item;
                    break;
                }
            } else {
                std.log.info("no default installation found for {s}. Maybe symlinks are broken...", .{configName});
                return;
            }

            var client = std.http.Client{ .allocator = alloc };
            defer client.deinit();

            var downloadProgress = p.start("downloading versions", 0);
            var versions = conf.getDownloadTargets(alloc, &client, downloadProgress) catch |err| {
                std.log.err("failed fetching versions file with {s}", .{@errorName(err)});
                return;
            };
            downloadProgress.end();
            defer {
                for (versions.items) |item| item.deinit(alloc);
                versions.deinit(alloc);
            }

            const target = blk: {
                for (versions.items) |*item| {
                    if (defaultInstall.version.order(item.version) == .lt) {
                        break :blk item;
                    }
                } else {
                    std.log.info("latest version is alredy installed", .{});
                    return;
                }
            };

            std.log.info("resolved to {f}", .{target.version});

            var existingDir = store.getConfVersionDir(configName, target.versionString, .{});
            if (existingDir) |*dir| {
                dir.close();
                std.log.info("{s} - {f} already installed", .{ configName, target.version });
                return;
            }

            downloadProgress = p.start("downloading target file", 0);
            const targetFilename, const targetFile = try utils.getTargetFile(alloc, &client, &store, target);
            downloadProgress.end();
            defer alloc.free(targetFilename);
            defer targetFile.close();

            if (conf.getTarballShasum) |getTarballShasum| {
                var fetchingShasumProgress = p.start("fetching shasum", 0);
                defer fetchingShasumProgress.end();

                target.shasum = getTarballShasum(
                    alloc,
                    &client,
                    target.*,
                    fetchingShasumProgress,
                ) catch |err| {
                    std.log.err("failed fething tarball shasum with {s} error", .{@errorName(err)});
                    return;
                };
            }

            if (target.shasum) |shasum| {
                var verifyingShasumProgress = p.start("verifying shasum", 0);
                if (!try Store.verifyShasum(alloc, &targetFile, shasum)) {
                    try targetFile.setEndPos(0);
                    std.log.err("shasum verification failed, try reruning update command", .{});
                    return;
                }
                verifyingShasumProgress.end();
                std.log.info("shasum matches expected", .{});
            } else {
                std.log.info("skipping shasum verification, no target shasum were found", .{});
            }

            const compression = utils.guessCompression(targetFilename) orelse return;

            const tmpDir = try store.prepareTmpDirForDecompression(configName, target.version);

            var decompressProgress = p.start("decompressing", 0);
            var outDir = conf.decompressTargetFile(alloc, compression, targetFile, tmpDir) catch |err| {
                std.log.err("failed decompressing target file {s} with {s}", .{ targetFilename, @errorName(err) });
                return;
            };
            defer outDir.close();
            decompressProgress.end();

            const saveDirPath = store.generateSaveOutDirPath(alloc, configName, target.versionString);
            defer alloc.free(saveDirPath);

            try store.saveOutDir(outDir, saveDirPath);

            const range = std.SemanticVersion.Range{
                .min = target.version,
                .max = target.version,
            };

            const pickedVersionString = store.useAsDefaultWithRange(configName, range, conf.binPath) catch |err| switch (err) {
                error.NoMatchingVersionFound => {
                    std.log.err(
                        "no installed version matching {s} for {s} was found",
                        .{ target.versionString, configName },
                    );

                    return;
                },
                else => return err,
            } orelse return;
            defer alloc.free(pickedVersionString);

            var confDir = store.getConfDir(configName).?;
            defer confDir.close();
            try confDir.deleteTree(defaultInstall.versionString);

            std.log.info("removed {s} - {s}", .{ configName, defaultInstall.versionString });
            std.log.info("updated {s} to {f}", .{ configName, target.version });
        },
        .list, .installed, .@"list-installed" => {
            var store = try Store.init(alloc);
            defer store.deinit();

            var buf: [2048]u8 = undefined;
            var stdoutWriter = std.fs.File.stdout().writer(&buf);

            var stdout = &stdoutWriter.interface;
            defer stdout.flush() catch {};

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

            const conf = utils.resolveConfig(configName) orelse return;

            var progressNameBuf: [32]u8 = undefined;
            var p = std.Progress.start(.{
                .root_name = std.fmt.bufPrint(&progressNameBuf, "resolving {s}", .{configName}) catch unreachable,
            });

            var client = std.http.Client{ .allocator = alloc };
            defer client.deinit();

            var downloadProgress = p.start("downloading versions", 0);
            var versions = conf.getDownloadTargets(alloc, &client, downloadProgress) catch |err| {
                std.log.err("failed fetching versions file with {s}", .{@errorName(err)});
                return;
            };
            defer {
                for (versions.items) |item| item.deinit(alloc);
                versions.deinit(alloc);
            }
            downloadProgress.end();
            p.end();

            var store = try Store.init(alloc);
            defer store.deinit();

            const installed: std.array_list.Managed(Store.Install) = store.getConfInstallations(configName) catch .init(alloc);
            defer {
                for (installed.items) |item| item.deinit();
                installed.deinit();
            }

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

                if (isInstalled) {
                    try writer.print("{f} - installed\n", .{item.version});
                } else {
                    try writer.print("{f}\n", .{item.version});
                }
            }
        },
        .use => {
            const configName = args.next() orelse {
                std.log.info("please provide config to change version of", .{});
                return;
            };
            const conf = utils.resolveConfig(configName) orelse return;

            if (conf.type == .Package) {
                std.log.info("use command is not supported for {s}", .{configName});
                return;
            }

            const looseVersion = args.next() orelse {
                std.log.info("please provide version of config to use (eg. 22 or 0.15 or 1.2.3)", .{});
                return;
            };
            const range = try common.parseUserVersion(looseVersion);

            var store = try Store.init(alloc);
            defer store.deinit();

            const pickedVersionString = store.useAsDefaultWithRange(configName, range, conf.binPath) catch |err| switch (err) {
                error.NoMatchingVersionFound => {
                    std.log.err(
                        "no installed version matching {s} for {s} was found",
                        .{ looseVersion, configName },
                    );

                    return;
                },
                else => return err,
            } orelse return;
            defer alloc.free(pickedVersionString);

            std.log.info("using {s} as default for {s}", .{ pickedVersionString, configName });
        },
        .remove, .uninstall, .delete => {
            const configName = args.next() orelse {
                std.log.info("please provide config to delete", .{});
                return;
            };

            const conf = utils.resolveConfig(configName) orelse return;

            var store = try Store.init(alloc);
            defer store.deinit();

            var installed = try store.getConfInstallations(configName);
            defer {
                for (installed.items) |item| item.deinit();
                installed.deinit();
            }

            if (installed.items.len == 0) {
                std.log.info("no versions installed for {s}", .{configName});
                return;
            }

            var versionsToRemove: std.array_list.Aligned([]const u8, null) = .empty;
            defer versionsToRemove.deinit(alloc);

            switch (conf.type) {
                .Runtime => {
                    if (args.next()) |looseVersion| {
                        const versionRange = common.parseUserVersion(looseVersion) catch |err| {
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
                                configName,
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

            var confDir = store.getConfDir(configName).?;
            defer confDir.close();

            var removedDefaultOne = false;
            for (versionsToRemove.items) |versionToRemove| {
                confDir.deleteTree(versionToRemove) catch |err| {
                    std.log.warn("failed removing {s} version from installations/{s} with {s} error", .{
                        versionToRemove,
                        configName,
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

                    std.log.info("removed {s} - {s}", .{ configName, versionToRemove });

                    break;
                }
            }

            if (!removedDefaultOne) {
                return;
            }

            store.removeDeadSymlinks();

            const installationToUse = if (installed.items.len > 0) installed.items[0] else null;

            if (installationToUse) |installation| {
                const pickedVersionString = try store.useAsDefaultWithRange(configName, std.SemanticVersion.Range{
                    .max = installation.version,
                    .min = installation.version,
                }, conf.binPath) orelse return;
                defer alloc.free(pickedVersionString);

                std.log.info("using {s} as default for {s}", .{ pickedVersionString, configName });
            } else {
                // it doesn't really matter if empty installation folder will exists or not for copper
                store.installationsDir.deleteTree(configName) catch return;
                std.log.info("removed {s} installations folder", .{configName});
            }
        },
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
    std.testing.refAllDecls(configs);
}
