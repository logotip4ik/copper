const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.btop);

pub const interface: common.ConfInterface = .{
    .name = "btop",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = common.stripV,
    }),
    .decompressTargetFile = common.decompressFirstDir,
    .buildTarget = buildTarget,
};

const GITHUB_API_URL = "https://api.github.com/repos/aristocratos/btop/releases/latest";

fn matchingAsset(name: []const u8) bool {
    const prefix = comptime getTargetPrefix();

    return std.mem.endsWith(u8, name, prefix orelse return false);
}

const BuildFromSourceError = common.BuildFromSourceError;
fn buildTarget(
    alloc: std.mem.Allocator,
    io: std.Io,
    _: *const std.process.Environ.Map,
    progress: std.Progress.Node,
    sourceDir: std.Io.Dir,
    _: common.BuildTargetContext,
) BuildFromSourceError!std.Io.Dir {
    progress.setEstimatedTotalItems(1);
    defer progress.completeOne();

    logger.info("checking if make is installed", .{});
    const isMakeInstalled = common.isMakeInstalled(alloc, io);
    if (!isMakeInstalled) {
        logger.info("please install make before proceeding", .{});
        return BuildFromSourceError.DepsNotInstalled;
    }

    common.run(alloc, io, &.{
        "make",
        "ADDFLAGS=-march=native",
        "QUIET=true",
        "STRIP=true",
    }, .{ .cwdDir = sourceDir }) catch |err| {
        logger.err("failed building with {s}", .{@errorName(err)});
        return BuildFromSourceError.FailedBuilding;
    };

    return sourceDir.openDir(io, "bin", .{}) catch BuildFromSourceError.FailedBuilding;
}

fn getTargetPrefix() ?[]const u8 {
    const arch = switch (builtin.target.cpu.arch) {
        .aarch64 => "aarch64",
        .x86 => "i686",
        .mips64 => "mips64",
        .powerpc64 => "powerpc64",
        .x86_64 => "x86_64",
        else => return null,
    };

    const os = switch (builtin.target.os.tag) {
        .linux => "linux-musl",
        else => return null,
    };

    return std.fmt.comptimePrint("btop-{s}-{s}.tbz", .{ arch, os });
}
