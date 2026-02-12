const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");

const Alloc = std.mem.Allocator;

const Self = @This();

const logger = std.log.scoped(.store);

alloc: Alloc,

rootPath: []const u8,
rootDir: ?std.fs.Dir = null,

aliasesDirPath: []const u8,
aliasesDir: ?std.fs.Dir = null,

tmpDirPath: []const u8,
tmpDir: ?std.fs.Dir = null,

installationsDirPath: []const u8,
installationsDir: ?std.fs.Dir = null,

manDirPath: []const u8,
manDir: ?std.fs.Dir = null,

pub fn init(alloc: Alloc) !Self {
    const storeDirname = try std.fs.getAppDataDir(alloc, consts.EXE_NAME);
    errdefer alloc.free(storeDirname);

    const tmpDirname = getTmpDirname(alloc);
    defer alloc.free(tmpDirname);

    const tmpDirPath = try std.fs.path.join(alloc, &[_][]const u8{
        tmpDirname,
        consts.EXE_NAME,
    });
    errdefer alloc.free(tmpDirPath);

    const installationsDirPath = try std.fs.path.join(alloc, &.{ storeDirname, "installations" });
    errdefer alloc.free(installationsDirPath);

    const aliasesDirPath = try std.fs.path.join(alloc, &.{ storeDirname, "aliases" });
    errdefer alloc.free(aliasesDirPath);

    const manDirPath = try std.fs.path.join(alloc, &.{ storeDirname, "share", "man" });
    errdefer alloc.free(manDirPath);

    return Self{
        .alloc = alloc,
        .rootPath = storeDirname,
        .aliasesDirPath = aliasesDirPath,
        .tmpDirPath = tmpDirPath,
        .installationsDirPath = installationsDirPath,
        .manDirPath = manDirPath,
    };
}

pub fn deinit(self: *Self) void {
    if (self.rootDir) |*x| x.close();
    self.alloc.free(self.rootPath);

    if (self.aliasesDir) |*x| x.close();
    self.alloc.free(self.aliasesDirPath);

    if (self.tmpDir) |*x| x.close();
    self.alloc.free(self.tmpDirPath);

    if (self.installationsDir) |*x| x.close();
    self.alloc.free(self.installationsDirPath);

    if (self.manDir) |*x| x.close();
    self.alloc.free(self.manDirPath);
}

pub fn getRootFolder(self: *Self) !std.fs.Dir {
    const home = std.fs.openDirAbsolute(
        self.rootPath,
        .{ .iterate = true },
    ) catch |err| blk: switch (err) {
        error.FileNotFound => {
            std.fs.makeDirAbsolute(self.rootPath) catch {
                logger.err("failed creating home dir for copper", .{});
                return error.NoHomeDir;
            };
            break :blk try std.fs.openDirAbsolute(self.rootPath, .{ .iterate = true });
        },
        else => return err,
    };

    self.rootDir = home;
    return home;
}

pub inline fn getDir(
    self: *Self,
    comptime field: enum { installations, aliases, man, tmp },
) !std.fs.Dir {
    const dir = @tagName(field) ++ "Dir";
    const dirPath = @field(self, dir ++ "Path");

    if (@field(self, dir)) |x| {
        return x;
    }

    if (std.fs.openDirAbsolute(dirPath, .{ .iterate = true })) |x| {
        @branchHint(.likely);
        @field(self, dir) = x;
        return x;
    } else |err| blk: {
        switch (err) {
            error.FileNotFound => {
                std.fs.makeDirAbsolute(dirPath) catch break :blk;
                return std.fs.openDirAbsolute(dirPath, .{ .iterate = true }) catch break :blk;
            },
            else => {},
        }
    }

    const home = try self.getRootFolder();

    const openedDir = switch (field) {
        .tmp => unreachable,
        else => blk: {
            const relativePath = dirPath[self.rootPath.len + 1 ..];
            var pathIter = std.fs.path.componentIterator(relativePath) catch unreachable;

            while (pathIter.next()) |chunk| {
                home.makeDir(chunk.path) catch |err| {
                    logger.err("failed creating dir at {s}/{s}", .{ self.rootPath, chunk.path });
                    return err;
                };
            }

            break :blk home.openDir(relativePath, .{ .iterate = true }) catch |err| {
                logger.err("failed opening dir {s}/{s}", .{ self.rootPath, relativePath });
                return err;
            };
        },
    };

    @field(self, dir) = openedDir;

    return openedDir;
}

