const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.@"tree-sitter");

const GITHUB_API_URL = "https://api.github.com/repos/tree-sitter/tree-sitter/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "tree-sitter",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = decompressTargetFile,
};

fn matchingAsset(name: []const u8) bool {
    const targetFilename = comptime getTargetPrefix();

    return std.mem.endsWith(u8, name, targetFilename orelse return false);
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    compression: compress.Compression,
    targetFile: std.Io.File,
    tmpDir: std.Io.Dir,
) DecompressError!std.Io.Dir {
    const exeName = if (builtin.target.os.tag == .windows) "tree-sitter.exe" else "tree-sitter";

    const outputFile = tmpDir.createFile(io, exeName, .{}) catch |err| {
        @branchHint(.unlikely);
        logger.err("failed opening output file {s} with {s}", .{ exeName, @errorName(err) });
        return DecompressError.FailedCreatingCopyFile;
    };
    defer outputFile.close(io);

    var writerBuf: [64 * 1024]u8 = undefined;
    var outputWriter = outputFile.writer(io, &writerBuf);
    defer outputWriter.interface.flush() catch {
        @branchHint(.unlikely);
        logger.err("failed flushing output file buffer", .{});
    };

    switch (compression) {
        .gz => try compress.decompressGzFile(alloc, io, targetFile, &outputWriter.interface),
        else => unreachable,
    }

    if (builtin.target.os.tag != .windows) {
        outputFile.setPermissions(io, .executable_file) catch {
            @branchHint(.unlikely);
            logger.err("failed changing mod for {s}", .{exeName});
            tmpDir.deleteTree(io, exeName) catch {};
            return error.FailedUnzipping;
        };
    }

    return tmpDir;
}

fn getTargetPrefix() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x64",
        .x86 => "x86",
        .powerpc64 => "powerpc64",
        .aarch64 => "arm64",
        .arm => "arm",
        else => return null,
    };

    const extension = "gz";

    return std.fmt.comptimePrint("{s}-{s}.{s}", .{ os, arch, extension });
}
