const std = @import("std");
const consts = @import("./consts.zig");
const common = @import("./config/common.zig");

const Alloc = std.mem.Allocator;

const Self = @This();

const isWindows = @import("builtin").os.tag == .windows;

const logger = std.log.scoped(.store);

alloc: Alloc,

dirPath: []const u8,

dir: std.fs.Dir,

tmpDirPath: []const u8,

tmpDir: std.fs.Dir,

pub fn init(alloc: Alloc) !Self {
    const storeDirname = try std.fs.getAppDataDir(alloc, consts.EXE_NAME);

    const dir = try openOrMakeDir(storeDirname, .{});

    const tmpDir = getTmpDirname(alloc);
    defer alloc.free(tmpDir);

    const tmpDirPath = std.fs.path.join(
        alloc,
        &[_][]const u8{ tmpDir, consts.EXE_NAME },
    ) catch unreachable;

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
    const absoluteTargetPath = std.fs.path.join(self.alloc, &[_][]const u8{
        self.dirPath,
        confName,
        version,
    }) catch unreachable;

    const outPath = try out.realpathAlloc(self.alloc, ".");
    defer self.alloc.free(outPath);

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

pub fn useAsDefault(self: Self, path: []const u8) !void {
    std.debug.assert(std.mem.startsWith(u8, path, self.dirPath));

    // + 1 to skip leading slash
    const confAndVersion = path[self.dirPath.len + 1 ..];

    var chunkIter = std.mem.splitScalar(u8, confAndVersion, '/');

    const conf = chunkIter.next().?;
    const version = chunkIter.next().?;

    const confDir = self.getConfDir(conf) orelse return error.NoConfDirFound;

    confDir.deleteTree("default") catch {};

    try confDir.symLink(version, "default", .{ .is_directory = true });
}

/// returns absolute paths to aliases
pub fn getInstalledConfs(self: Self) !std.array_list.Aligned([]const u8, null) {
    var installed: std.array_list.Aligned([]const u8, null) = .empty;

    var iter = self.dir.iterate();
    while (iter.next() catch null) |item| {
        if (item.kind != .directory) continue;

        var confDir = self.dir.openDir(item.name, .{}) catch continue;
        defer confDir.close();

        var confIter = confDir.iterate();
        while (confIter.next() catch null) |confItem| {
            if (confItem.kind == .sym_link) {
                try installed.append(
                    self.alloc,
                    try std.fs.path.join(self.alloc, &[_][]const u8{self.dirPath, item.name, confItem.name}),
                );
            }
        }

        try installed.append(self.alloc, try self.alloc.dupe(u8, item.name));
    }

    return installed;
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