pub fn generateSaveOutDirPath(
    self: Self,
    alloc: std.mem.Allocator,
    confName: []const u8,
    version: []const u8,
) []const u8 {
    return std.fs.path.join(alloc, &[_][]const u8{
        self.installationsDirPath,
        confName,
        version,
    }) catch unreachable;
}

pub fn saveOutDir(
    self: *Self,
    out: std.fs.Dir,
    saveDirPath: []const u8,
) !void {
    std.debug.assert(std.mem.startsWith(u8, saveDirPath, self.installationsDirPath));

    var chunkIter = std.mem.splitScalar(u8, saveDirPath[self.installationsDirPath.len..], std.fs.path.sep);

    // skip leading slash
    _ = chunkIter.next().?;

    const confName = chunkIter.next().?;

    // version chunk also must be defined
    std.debug.assert(chunkIter.next() != null);

    var confDir = self.getConfDir(confName);
    if (confDir) |*dir| {
        dir.close();
    } else {
        const installationsDir = try self.getDir(.installations);
        try installationsDir.makeDir(confName);
    }

    var outBuf: [std.fs.max_path_bytes]u8 = undefined;
    const outPath = try out.realpath(".", &outBuf);

    logger.info("moving {s} to {s}", .{ outPath, saveDirPath });

    try std.fs.renameAbsolute(outPath, saveDirPath);
}

pub fn linkManPages(
    self: *Self,
    conf: []const u8,
    versionString: []const u8,
    manPages: []const []const u8,
) !void {
    var installDir = self.getConfVersionDir(conf, versionString, .{}) orelse {
        logger.err("missing {s} folder for {s} config installation", .{ versionString, conf });
        return error.NoInstallationFound;
    };
    defer installDir.close();

    var sections: std.hash_map.StringHashMapUnmanaged(std.fs.Dir) = .empty;
    defer {
        var iter = sections.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            entry.value_ptr.close();
        }
        sections.deinit(self.alloc);
    }

    var symlinks: u8 = 0;
    var pathBuf: [std.fs.max_path_bytes]u8 = undefined;

    const manDir = try self.getDir(.man);

    for (manPages) |manPage| {
        const sectionExt = std.fs.path.extension(manPage);
        if (sectionExt.len < 2) {
            @branchHint(.cold);
            logger.warn("expected {s} to have man page section in the extension", .{manPage});
            continue;
        }

        const section = sectionExt[1..];

        const sectionDir: std.fs.Dir = sections.get(section) orelse blk: {
            const manSectionDirName = std.fmt.bufPrint(&pathBuf, "man{s}", .{
                section,
            }) catch unreachable;

            const dir = manDir.makeOpenPath(manSectionDirName, .{}) catch |err| {
                @branchHint(.unlikely);
                logger.err("failed to open {s} section dir in {s} with {s}", .{
                    section,
                    self.manDirPath,
                    @errorName(err),
                });
                continue;
            };

            try sections.put(self.alloc, try self.alloc.dupe(u8, section), dir);

            break :blk dir;
        };

        const manPagePath = try std.fs.path.join(self.alloc, &[_][]const u8{
            self.installationsDirPath,
            conf,
            versionString,
            manPage,
        });
        defer self.alloc.free(manPagePath);

        const manPageName = std.fs.path.basename(manPage);
        sectionDir.deleteTree(manPageName) catch {};
        sectionDir.symLink(manPagePath, manPageName, .{}) catch |err| {
            logger.err("failed symlinking {s} to {s} with {s}", .{
                manPagePath,
                manPageName,
                @errorName(err),
            });
            continue;
        };

        symlinks += 1;
    }

    if (symlinks == 1) {
        logger.info("added one manpage", .{});
    } else if (symlinks > 1) {
        logger.info("added {d} manpages", .{symlinks});
    }
}

pub fn getConfDir(self: *Self, conf: []const u8) ?std.fs.Dir {
    const installationsDir = self.getDir(.installations) catch return null;

    return installationsDir.openDir(conf, .{}) catch null;
}

