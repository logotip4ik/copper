const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");

const configs = @import("./config/configs.zig");
const common = @import("./config/common.zig");

const Alloc = std.mem.Allocator;

const Self = @This();

const isWindows = @import("builtin").os.tag == .windows;

const logger = std.log.scoped(.store);

alloc: Alloc,

rootPath: []const u8,

aliasesDirPath: []const u8,

aliasesDir: std.fs.Dir,

tmpDirPath: []const u8,

tmpDir: std.fs.Dir,

installationsDirPath: []const u8,

installationsDir: std.fs.Dir,

pub fn init(alloc: Alloc) !Self {
    const storeDirname = try std.fs.getAppDataDir(alloc, consts.EXE_NAME);
    errdefer alloc.free(storeDirname);

    var root = try openOrMakeDir(storeDirname, .{});
    errdefer root.close();

    const tmpDirname = getTmpDirname(alloc);
    defer alloc.free(tmpDirname);

    const tmpDirPath = try std.fs.path.join(alloc, &[_][]const u8{
        tmpDirname,
        consts.EXE_NAME,
    });
    errdefer alloc.free(tmpDirPath);

    var tmpDir = try openOrMakeDir(tmpDirPath, .{ .iterate = true });
    errdefer tmpDir.close();

    var installationsDir = try root.makeOpenPath("installations", .{ .iterate = true });
    errdefer installationsDir.close();

    const installationsDirPath = try installationsDir.realpathAlloc(alloc, ".");
    errdefer alloc.free(installationsDirPath);

    var aliasesDir = try root.makeOpenPath("aliases", .{ .iterate = true });
    errdefer aliasesDir.close();

    const aliasesDirPath = try aliasesDir.realpathAlloc(alloc, ".");
    errdefer alloc.free(aliasesDirPath);

    return Self{
        .alloc = alloc,
        .rootPath = storeDirname,
        .aliasesDir = aliasesDir,
        .aliasesDirPath = aliasesDirPath,
        .tmpDir = tmpDir,
        .tmpDirPath = tmpDirPath,
        .installationsDir = installationsDir,
        .installationsDirPath = installationsDirPath,
    };
}

pub fn deinit(self: *Self) void {
    self.alloc.free(self.rootPath);

    self.aliasesDir.close();
    self.alloc.free(self.aliasesDirPath);

    self.alloc.free(self.tmpDirPath);
    self.tmpDir.close();

    self.installationsDir.close();
    self.alloc.free(self.installationsDirPath);
}

pub fn saveOutDir(
    self: Self,
    out: std.fs.Dir,
    confName: []const u8,
    version: []const u8,
) ![]const u8 {
    var confDir = self.getConfDir(confName);
    if (confDir) |*dir| {
        dir.close();
    } else {
        try self.installationsDir.makeDir(confName);
    }

    const absoluteTargetPath = std.fs.path.join(self.alloc, &[_][]const u8{
        self.installationsDirPath,
        confName,
        version,
    }) catch unreachable;
    errdefer self.alloc.free(absoluteTargetPath);

    var outBuf: [std.fs.max_path_bytes]u8 = undefined;
    const outPath = try out.realpath(".", &outBuf);

    logger.info("moving {s} to {s}", .{ outPath, absoluteTargetPath });

    try std.fs.renameAbsolute(outPath, absoluteTargetPath);

    return absoluteTargetPath;
}

pub fn getConfDir(self: Self, conf: []const u8) ?std.fs.Dir {
    return self.installationsDir.openDir(conf, .{}) catch null;
}

pub fn getConfVersionDir(
    self: Self,
    conf: []const u8,
    version: []const u8,
    openOptions: std.fs.Dir.OpenOptions,
) ?std.fs.Dir {
    const path = std.fs.path.join(self.alloc, &[_][]const u8{
        conf,
        version,
    }) catch unreachable;
    defer self.alloc.free(path);

    return self.installationsDir.openDir(path, openOptions) catch null;
}

