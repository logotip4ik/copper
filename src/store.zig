const std = @import("std");
const configs = @import("./config/configs.zig");
const consts = @import("./consts.zig");
const common = @import("./config/common.zig");

const Alloc = std.mem.Allocator;

const Self = @This();

const isWindows = @import("builtin").os.tag == .windows;

const logger = std.log.scoped(.store);

pub const defaultUseFolderName = "default";

alloc: Alloc,

dirPath: []const u8,

dir: std.fs.Dir,

tmpDirPath: []const u8,

tmpDir: std.fs.Dir,

pub fn init(alloc: Alloc) !Self {
    const storeDirname = try std.fs.getAppDataDir(alloc, consts.EXE_NAME);
    errdefer alloc.free(storeDirname);

    var dir = try openOrMakeDir(storeDirname, .{});
    errdefer dir.close();

    const tmpDir = getTmpDirname(alloc);
    defer alloc.free(tmpDir);

    const tmpDirPath = std.fs.path.join(
        alloc,
        &[_][]const u8{ tmpDir, consts.EXE_NAME },
    ) catch unreachable;
    errdefer alloc.free(tmpDirPath);

    return Self{
        .alloc = alloc,
        .dir = dir,
        .dirPath = storeDirname,
        .tmpDir = try openOrMakeDir(tmpDirPath, .{}),
        .tmpDirPath = tmpDirPath,
    };
}

pub fn deinit(self: *Self) void {
    self.alloc.free(self.dirPath);
    self.dir.close();
    self.alloc.free(self.tmpDirPath);
    self.tmpDir.close();
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
        try self.dir.makeDir(confName);
        logger.warn("shell refresh may be needed start using {s}", .{confName});
    }

    const absoluteTargetPath = std.fs.path.join(self.alloc, &[_][]const u8{
        self.dirPath,
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
    return self.dir.openDir(conf, .{}) catch null;
}

pub fn getConfVersionDir(self: Self, conf: []const u8, version: []const u8) ?std.fs.Dir {
    const path = std.fs.path.join(self.alloc, &[_][]const u8{
        conf,
        version,
    }) catch unreachable;
    defer self.alloc.free(path);

    return self.dir.openDir(path, .{}) catch null;
}

pub fn useAsDefault(self: Self, conf: []const u8, version: []const u8) !void {
    var confDir = self.getConfDir(conf) orelse return error.NoConfDirFound;
    defer confDir.close();

    var versionDir = confDir.openDir(version, .{}) catch return error.NoVersionDir;
    defer versionDir.close();

    confDir.deleteTree(defaultUseFolderName) catch {};

    try confDir.symLink(version, defaultUseFolderName, .{ .is_directory = true });

    logger.info("using {s} as default for {s}", .{ version, conf });
}

pub fn useAsDefaultWithRange(self: Self, conf: []const u8, range: std.SemanticVersion.Range) !void {
    var confDir = self.getConfDir(conf) orelse return error.NoConfDirFound;
    defer confDir.close();

    const VersionWithString = struct { string: []const u8, version: std.SemanticVersion };
    var versions: std.array_list.Aligned(VersionWithString, null) = .empty;
    defer {
        for (versions.items) |item| self.alloc.free(item.string);
        versions.deinit(self.alloc);
    }

    var versionIter = confDir.iterate();
    while (versionIter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        const version = std.SemanticVersion.parse(entry.name) catch {
            logger.warn("broken version {s} in {s}", .{ entry.name, conf });
            continue;
        };

        try versions.append(self.alloc, .{
            .string = try self.alloc.dupe(u8, entry.name),
            .version = version,
        });
    }

    std.sort.heap(VersionWithString, versions.items, {}, common.compareVersionField(VersionWithString));

    for (versions.items) |item| {
        if (range.includesVersion(item.version)) {
            var versionDir = confDir.openDir(item.string, .{}) catch unreachable;
            defer versionDir.close();

            confDir.deleteTree(defaultUseFolderName) catch {};

            try confDir.symLink(item.string, defaultUseFolderName, .{ .is_directory = true });

            logger.info("using {s} as default for {s}", .{ item.string, conf });

            return;
        }
    }

    return error.NoMatchingVersionFound;
}

const Install = struct {
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

    var confDir = self.dir.openDir(conf, .{}) catch {
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

    var defaultInstallDir: ?std.fs.Dir = confDir.openDir(defaultUseFolderName, .{}) catch null;
    if (defaultInstallDir) |*defaultDir| blk: {
        defer defaultDir.close();

        var defaultPathBuff: [std.fs.max_path_bytes]u8 = undefined;
        const defaultPathAbs = defaultDir.realpath(".", &defaultPathBuff) catch {
            logger.warn("failed constructing path for default {s} insatll", .{conf});
            break :blk;
        };

        const version = std.fs.path.basename(defaultPathAbs);
        for (installed.items) |*item| {
            if (std.mem.eql(u8, item.versionString, version)) {
                item.default = true;
                break;
            }
        }
    }

    return installed;
}

/// returns absolute paths to aliases
pub fn getInstalledConfs(self: Self) !std.array_list.Managed([]const u8) {
    var installed: std.array_list.Managed([]const u8) = .init(self.alloc);

    var iter = self.dir.iterate();
    while (iter.next() catch null) |item| {
        if (item.kind != .directory) continue;

        var confDir = self.dir.openDir(item.name, .{}) catch continue;
        defer confDir.close();

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