pub fn getConfVersionDir(
    self: *Self,
    conf: []const u8,
    version: []const u8,
    openOptions: std.fs.Dir.OpenOptions,
) ?std.fs.Dir {
    const path = std.fs.path.join(self.alloc, &[_][]const u8{
        conf,
        version,
    }) catch unreachable;
    defer self.alloc.free(path);

    const installationsDir = self.getDir(.installations) catch return null;
    return installationsDir.openDir(path, openOptions) catch null;
}

/// fails if symlink already exists
pub fn useAsDefault(self: *Self, conf: []const u8, version: []const u8, binPath: []const u8) !void {
    var confVersionDir = self.getConfVersionDir(conf, version, .{
        .iterate = true,
    }) orelse return error.NoInstallationFound;
    var binDir = confVersionDir;
    defer binDir.close();

    if (binPath.len != 0) {
        binDir = confVersionDir.openDir(binPath, .{ .iterate = true }) catch return error.NoBinDir;
        confVersionDir.close();
    }

    var symlinks: u16 = 0;

    const aliasesDir = try self.getDir(.aliases);

    var iter = binDir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        const filePath = try std.fs.path.join(self.alloc, &[_][]const u8{
            self.installationsDirPath,
            conf,
            version,
            binPath,
            entry.name,
        });
        defer self.alloc.free(filePath);

        if (isFileExecutable(entry.name, filePath)) {
            try aliasesDir.symLink(filePath, entry.name, .{});

            symlinks += 1;
        }
    }

    if (symlinks == 1) {
        logger.info("created one symlink", .{});
    } else if (symlinks > 1) {
        logger.info("created {d} symlinks", .{symlinks});
    }
}

fn getConfAndVersionFromPath(self: Self, path: []const u8) !struct { []const u8, []const u8 } {
    if (!std.mem.startsWith(u8, path, self.installationsDirPath)) {
        @branchHint(.unlikely);
        logger.err("{s} should be located under {s}", .{ path, self.installationsDirPath });
        return error.NotInInstallationsDir;
    }

    var confPathWithVersion = std.mem.splitScalar(
        u8,
        path[self.installationsDirPath.len..],
        std.fs.path.sep,
    );

    // skip leading slash
    _ = confPathWithVersion.next() orelse return error.CorruptPath;

    const confNameFromPath = confPathWithVersion.next() orelse {
        @branchHint(.cold);
        return error.CorruptPath;
    };

    const versionString = confPathWithVersion.next() orelse {
        @branchHint(.cold);
        return error.CorruptPath;
    };

    return .{ confNameFromPath, versionString };
}

/// pre-cleans aliases, so symlink always succeeds
/// returns picked versionString (caller owns memory) or `null` if didn't change version
pub fn useAsDefaultWithRange(
    self: *Self,
    conf: []const u8,
    range: std.SemanticVersion.Range,
    binPath: []const u8,
) !?[]const u8 {
    var installedVersions = try self.getConfInstallations(self.alloc, conf);
    defer {
        for (installedVersions.items) |item| item.deinit();
        installedVersions.deinit(self.alloc);
    }

    for (installedVersions.items) |item| {
        if (item.default and range.includesVersion(item.version)) {
            return null;
        }
    }

    var install: Install = undefined;
    for (installedVersions.items) |item| {
        if (range.includesVersion(item.version)) {
            install = item;
            break;
        }
    } else return error.NoMatchingVersionFound;

    var installDir = self.getConfVersionDir(conf, install.versionString, .{
        .iterate = true,
    }) orelse return error.NoInstallDir;
    var binDir = installDir;
    defer binDir.close();

    if (binPath.len != 0) {
        binDir = try installDir.openDir(binPath, .{ .iterate = true });
        installDir.close();
    }

    var pathBuf: [std.fs.max_path_bytes]u8 = undefined;
    var deletedCount: u16 = 0;

    const aliasesDir = try self.getDir(.aliases);
    var aliasesIter = aliasesDir.iterate();

    while (aliasesIter.next() catch null) |entry| {
        if (entry.kind != .sym_link) continue;

        const filePath = aliasesDir.readLink(entry.name, &pathBuf) catch {
            @branchHint(.unlikely);
            aliasesDir.deleteTree(entry.name) catch continue;
            deletedCount += 1;
            continue;
        };

        const confNameFromPath, const versionString = self.getConfAndVersionFromPath(filePath) catch continue;

        if (!std.mem.eql(u8, confNameFromPath, conf)) {
            continue;
        }

        const version = std.SemanticVersion.parse(versionString) catch {
            @branchHint(.cold);
            logger.err("failed parsing {s} version for {s} config installation", .{ versionString, entry.name });
            continue;
        };

        if (range.includesVersion(version)) {
            continue;
        }

        aliasesDir.deleteTree(entry.name) catch continue;
        deletedCount += 1;
    }

    if (deletedCount == 1) {
        logger.info("removed one symlink", .{});
    } else if (deletedCount > 1) {
        logger.info("removed {d} symlinks", .{deletedCount});
    }

    try self.useAsDefault(conf, install.versionString, binPath);

    return try self.alloc.dupe(u8, install.versionString);
}

