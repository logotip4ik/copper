const std = @import("std");
const consts = @import("./consts.zig");
const common = @import("./config/common.zig");

const Alloc = std.mem.Allocator;

const Self = @This();

const isWindows = @import("builtin").os.tag == .windows;

alloc: Alloc,

dirPath: []const u8,

dir: std.fs.Dir,

tmpDirPath: []const u8,

tmpDir: std.fs.Dir,

pub fn init(alloc: Alloc) !Self {
    const storeDirname = try std.fs.getAppDataDir(alloc, consts.EXE_NAME);

    std.log.info("making store at {s}", .{storeDirname});

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

pub fn getSaveFile(self: Self, conf: []const u8, version: std.SemanticVersion) !std.fs.File {
    var pathBuf: [std.fs.max_path_bytes]u8 = undefined;

    const versionPath = std.fmt.bufPrint(
        &pathBuf,
        "{s}{c}{s}{c}{f}",
        .{ self.dirPath, std.fs.path.sep, conf, std.fs.path.sep, version },
    ) catch unreachable;

    std.log.info("making store file at {s}", .{versionPath});

    var versionDir = try self.dir.makeOpenPath(versionPath, .{});
    defer versionDir.close();

    const saveFileName = if (isWindows) "default.exe" else "default";
    const saveFile = versionDir.openFile(saveFileName, .{ .mode = .read_write }) catch |err| blk: switch (err) {
        error.FileNotFound => {
            const file = try versionDir.createFile(saveFileName, .{});
            file.close();

            break :blk try versionDir.openFile(saveFileName, .{ .mode = .read_write });
        },
        else => return err,
    };

    return saveFile;
}

pub fn saveOutDir(
    self: Self,
    out: std.fs.Dir,
    confName: []const u8,
    version: []const u8,
) ![]u8 {
    const absoluteTargetPath = std.fs.path.join(self.alloc, &[_][]const u8{
        self.dirPath,
        confName,
        version,
    }) catch unreachable;

    const outPath = try out.realpathAlloc(self.alloc, ".");
    defer self.alloc.free(outPath);

    std.log.info("moving {s} to {s}", .{outPath, absoluteTargetPath});

    try std.fs.renameAbsolute(outPath, absoluteTargetPath);

    return absoluteTargetPath;
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

const Compression = enum { xz };

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