/// fails if symlink already exists
pub fn useAsDefault(self: Self, conf: []const u8, version: []const u8, binPath: []const u8) !void {
    var confVersionDir = self.getConfVersionDir(conf, version, .{
        .iterate = true,
    }) orelse return error.NoInstallationFound;
    var binDir = confVersionDir;
    defer binDir.close();

    if (binPath.len != 0) {
        binDir = try confVersionDir.openDir(binPath, .{ .iterate = true });
        confVersionDir.close();
    }

    var symlinks: u16 = 0;
    var pathBuf: [std.fs.max_path_bytes]u8 = undefined;

    var iter = binDir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        const filePath = binDir.realpath(entry.name, &pathBuf) catch unreachable;

        if (isFileExecutable(filePath)) {
            try self.aliasesDir.symLink(filePath, entry.name, .{});

            symlinks += 1;
        }
    }

    if (symlinks == 1) {
        logger.info("created one symlink", .{});
    } else if (symlinks > 1) {
        logger.info("created {d} symlinks", .{symlinks});
    }
}

/// pre-cleans aliases, so symlink always succeeds
/// returns picked versionString, caller owns memory
pub fn useAsDefaultWithRange(
    self: Self,
    conf: []const u8,
    range: std.SemanticVersion.Range,
    binPath: []const u8,
) ![]const u8 {
    const installations = try self.getConfInstallations(conf);
    defer {
        for (installations.items) |item| item.deinit();
        installations.deinit();
    }

    var install: Install = undefined;
    for (installations.items) |item| {
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

    var iter = binDir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        const filePath = binDir.realpath(entry.name, &pathBuf) catch unreachable;

        if (!isFileExecutable(filePath)) {
            continue;
        }

        self.aliasesDir.deleteTree(entry.name) catch continue;

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

pub fn removeDeadSymlinks(self: Self) void {
    var deletedCount: u16 = 0;

    var pathBuf: [std.fs.max_path_bytes]u8 = undefined;
    var iter = self.aliasesDir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .sym_link) continue;

        if (self.aliasesDir.realpath(entry.name, &pathBuf)) |_| {} else |_| {
            // failed getting real path, so means broken...

            self.aliasesDir.deleteTree(entry.name) catch continue;

            deletedCount += 1;
        }
    }

    if (deletedCount == 1) {
        logger.info("removed one symlink", .{});
    } else if (deletedCount > 1) {
        logger.info("removed {d} symlinks", .{deletedCount});
    }
}