pub fn removeDeadSymlinks(self: *Self) !void {
    var deletedCount: u16 = 0;

    var pathBuf: [std.fs.max_path_bytes]u8 = undefined;
    const aliasesDir = try self.getDir(.aliases);
    var iter = aliasesDir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .sym_link) continue;

        const link = aliasesDir.readLink(entry.name, &pathBuf) catch {
            @branchHint(.unlikely);
            aliasesDir.deleteTree(entry.name) catch continue;
            deletedCount += 1;
            continue;
        };

        if (isFileExecutable(entry.name, link)) {
            continue;
        }

        aliasesDir.deleteTree(entry.name) catch continue;
        deletedCount += 1;
    }

    if (deletedCount == 1) {
        logger.info("removed one symlink", .{});
    } else if (deletedCount > 1) {
        logger.info("removed {d} symlinks", .{deletedCount});
    }

    deletedCount = 0;

    const manDir = try self.getDir(.man);
    var manIter = try manDir.walk(self.alloc);
    defer manIter.deinit();

    while (manIter.next() catch null) |entry| {
        if (entry.kind != .sym_link) continue;

        if (manDir.readLink(entry.path, &pathBuf)) |_| {} else |_| {
            manDir.deleteTree(entry.path) catch continue;

            deletedCount += 1;
        }
    }

    if (deletedCount == 1) {
        logger.info("removed one man page", .{});
    } else if (deletedCount > 1) {
        logger.info("removed {d} man pages", .{deletedCount});
    }
}

pub const Install = struct {
    alloc: Alloc,

    versionString: []const u8,
    version: std.SemanticVersion,

    default: bool,

    pub fn init(alloc: Alloc, versionString: []const u8) !Install {
        const localVersionString = try alloc.dupe(u8, versionString);
        errdefer alloc.free(localVersionString);

        const version = try std.SemanticVersion.parse(localVersionString);

        return Install{
            .alloc = alloc,
            .version = version,
            .versionString = localVersionString,
            .default = false,
        };
    }

    pub fn deinit(self: Install) void {
        self.alloc.free(self.versionString);
    }

    pub fn lessThan(_: void, a: Install, b: Install) bool {
        return a.version.order(b.version) == .gt;
    }
};

pub fn getConfInstallations(self: *Self, alloc: std.mem.Allocator, conf: []const u8) !std.array_list.Aligned(Install, null) {
    var installed: std.array_list.Aligned(Install, null) = .empty;

    var confDir = self.getConfDir(conf) orelse return error.NoConfDir;
    defer confDir.close();

    var versionIter = confDir.iterate();
    while (versionIter.next() catch null) |versionEntry| {
        if (versionEntry.kind != .directory) continue;

        const install = Install.init(alloc, versionEntry.name) catch {
            logger.warn("failed creating install entry for {s} - {s}", .{ conf, versionEntry.name });
            continue;
        };

        try installed.append(alloc, install);
    }

    std.sort.pdq(Install, installed.items, {}, Install.lessThan);

    const aliasesDir = try self.getDir(.aliases);

    var pathBuf: [std.fs.max_path_bytes]u8 = undefined;
    var iter = aliasesDir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .sym_link) continue;

        const path = aliasesDir.readLink(entry.name, &pathBuf) catch continue;
        const confFromPath, const versionString = self.getConfAndVersionFromPath(path) catch continue;

        if (!std.mem.eql(u8, confFromPath, conf)) {
            continue;
        }

        for (installed.items) |*item| {
            if (std.mem.eql(u8, item.versionString, versionString) and isFileExecutable(entry.name, path)) {
                item.default = true;
                return installed;
            }
        }
    }

    return installed;
}

