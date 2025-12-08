const std = @import("std");

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

    var iter = tmpDir.iterate();
    while (iter.next() catch null) |entry| {
        tmpDir.deleteTree(entry.name) catch {};
    }

    std.zip.extract(tmpDir, &fileReader, .{}) catch return error.FailedUnzipping;
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
    }) catch return error.FailedUnzipping;
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

    var iter = tmpDir.iterate();
    while (iter.next() catch null) |entry| {
        tmpDir.deleteTree(entry.name) catch {};
    }

    std.tar.pipeToFileSystem(tmpDir, &decompressed.reader, .{
        .mode_mode = .executable_bit_only,
    }) catch return error.FailedUnzipping;
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

    var iter = tmpDir.iterate();
    while (iter.next() catch null) |entry| {
        tmpDir.deleteTree(entry.name) catch {};
    }

    std.tar.pipeToFileSystem(tmpDir, &newreader.new_interface, .{
        .mode_mode = .executable_bit_only,
    }) catch return error.FailedUnzipping;
}

