const std = @import("std");
const builtin = @import("builtin");
const buildOptions = @import("build_options");
const consts = @import("consts");

const Store = @import("./store.zig");
const shell = @import("./shell.zig");
const utils = @import("./utils.zig");
const Copper = @import("./copper-functions.zig");
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

    const command = std.meta.stringToEnum(
        Command,
        args.next() orelse "help",
    ) orelse {
        const stdout = std.fs.File.stdout();
        defer stdout.close();

        const commands = comptime utils.concatComptime(std.meta.fieldNames(Command), ", ");
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

            try writer.print("{f} optimize mode: {s}\n", .{
                buildOptions.version,
                @tagName(builtin.mode),
            });

            return;
        },
        .shell => {
            const shellType = std.meta.stringToEnum(
                shell.Shell,
                args.next() orelse return error.NoShellProvided,
            ) orelse {
                const stdout = std.fs.File.stdout();
                defer stdout.close();

                const shells = comptime utils.concatComptime(std.meta.fieldNames(shell.Shell), ", ");
                _ = stdout.write("available shells: " ++ shells ++ "\n") catch unreachable;

                return error.UnsupportedShell;
            };

            var configsToCheckBuf: [configs.configs.keys().len][]const u8 = undefined;
            var configsToCheck: std.array_list.Aligned([]const u8, null) = .initBuffer(&configsToCheckBuf);

            const triggerFilesCount = comptime blk: {
                var sum: u16 = 0;

                for (configs.configs.values()) |interface| {
                    if (interface.fileHooks) |fileHooks| sum += fileHooks.len;
                }

                break :blk sum;
            };
            var triggerFilesBuf: [triggerFilesCount][]const u8 = undefined;
            var triggerFilesArray: std.array_list.Aligned([]const u8, null) = .initBuffer(&triggerFilesBuf);

            while (args.next()) |confName| {
                const conf = configs.configs.get(confName) orelse {
                    std.log.err("'{s}' config is not recognized", .{confName});
                    return error.UnrecognisedConfig;
                };

                if (conf.fileHooks) |fileHooks| {
                    configsToCheck.appendAssumeCapacity(confName);

                    for (fileHooks) |file| {
                        triggerFilesArray.appendAssumeCapacity(file);
                    }
                } else {
                    std.log.err("'{s}' config doesn't not support file hooks", .{confName});
                    return error.NotSupportedConfig;
                }
            }

            var store = try Store.init(alloc);
            defer store.deinit();

            const out = std.fs.File.stdout();
            defer out.close();
            var buf: [128]u8 = undefined;

            var outwriter = out.writer(&buf);
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

            return;
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
                    std.log.err("'{s}' config is not recognized", .{confName});
                    return error.UnrecognisedConfig;
                };

                const fileHooks = conf.fileHooks orelse {
                    std.log.err("'{s}' config doesn't not support file hooks", .{confName});
                    return error.NotSupportedConfig;
                };

                var versionString: []const u8 = undefined;
                for (fileHooks) |filename| {
                    const file = cwd.openFile(filename, .{}) catch continue;
                    defer file.close();

                    versionString = conf.resolveVersionFromFile(alloc, filename, file) orelse continue;

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

            return;
        },
        .list => {
            var store = try Store.init(alloc);
            defer store.deinit();

            var installed = try store.getInstalledConfs(alloc);
            defer {
                for (installed.items) |item| alloc.free(item);
                installed.deinit(alloc);
            }

            if (installed.items.len == 0) {
                return;
            }

            const stdout = std.fs.File.stdout();
            defer stdout.close();

            var buf: [1024]u8 = undefined;
            var writer = stdout.writer(&buf);
            defer writer.interface.flush() catch {};

            writer.interface.print("installed confs:\n", .{}) catch unreachable;

            for (installed.items) |conf| {
                writer.interface.print("- {s}\n", .{conf}) catch unreachable;
            }

            return;
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

            const targetFilename, const targetFile = try Copper.getTargetFile(alloc, &client, &store, &target);
            defer alloc.free(targetFilename);
            defer targetFile.close();

            var verifyingShasumProgress = p.start("verifying shasum", 0);
            if (!try Store.verifyShasum(alloc, &targetFile, target.shasum.?)) {
                try targetFile.setEndPos(0);
                return error.IncorrectShasum;
            }
            verifyingShasumProgress.end();
            std.log.info("shasum matches expected", .{});

            const tmpDir = try store.prepareTmpDirForDecompression(consts.EXE_NAME, target.version);

            const file = try CopperConfig.decompressCopper(alloc, std.meta.stringToEnum(
                common.Compression,
                std.fs.path.extension(target.tarball)[1..],
            ) orelse return error.UnknownCompression, targetFile, tmpDir);
            defer alloc.free(file);

            var selfPathBuf: [std.fs.max_path_bytes]u8 = undefined;
            const selfPath = try std.fs.selfExePath(&selfPathBuf);

            try std.fs.deleteFileAbsolute(selfPath);
            try std.fs.renameAbsolute(file, selfPath);

            std.log.info("updated {s} to {f}", .{ consts.EXE_NAME, target.version });

            return;
        },
        .store => {
            const subcommand: StoreCommands = std.meta.stringToEnum(
                StoreCommands,
                args.next() orelse return error.NoSubcommandProvided,
            ) orelse {
                const stdout = std.fs.File.stdout();
                defer stdout.close();

                const commands = comptime utils.concatComptime(std.meta.fieldNames(StoreCommands), ", ");
                _ = stdout.write("available commands: " ++ commands ++ "\n") catch unreachable;

                return error.UnrecognisedSubcommand;
            };

            var store = try Store.init(alloc);
            defer store.deinit();

            switch (subcommand) {
                .dir => {
                    const stdout = std.fs.File.stdout();
                    defer stdout.close();

                    _ = stdout.write(store.rootPath) catch unreachable;
                    _ = stdout.write("\n") catch unreachable;
                },
                .installations, .@"installations-dir" => {
                    const stdout = std.fs.File.stdout();
                    defer stdout.close();

                    _ = stdout.write(store.installationsDirPath) catch unreachable;
                    _ = stdout.write("\n") catch unreachable;
                },
                .@"cache-dir" => {
                    const stdout = std.fs.File.stdout();
                    defer stdout.close();

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
                \\copper - utility to handle installation of packages. Some examples of execution:
                \\
                \\  copper list-remote|remote node 22          - list all node 22.*.* versions which are available for installation on your machine. You can also omit `22` to see all available versions.
                \\  copper add|install node 22                 - fetch most recent node with matches 22.*.* version.
                \\  copper list-installed|installed node       - show installed node versions (you can also provide version to narrow log down)
                \\  copper remove|uninstall|delete node 22.*.* - remove node version 22.*.* if is installed.
                \\  copper use node 24                         - change default node version to 24.*.*
                \\  copper update node                         - update default node installation to latest available version
                \\
                \\To provide installed packages, copper needs to patch "$PATH" - do so call in your shell:
                \\
                \\  copper shell zsh|bash|fish|pwsh [...configs]
                \\  copper shell zsh|bash|fish|pwsh node python
                \\
                \\  [configs] - are configurations that support dynamically changing config version based on some
                \\  files. With this enabled, copper will check current dir on `cd` and if it finds needed file it
                \\  will parse it and change node version to one specified in file, if this version is installed.
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
        .configs, .confs => {
            const stdout = std.fs.File.stdout();
            defer stdout.close();

            var buf: [1024]u8 = undefined;
            var writer = stdout.writer(&buf);
            defer writer.interface.flush() catch {};

            writer.interface.print("supported configs:\n", .{}) catch unreachable;

            for (configs.configs.keys()) |conf| {
                writer.interface.print("- {s}\n", .{conf}) catch unreachable;
            }

            return;
        },
        .outdated => {
            const p = std.Progress.start(.{ .root_name = "checking outdated" });
            defer p.end();

            var stdoutBuf: [1024]u8 = undefined;
            var stdout = std.fs.File.stdout().writer(&stdoutBuf);

            var writer = &stdout.interface;
            defer {
                writer.writeByte('\n') catch {};
                writer.flush() catch unreachable;
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

            var client = std.http.Client{ .allocator = alloc };
            defer client.deinit();

            const userProvidedConf = args.next() orelse null;
            if (userProvidedConf) |conf| {
                for (installed.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item, conf)) {
                        break;
                    }
                } else {
                    std.log.err("{s} is not installed", .{conf});
                    return error.UnrecognisedConfig;
                }
            }

            p.setEstimatedTotalItems(
                if (userProvidedConf == null) installed.items.len else 1,
            );

            var pool: std.Thread.Pool = undefined;
            try pool.init(.{
                .allocator = alloc,
                .n_jobs = @min(3, std.Thread.getCpuCount() catch 1),
            });
            defer pool.deinit();

            var waitGroup: std.Thread.WaitGroup = .{};
            defer waitGroup.wait();

            for (installed.items) |configName| {
                const matchedFilter = if (userProvidedConf) |userConf|
                    std.ascii.eqlIgnoreCase(userConf, configName)
                else
                    true;

                if (!matchedFilter) {
                    continue;
                }

                pool.spawnWg(
                    &waitGroup,
                    Copper.printOutdated,
                    .{ alloc, configName, &client, p, &store, writer },
                );
            }

            return;
        },
        .add, .install => {
            const configName = args.next() orelse return error.NoConfigProvided;
            const conf = try utils.resolveConfig(configName);

            var p = std.Progress.start(.{ .root_name = "installing" });
            defer p.end();

            var client = std.http.Client{ .allocator = alloc };
            defer client.deinit();

            var downloadProgress = p.start("downloading versions", 0);
            var versions = try conf.getDownloadTargets(alloc, &client, downloadProgress);
            downloadProgress.end();
            defer {
                for (versions.items) |item| item.deinit(alloc);
                versions.deinit(alloc);
            }

            var target: *common.DownloadTarget = undefined;
            if (args.next()) |looseVersion| {
                const allowedVersions = try common.parseUserVersion(looseVersion);

                for (versions.items) |*item| {
                    if (allowedVersions.includesVersion(item.version)) {
                        target = item;
                        break;
                    }
                } else {
                    return error.NoMatchingTargetFound;
                }
            } else {
                target = &versions.items[0];
            }

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
            const targetFilename, const targetFile = try Copper.getTargetFile(alloc, &client, &store, target);
            defer alloc.free(targetFilename);
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

            if (target.shasum) |shasum| {
                var verifyingShasumProgress = p.start("verifying shasum", 0);
                if (!try Store.verifyShasum(alloc, &targetFile, shasum)) {
                    try targetFile.setEndPos(0);
                    return error.IncorrectShasum;
                }
                verifyingShasumProgress.end();
                std.log.info("shasum matches expected", .{});
            } else {
                std.log.info("skipping shasum verification, no target shasum were found", .{});
            }

            const ext = std.fs.path.extension(targetFilename);

            const compression = std.meta.stringToEnum(
                common.Compression,
                if (ext.len == 0) "uncompressed" else ext[1..],
            ) orelse return error.UnknownCompression;

            const tmpDir = try store.prepareTmpDirForDecompression(configName, target.version);

            var decompressProgress = p.start("decompressing", 0);
            var outDir = try conf.decompressTargetFile(alloc, compression, targetFile, tmpDir);
            defer outDir.close();
            decompressProgress.end();

            if (conf.buildTarget) |buildTarget| {
                var buildProgress = p.start("building", 0);
                defer buildProgress.end();

                try buildTarget(alloc, buildProgress, outDir);
            }

            const savedDirPath = try store.saveOutDir(outDir, configName, target.versionString);
            defer alloc.free(savedDirPath);

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
            const configName = args.next() orelse return error.NoConfigProvided;
            const conf = try utils.resolveConfig(configName);

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
                return error.NoDefaultInstallFound;
            }

            var client = std.http.Client{ .allocator = alloc };
            defer client.deinit();

            var downloadProgress = p.start("downloading versions", 0);
            var versions = try conf.getDownloadTargets(alloc, &client, downloadProgress);
            downloadProgress.end();
            defer {
                for (versions.items) |item| item.deinit(alloc);
                versions.deinit(alloc);
            }

            var target: *common.DownloadTarget = undefined;
            if (args.next()) |looseVersion| {
                const allowedVersions = try common.parseUserVersion(looseVersion);

                for (versions.items) |*item| {
                    if (allowedVersions.includesVersion(item.version)) {
                        target = item;
                        break;
                    }
                } else {
                    return error.NoMatchingTargetFound;
                }
            } else {
                for (versions.items) |*item| {
                    if (defaultInstall.version.order(item.version) == .lt) {
                        target = item;
                        break;
                    }
                } else {
                    std.log.info("latest version is alredy installed", .{});
                    return;
                }
            }

            std.log.info("resolved to {f}", .{target.version});

            var existingDir = store.getConfVersionDir(configName, target.versionString, .{});
            if (existingDir) |*dir| {
                dir.close();
                std.log.info("{s} - {f} already installed", .{ configName, target.version });
                return;
            }

            downloadProgress = p.start("downloading target file", 0);
            const targetFilename, const targetFile = try Copper.getTargetFile(alloc, &client, &store, target);
            defer alloc.free(targetFilename);
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

            if (target.shasum) |shasum| {
                var verifyingShasumProgress = p.start("verifying shasum", 0);
                if (!try Store.verifyShasum(alloc, &targetFile, shasum)) {
                    try targetFile.setEndPos(0);
                    return error.IncorrectShasum;
                }
                verifyingShasumProgress.end();
                std.log.info("shasum matches expected", .{});
            } else {
                std.log.info("skipping shasum verification, no target shasum were found", .{});
            }

            const ext = std.fs.path.extension(target.tarball);

            const compression = std.meta.stringToEnum(
                common.Compression,
                if (ext.len == 0) "uncompressed" else ext[1..],
            ) orelse return error.UnknownCompression;

            const tmpDir = try store.prepareTmpDirForDecompression(configName, target.version);

            var decompressProgress = p.start("decompressing", 0);
            var outDir = try conf.decompressTargetFile(alloc, compression, targetFile, tmpDir);
            defer outDir.close();
            decompressProgress.end();

            const savedDirPath = try store.saveOutDir(outDir, configName, target.versionString);
            defer alloc.free(savedDirPath);

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
        .installed, .@"list-installed" => {
            const configName = args.next() orelse return error.NoConfigProvided;

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

            for (installed.items) |item| {
                if (item.default) {
                    stdout.print("{s} - default\n", .{item.versionString}) catch unreachable;
                } else {
                    stdout.print("{s}\n", .{item.versionString}) catch unreachable;
                }
            }
        },
        .remote, .@"list-remote" => {
            const configName = args.next() orelse return error.NoConfigProvided;
            const conf = try utils.resolveConfig(configName);

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

            var store = try Store.init(alloc);
            defer store.deinit();

            const installed: std.array_list.Managed(Store.Install) = store.getConfInstallations(configName) catch .init(alloc);
            defer {
                for (installed.items) |item| item.deinit();
                installed.deinit();
            }

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
            const configName = args.next() orelse return error.NoConfigProvided;
            const conf = try utils.resolveConfig(configName);

            const looseVersion = args.next() orelse return error.NoVersionProvided;
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
            const configName = args.next() orelse return error.NoConfigProvided;
            const conf = try utils.resolveConfig(configName);

            var store = try Store.init(alloc);
            defer store.deinit();

            const installed = try store.getConfInstallations(configName);
            defer {
                for (installed.items) |item| item.deinit();
                installed.deinit();
            }

            if (installed.items.len == 0) {
                std.log.info("no versions installed for {s}", .{configName});
                return;
            }

            const versionString = blk: {
                if (args.next()) |version| break :blk version;
                for (installed.items) |item| {
                    if (item.default) {
                        break :blk item.versionString;
                    }
                }

                break :blk installed.items[0].versionString;
            };

            var confDir = store.getConfDir(configName).?;
            defer confDir.close();
            try confDir.deleteTree(versionString);

            std.log.info("removed {s} - {s}", .{ configName, versionString });

            store.removeDeadSymlinks();

            var firstNonDefault: ?Store.Install = null;
            var removedDefaultOne = false;
            for (installed.items) |item| {
                if (!item.default) {
                    firstNonDefault = item;
                }

                if (item.default and std.mem.eql(u8, versionString, item.versionString)) {
                    removedDefaultOne = true;
                }
            }

            if (!removedDefaultOne or firstNonDefault == null) {
                return;
            }

            const pickedVersionString = try store.useAsDefaultWithRange(configName, std.SemanticVersion.Range{
                .max = firstNonDefault.?.version,
                .min = firstNonDefault.?.version,
            }, conf.binPath) orelse return;
            defer alloc.free(pickedVersionString);

            std.log.info("using {s} as default for {s}", .{ pickedVersionString, configName });
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
}