pub fn getInstalledConfs(self: *Self, alloc: Alloc) !std.array_list.Aligned([]const u8, null) {
    var installed: std.array_list.Aligned([]const u8, null) = .empty;

    const installationsDir = try self.getDir(.installations);

    var iter = installationsDir.iterate();
    while (iter.next() catch null) |item| {
        if (item.kind != .directory) continue;

        var confDir = installationsDir.openDir(item.name, .{ .iterate = true }) catch continue;
        defer confDir.close();

        var confIter = confDir.iterate();
        while (confIter.next() catch null) |entry| {
            if (entry.kind != .directory) continue;

            try installed.append(
                alloc,
                try alloc.dupe(u8, item.name),
            );

            break;
        }
    }

    return installed;
}

pub fn clearTmpdir(self: *Self) void {
    std.debug.assert(
        std.mem.endsWith(u8, self.tmpDirPath, consts.EXE_NAME),
    );

    const tmpDir = self.getDir(.tmp) catch |err| {
        @branchHint(.unlikely);
        logger.err("failed opening tmp dir with {s}", .{@errorName(err)});
        return;
    };
    var iter = tmpDir.iterate();

    var count: u16 = 0;
    while (iter.next() catch null) |item| {
        tmpDir.deleteTree(item.name) catch {
            logger.warn(
                "failed deleteing {f}",
                .{std.fs.path.fmtJoin(&[_][]const u8{ self.tmpDirPath, item.name })},
            );
            continue;
        };

        count += 1;
    }

    if (count > 0) {
        logger.info("removed {d} items", .{count});
    } else {
        logger.info("nothing to remove", .{});
    }
}

pub fn openOrMakeDir(path: []const u8, options: std.fs.Dir.OpenOptions) !std.fs.Dir {
    return std.fs.openDirAbsolute(path, options) catch |err| blk: switch (err) {
        error.FileNotFound => {
            std.fs.makeDirAbsolute(path) catch return error.UnableToCreateTmpDir;
            break :blk std.fs.openDirAbsolute(path, options) catch return error.UnableToOpenTmpDir;
        },
        else => return error.UnableToOpenTmpDir,
    };
}

pub fn prepareTmpDirForDecompression(self: *Self, conf: []const u8, version: std.SemanticVersion) !std.fs.Dir {
    var tmpDirNameBuf: [std.fs.max_name_bytes]u8 = undefined;
    const tmpDirName = std.fmt.bufPrint(&tmpDirNameBuf, "{s}-{f}", .{
        conf,
        version,
    }) catch unreachable;

    const tmpDir = try self.getDir(.tmp);
    return tmpDir.makeOpenPath(tmpDirName, .{ .access_sub_paths = true, .iterate = true });
}

pub fn getTmpDirname(alloc: Alloc) []const u8 {
    const isWindows = @import("builtin").os.tag == .windows;

    const env_vars = if (isWindows)
        &[_][]const u8{ "TEMP", "TMP" }
    else
        &[_][]const u8{"TMPDIR"};

    for (env_vars) |var_name| {
        if (std.process.getEnvVarOwned(alloc, var_name)) |path| {
            return path;
        } else |_| {}
    }

    const fallback = if (isWindows) "C:\\temp" else "/tmp";
    return alloc.dupe(u8, fallback) catch unreachable;
}

fn isFileExecutable(originalEntryName: []const u8, path: []const u8) bool {
    if (builtin.target.os.tag == .windows) {
        const extension = std.fs.path.extension(path);
        const executable_extensions = [_][]const u8{ ".exe", ".bat", ".cmd" };
        for (executable_extensions) |ext| {
            if (std.mem.eql(u8, extension, ext)) {
                return true;
            }
        }
        return false;
    }

    std.posix.access(path, std.posix.X_OK) catch return false;

    return std.fs.path.extension(originalEntryName).len == 0;
}