pub const Install = struct {
    alloc: std.mem.Allocator,

    versionString: []const u8,
    version: std.SemanticVersion,

    default: bool,

    pub fn init(alloc: std.mem.Allocator, versionString: []const u8) !Install {
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
};

pub fn getConfInstallations(self: Self, conf: []const u8) !std.array_list.Managed(Install) {
    var installed: std.array_list.Managed(Install) = .init(self.alloc);

    var confDir = self.getConfDir(conf) orelse {
        logger.warn("failed opening {s} config", .{conf});
        return error.NoConfDir;
    };
    defer confDir.close();

    var versionIter = confDir.iterate();
    while (versionIter.next() catch null) |versionEntry| {
        if (versionEntry.kind != .directory) continue;

        const install = Install.init(self.alloc, versionEntry.name) catch {
            logger.warn("failed creating install entry for {s} - {s}", .{ conf, versionEntry.name });
            continue;
        };

        try installed.append(install);
    }

    std.sort.heap(Install, installed.items, {}, common.compareVersionField(Install));

    var pathBuf: [std.fs.max_path_bytes]u8 = undefined;
    var iter = self.aliasesDir.iterate();
    while (iter.next() catch null) |entry| outer: {
        if (entry.kind != .sym_link) continue;

        const path = self.aliasesDir.realpath(entry.name, &pathBuf) catch continue;

        if (!std.mem.startsWith(u8, path, self.installationsDirPath)) {
            logger.err("{s} must be installed in {s}", .{ path, self.installationsDirPath });
            continue;
        }

        const confVersionChunk = path[self.installationsDirPath.len + 1 ..];
        var chunks = std.mem.splitScalar(u8, confVersionChunk, std.fs.path.sep);

        const confFromPath = chunks.next() orelse {
            logger.err("invalid installtion path for {s}", .{path});
            continue;
        };
        const versionString = chunks.next() orelse {
            logger.err("invalid installtion path for {s}", .{path});
            continue;
        };

        if (!std.mem.eql(u8, confFromPath, conf)) {
            continue;
        }

        for (installed.items) |*item| {
            if (std.mem.eql(u8, item.versionString, versionString)) {
                item.default = true;
                break :outer;
            }
        }
    }

    return installed;
}

pub fn getInstalledConfs(self: Self) !std.array_list.Managed([]const u8) {
    var installed: std.array_list.Managed([]const u8) = .init(self.alloc);

    var iter = self.installationsDir.iterate();
    while (iter.next() catch null) |item| {
        if (item.kind != .directory) continue;

        try installed.append(
            try self.alloc.dupe(u8, item.name),
        );
    }

    return installed;
}

pub fn clearTmpdir(self: Self) void {
    var iter = self.tmpDir.iterate();

    var count: u16 = 0;
    while (iter.next() catch null) |item| {
        self.tmpDir.deleteTree(item.name) catch {
            logger.warn(
                "failed deleteing {f}",
                .{std.fs.path.fmtJoin(&[_][]const u8{ self.tmpDirPath, item.name })},
            );
            continue;
        };

        count += 1;
    }

    logger.info("removed {d} items", .{count});
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

pub fn prepareTmpDirForDecompression(self: Self, conf: []const u8, version: std.SemanticVersion) !std.fs.Dir {
    var tmpDirNameBuf: [std.fs.max_name_bytes]u8 = undefined;
    const tmpDirName = std.fmt.bufPrint(&tmpDirNameBuf, "{s}-{f}", .{
        conf,
        version,
    }) catch unreachable;

    return self.tmpDir.makeOpenPath(tmpDirName, .{ .access_sub_paths = true, .iterate = true });
}

pub fn getTmpDirname(alloc: std.mem.Allocator) []const u8 {
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

pub fn computeShasum(file: *const std.fs.File, buffer: []u8) ![std.crypto.hash.sha2.Sha256.digest_length * 2]u8 {
    var sha256: std.crypto.hash.sha2.Sha256 = .init(.{});

    while (true) {
        const read = try file.read(buffer);
        if (read == 0) break;

        sha256.update(buffer[0..read]);
    }

    try file.seekTo(0);
    return std.fmt.bytesToHex(sha256.finalResult(), .lower);
}

pub fn verifyShasum(alloc: Alloc, targetFile: *const std.fs.File, expected: []const u8) !bool {
    const shaBuf = try alloc.alloc(u8, 64 * 1024 * 1024);
    defer alloc.free(shaBuf);

    const shasum = try computeShasum(targetFile, shaBuf);

    return std.mem.eql(u8, &shasum, expected);
}

fn isFileExecutable(path: []const u8) bool {
    if (builtin.target.os.tag == .windows) {
        const extension = std.fs.path.extension(path);
        const executable_extensions = [_][]const u8{ ".exe", ".bat", ".cmd" };
        for (executable_extensions) |ext| {
            if (std.mem.eql(extension, ext)) {
                return true;
            }
        }
        return false;
    }

    std.posix.access(path, std.posix.X_OK) catch return false;

    return true;
}

test "correct tmp dir" {
    const testing = std.testing;

    var store = try Self.init(testing.allocator);
    defer store.deinit();

    try testing.expect(
        std.mem.endsWith(u8, store.tmpDirPath, consts.EXE_NAME),
    );
}
