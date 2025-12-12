const std = @import("std");

const logger = std.log.scoped(.compress);

pub const Compression = enum {
    xz,
    gz,
    zip,
    tgz,
    uncompressed,
};

const DecompressError = error {
    FailedUnzipping,
    FailedCreatingDecompressor
};

pub fn decompressZipDir(
    alloc: std.mem.Allocator,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!void {
    _ = alloc;

    var fileBuf: [64 * 1024]u8 = undefined;
    var fileReader = targetFile.reader(&fileBuf);

    std.zip.extract(tmpDir, &fileReader, .{}) catch |err| {
        @branchHint(.unlikely);
        logger.err("failed unzipping with {s}", .{@errorName(err)});
        return error.FailedUnzipping;
    };
}

pub fn decompressTgzDir(
    alloc: std.mem.Allocator,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!void {
    _ = alloc;

    comptime std.debug.assert(std.compress.flate.max_window_len <= 64 * 1024);

    var fileBuf: [std.compress.flate.max_window_len]u8 = undefined;
    var fileReader = targetFile.reader(&fileBuf);

    var decompressBuf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&fileReader.interface, .gzip, &decompressBuf);

    std.tar.pipeToFileSystem(tmpDir, &decompress.reader, .{
        .mode_mode = .executable_bit_only,
    }) catch |err| {
        @branchHint(.unlikely);
        logger.err("failed decompressing with {s}", .{@errorName(err)});
        return error.FailedUnzipping;
    };
}

pub fn decompressGzDir(
    alloc: std.mem.Allocator,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!void {
    _ = alloc;

    comptime std.debug.assert(std.compress.flate.max_window_len <= 64 * 1024);

    var fileBuf: [std.compress.flate.max_window_len]u8 = undefined;
    var fileReader = targetFile.reader(&fileBuf);

    var decompressBuf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressed: std.compress.flate.Decompress = .init(&fileReader.interface, .gzip, &decompressBuf);

    std.tar.pipeToFileSystem(tmpDir, &decompressed.reader, .{
        .mode_mode = .executable_bit_only,
    }) catch |err| {
        @branchHint(.unlikely);
        logger.err("failed decompressing with {s}", .{@errorName(err)});
        return error.FailedUnzipping;
    };
}

pub fn decompressGzFile(
    alloc: std.mem.Allocator,
    targetFile: std.fs.File,
    output: *std.Io.Writer,
) DecompressError!void {
    _ = alloc;

    comptime std.debug.assert(std.compress.flate.max_window_len <= 64 * 1024);

    var fileBuf: [std.compress.flate.max_window_len]u8 = undefined;
    var fileReader = targetFile.reader(&fileBuf);

    var decompressBuf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressed: std.compress.flate.Decompress = .init(&fileReader.interface, .gzip, &decompressBuf);

    _ = decompressed.reader.streamRemaining(output) catch |err| {
        @branchHint(.unlikely);
        logger.err("failed decompressing into output writer with {s}", .{@errorName(err)});
        return DecompressError.FailedUnzipping;
    };
}

pub fn decompressXzDir(
    alloc: std.mem.Allocator,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!void {
    var fileBuf: [64 * 1024]u8 = undefined;
    var fileReader = targetFile.reader(&fileBuf);
    var reader = &fileReader.interface;

    var decompressed = std.compress.xz.decompress(alloc, reader.adaptToOldInterface()) catch return error.FailedCreatingDecompressor;
    defer decompressed.deinit();

    var decompressedReader = decompressed.reader();

    var outwriterBuf: [64 * 1024]u8 = undefined;
    var newreader = decompressedReader.adaptToNewApi(&outwriterBuf);

    std.tar.pipeToFileSystem(tmpDir, &newreader.new_interface, .{
        .mode_mode = .executable_bit_only,
    }) catch |err| {
        @branchHint(.unlikely);
        logger.err("failed decompressing with {s}", .{@errorName(err)});
        return error.FailedUnzipping;
    };
}

