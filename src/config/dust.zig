const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.dust);

const GITHUB_API_URL = "https://api.github.com/repos/bootandy/dust/releases/latest";

pub const interface: common.ConfInterface = .{
    .type = .Package,
    .name = "dust",

    .getDownloadTargets = fetchVersions,
    .decompressTargetFile = decompressTargetFile,

    .buildDeps = &.{"rust"},
    .buildTarget = buildTarget,
};

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
    return common.fetchGithubReleases(
        alloc,
        logger,
        progress,
        client,
        GITHUB_API_URL,
        common.stripV,
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
        .gz => try compress.decompressGzDir(alloc, targetFile, tmpDir),
        .zip => try compress.decompressZipDir(alloc, targetFile, tmpDir),
        else => unreachable,
    }

    const dir = common.openFirstDirWithLog(tmpDir, logger, "decompressed {s}") catch return error.FailedUnzipping;
    return dir orelse error.FailedUnzipping;
}

fn getTargetPrefix() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "apple-darwin",
        .linux => "unknown-linux-gnu",
        .windows => "pc-windows-msvc",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86 => "i686",
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };

    const ext = if (builtin.target.os.tag == .windows) "zip" else "tar.gz";

    return std.fmt.comptimePrint("{s}-{s}.{s}", .{ arch, os, ext });
}

const BuildFromSourceError = common.BuildFromSourceError;
fn buildTarget(
    alloc: std.mem.Allocator,
    progress: std.Progress.Node,
    sourceDir: std.fs.Dir,
    context: common.BuildTargetContext,
) BuildFromSourceError!std.fs.Dir {
    progress.setEstimatedTotalItems(6);

    sourceDir.makeDir(".cargo_home") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            logger.err("failed creating .cargo_home dir with {s}", .{@errorName(err)});
            return BuildFromSourceError.FailedBuilding;
        },
    };
    sourceDir.makeDir(".cargo") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            logger.err("failed creating .cargo dir with {s}", .{@errorName(err)});
            return BuildFromSourceError.FailedBuilding;
        },
    };
    progress.completeOne();

    var envMap = std.process.getEnvMap(alloc) catch |err| {
        logger.err("failed getting current env map with {s}", .{@errorName(err)});
        return BuildFromSourceError.FailedBuilding;
    };
    defer envMap.deinit();

    // reused multiple times
    var pathBuf: [std.fs.max_path_bytes]u8 = undefined;

    const cargoHomeDirpath = sourceDir.realpath(".cargo_home", &pathBuf) catch |err| {
        logger.err("failed reading realpath of .cargo_home folder with {s}", .{@errorName(err)});
        return BuildFromSourceError.FailedBuilding;
    };
    try envMap.put("CARGO_HOME", cargoHomeDirpath);

    const sourceDirPath = sourceDir.realpath(".", &pathBuf) catch |err| {
        logger.err("failed resolving realpath for source dir with {s}", .{@errorName(err)});
        return BuildFromSourceError.FailedBuilding;
    };
    try envMap.put("CWD", sourceDirPath);
    try envMap.put("PWD", sourceDirPath);

    var paths: std.array_list.Aligned([]const u8, null) = try .initCapacity(alloc, context.depsBinDirs.size);
    defer paths.deinit(alloc);

    var binsIter = context.depsBinDirs.valueIterator();
    while (binsIter.next()) |entry| paths.appendAssumeCapacity(entry.*);

    if (paths.items.len > 0) {
        const joinedPath = try std.mem.join(alloc, &.{std.fs.path.delimiter}, paths.items);
        defer alloc.free(joinedPath);

        if (envMap.get("PATH")) |currentPath| {
            const expandedPath = try std.mem.join(alloc, &.{std.fs.path.delimiter}, &.{ joinedPath, currentPath });
            defer alloc.free(expandedPath);

            try envMap.put("PATH", expandedPath);
        } else {
            try envMap.put("PATH", joinedPath);
        }
    }
    progress.completeOne();

    const cargo = if (context.depsBinDirs.get("rust")) |rustBinDirPath|
        std.fmt.bufPrint(&pathBuf, "{s}{c}{s}", .{
            withoutTrailingChar(rustBinDirPath, std.fs.path.sep),
            std.fs.path.sep,
            "cargo",
        }) catch unreachable
    else
        "cargo"; // no rust in deps bin dirs means we already have rust installed

    const runOptions: common.RunOptions = .{
        .cwdDir = sourceDir,
        .envMap = &envMap,
        .stderrBehaivor = .Ignore,
    };

    logger.info("fetching cargo deps...", .{});
    const stdout = common.runAndGetStdout(alloc, &.{
        cargo,
        "vendor",
        "--locked",
        "--versioned-dirs",
    }, runOptions) catch |err| {
        logger.err("failed fetching cargo deps with {s}", .{@errorName(err)});
        return BuildFromSourceError.FailedBuilding;
    };
    defer alloc.free(stdout);
    progress.completeOne();

    const configToml = ".cargo/config.toml";
    sourceDir.writeFile(.{
        .data = stdout,
        .sub_path = configToml,
    }) catch |err| {
        logger.err("failed writing {s} file with {s}", .{ configToml, @errorName(err) });
        return BuildFromSourceError.FailedBuilding;
    };
    progress.completeOne();

    logger.info("building {s}...", .{interface.name});
    common.run(alloc, &.{
        cargo,
        "build",
        "--release",
        "--offline",
        "--frozen",
    }, runOptions) catch |err| {
        logger.err("failed fetching cargo deps with {s}", .{@errorName(err)});
        return BuildFromSourceError.FailedBuilding;
    };
    progress.completeOne();

    var binDir = sourceDir.makeOpenPath("bin", .{}) catch |err| {
        logger.err("failed creating or opening bin dir with {s}", .{@errorName(err)});
        return BuildFromSourceError.FailedBuilding;
    };
    errdefer binDir.close();

    sourceDir.rename("target/release/dust", "bin/dust") catch |err| {
        logger.err("failed moving dust executable in bin folder with {s}", .{@errorName(err)});
        sourceDir.deleteTree("target") catch {};
        sourceDir.deleteTree("bin") catch {};
        return BuildFromSourceError.FailedBuilding;
    };
    progress.completeOne();

    return binDir;
}

inline fn withoutTrailingChar(slice: []const u8, checkChar: u8) []const u8 {
    if (slice[slice.len - 1] == checkChar) {
        return slice[0..slice.len - 1];
    }

    return slice;
}

test "withoutTrailingChar" {
    try std.testing.expectEqualStrings("/path/hey", withoutTrailingChar("/path/hey/", '/'));
    try std.testing.expectEqualStrings("/path/hey", withoutTrailingChar("/path/hey", '/'));
}
