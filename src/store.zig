const std = @import("std");
const consts = @import("./consts.zig");
const common = @import("./config/common.zig");

const Alloc = std.mem.Allocator;

const Self = @This();

const isWindows = @import("builtin").os.tag == .windows;

alloc: Alloc,

path: []const u8,

dir: std.fs.Dir,

pub fn init(alloc: Alloc) !Self {
    const homeDir = try getHomeDir(alloc);
    defer alloc.free(homeDir);

    const storeDirname = std.fmt.allocPrint(
        alloc,
        "{s}{c}.{s}",
        .{ homeDir, std.fs.path.sep, consts.EXE_NAME },
    ) catch unreachable;

    const dir = try openOrMakeDir(storeDirname, .{});

    return Self{
        .alloc = alloc,
        .path = storeDirname,
        .dir = dir,
    };
}

pub fn deinit(self: *Self) void {
    self.alloc.free(self.path);
    self.dir.close();
}

pub fn getSaveFile(self: Self, conf: []const u8, version: std.SemanticVersion) !std.fs.File {
    var pathBuf: [std.fs.max_path_bytes]u8 = undefined;

    const versionPath = std.fmt.bufPrint(
        &pathBuf,
        "{s}{c}{s}{c}{f}",
        .{ self.path, std.fs.path.sep, conf, std.fs.path.sep, version },
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

pub fn saveTargetFile(
    self: Self,
    conf: []const u8,
    target: common.DownloadTarget,
    targetFile: std.fs.File,
) !void {
    const saveFile = try self.getSaveFile(conf, target.version);
    defer saveFile.close();

    decompressFile(self.alloc, std.fs.path.extension(target.tarball), targetFile, saveFile) catch |err| switch (err) {
        error.UnknownCompression => {
            std.log.err("Unknown compression in: {s}", .{target.tarball});
            return;
        },
        else => return err,
    };
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

const Compression = enum { xz };

pub fn decompressFile(alloc: Alloc, inExt: []const u8, in: std.fs.File, out: std.fs.File) !void {
    const ext = if (inExt[0] == '.') inExt[1..] else inExt;
    const compression = std.meta.stringToEnum(Compression, ext) orelse return error.UnknownCompression;

    const inreaderBuf = try alloc.alloc(u8, 16 * 1024 * 1024);
    defer alloc.free(inreaderBuf);

    const inreader = in.reader(inreaderBuf);

    var inreaderInterface = inreader.interface;

    var decompressor = switch (compression) {
        .xz => try std.compress.xz.decompress(alloc, inreaderInterface.adaptToOldInterface()),
    };
    defer decompressor.deinit();

    const decompressedReader = decompressor.reader();

    const outwriterBuf = try alloc.alloc(u8, 16 * 1024 * 1024);
    defer alloc.free(outwriterBuf);

    var outwriter = out.writer(outwriterBuf);
    defer outwriter.interface.flush() catch unreachable;

    const decompressBuf = try alloc.alloc(u8, 16 * 1024 * 1024);
    defer alloc.free(decompressBuf);
    while (true) {
        const read = try decompressedReader.read(decompressBuf);
        if (read == 0) break;

        _ = try outwriter.interface.write(decompressBuf[0..read]);
    }
}

pub fn getHomeDir(alloc: Alloc) ![]const u8 {
    const var_name = if (isWindows) "USERPROFILE" else "HOME";
    return std.process.getEnvVarOwned(alloc, var_name) catch |err| switch (err) {
        error.InvalidWtf8, error.EnvironmentVariableNotFound => error.HomeDirNotFound,
        else => |e| return e,
    };
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
