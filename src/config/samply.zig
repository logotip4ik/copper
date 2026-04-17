const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.samply);

const GITHUB_API_URL = "https://api.github.com/repos/mstange/samply/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "samply",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = stripSamplyPrefix,
    }),
    .decompressTargetFile = decompressTargetFile,
    .verifyTargetFile = verifyTargetFile,
};

const VerifyTargetFileError = common.VerifyTargetFileError;
fn verifyTargetFile(
    ctx: common.VerifyTargetFileContext,
    targetFile: *std.fs.File,
    downloadTarget: *const DownloadTarget,
) common.VerifyTargetFileError!?bool {
    var stream: std.Io.Writer.Allocating = .init(ctx.alloc);
    defer stream.deinit();

    ctx.progress.setEstimatedTotalItems(1);

    const shasumTxtUrl = try std.fmt.allocPrint(ctx.alloc, "{s}.sha256", .{
        downloadTarget.tarball orelse {
            logger.warn("expected {s} {s} to have prebuilt tarball url", .{
                interface.name,
                downloadTarget.versionString,
            });
            return null;
        },
    });
    defer ctx.alloc.free(shasumTxtUrl);

    const shasumRes = ctx.client.fetch(.{
        .method = .GET,
        .location = .{ .url = shasumTxtUrl },
        .headers = consts.DEFAULT_HEADERS,
        .keep_alive = false,
        .response_writer = &stream.writer,
    }) catch return VerifyTargetFileError.FailedFetching;

    ctx.progress.completeOne();

    const written = stream.written();
    if (shasumRes.status != .ok or written.len == 0) {
        logger.err("{s} failed with: {s} code, content length: {d}", .{
            shasumTxtUrl,
            @tagName(shasumRes.status),
            written.len,
        });
        return VerifyTargetFileError.FailedFetching;
    }

    const firstSpace = std.mem.indexOfScalar(u8, written, ' ') orelse {
        logger.warn("downloaded {s}, but no shasum where found", .{shasumTxtUrl});
        return null;
    };
    const shasum = written[0..firstSpace];

    var fileReaderBuf: [std.heap.page_size_max]u8 = undefined;
    var fileReader = targetFile.reader(&fileReaderBuf);

    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});

    while (true) {
        const chunk = fileReader.interface.take(fileReaderBuf.len) catch |err| switch (err) {
            error.EndOfStream => {
                hasher.update(fileReader.interface.buffered());
                break;
            },
            else => unreachable,
        };

        hasher.update(chunk);
    }

    const finalResult = hasher.finalResult();
    const result = std.fmt.bytesToHex(finalResult, .lower);

    return std.mem.eql(u8, shasum[0..32], result[0..32]);
}

const DownloadTarget = common.DownloadTarget;

fn stripSamplyPrefix(alloc: std.mem.Allocator, version: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, version, "samply-v")) {
        return alloc.dupe(u8, version["samply-v".len..]) catch null;
    }

    return null;
}

fn matchingAsset(name: []const u8) bool {
    const targetFilename = comptime getTargetPrefix();

    return std.mem.endsWith(u8, name, targetFilename orelse return false);
}

const DownloadTargets = common.DownloadTargets;
const DownloadTargetError = common.DownloadTargetError;
fn fetchVersions(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    progress: std.Progress.Node,
) DownloadTargetError!DownloadTargets {
    return try common.fetchGithubReleases(
        alloc,
        logger,
        progress,
        client,
        GITHUB_API_URL,
        stripSamplyPrefix,
        matchingAsset,
    );
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: compress.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    if (common.openFirstDirWithLog(tmpDir, logger, "using already decompressed {s}") catch null) |dir| {
        return dir;
    }

    switch (compression) {
        .xz => try compress.decompressXzDir(alloc, targetFile, tmpDir),
        .zip => try compress.decompressZipDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    const dir = common.openFirstDirWithLog(tmpDir, logger, "decompressed {s}") catch return DecompressError.FailedUnzipping;
    return dir orelse DecompressError.FailedUnzipping;
}

fn getTargetPrefix() ?[]const u8 {
    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "aarch64",
        else => return null,
    };

    const os = switch (builtin.target.os.tag) {
        .linux => "unknown-linux-gnu",
        .macos => "apple-darwin",
        .windows => "pc-windows-msvc",
        else => return null,
    };

    const extension = if (builtin.target.os.tag == .windows) "zip" else "tar.xz";

    return std.fmt.comptimePrint("{s}-{s}.{s}", .{ arch, os, extension });
}
