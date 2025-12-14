const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts");
const compress = @import("compress");

const common = @import("./common.zig");

const logger = std.log.scoped(.jq);

const GITHUB_API_URL = "https://api.github.com/repos/jqlang/jq/releases/latest";

pub const interface: common.ConfInterface = .{
    .name = "jq",
    .type = .Package,
    .getDownloadTargets = common.FetchGithubRelease(.{
        .logger = logger,
        .relaseUrl = GITHUB_API_URL,
        .matchingAsset = matchingAsset,
        .toSemverString = jqVersionToSemVer,
    }),
    .decompressTargetFile = decompressTargetFile,
};

fn jqVersionToSemVer(alloc: std.mem.Allocator, jq_version: []const u8) ?[]const u8 {
    // Ensure the input starts with "jq-"
    if (!std.mem.startsWith(u8, jq_version, "jq-")) {
        return null;
    }

    // Strip "jq-" prefix
    const version = jq_version[3..];

    var iter = std.mem.splitScalar(u8, version, '.');

    const major = std.fmt.parseUnsigned(u32, iter.next() orelse return null, 10) catch return null;

    var minor: ?u32 = null;
    var patch: ?u32 = null;
    var prerelease: ?[]const u8 = null;

    while (iter.next()) |component| {
        var componentWithoutPrerelease = component;

        // Handle rc, beta, etc. (prerelease identifiers)
        if (std.mem.indexOfAny(u8, component, "abr")) |idx| {
            componentWithoutPrerelease = component[0..idx];
            prerelease = component[idx..];
        }

        const int = std.fmt.parseUnsigned(u32, componentWithoutPrerelease, 10) catch return null;

        if (minor == null) {
            minor = int;
            continue;
        }

        if (patch == null) {
            patch = int;
            break;
        }
    }

    if (prerelease) |pre| {
        return std.fmt.allocPrint(alloc, "{d}.{d}.{d}-{s}", .{
            major,
            minor orelse 0,
            patch orelse 0,
            pre,
        }) catch null;
    }

    return std.fmt.allocPrint(alloc, "{d}.{d}.{d}", .{
        major,
        minor orelse 0,
        patch orelse 0,
    }) catch null;
}

test "jqVersionToSemVer" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "jq-1.8.1", "1.8.1" },
        .{ "jq-1.8.0", "1.8.0" },
        .{ "jq-1.7.1", "1.7.1" },
        .{ "jq-1.7", "1.7.0" },
        .{ "jq-1.7rc2", "1.7.0-rc2" },
        .{ "jq-1.7rc1", "1.7.0-rc1" },
        .{ "jq-1.6", "1.6.0" },
        .{ "jq-1.5", "1.5.0" },
        .{ "jq-1.5rc2", "1.5.0-rc2" },
        .{ "jq-1.5rc1", "1.5.0-rc1" },
        .{ "jq-1.4", "1.4.0" },
        .{ "jq-1.3", "1.3.0" },
        .{ "jq-1.2", "1.2.0" },
        .{ "jq-1.1", "1.1.0" },
        .{ "jq-1.0", "1.0.0" },
    };

    const testing = std.testing;
    for (cases) |case| {
        const version, const expected = case;
        const actual = jqVersionToSemVer(testing.allocator, version) orelse return error.FailedConverting;
        defer testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

fn matchingAsset(name: []const u8) bool {
    const targetFilename = comptime getTargetFilename();

    return std.mem.eql(u8, name, targetFilename orelse return false);
}

const DecompressError = common.DecompressError;
fn decompressTargetFile(
    alloc: std.mem.Allocator,
    compression: compress.Compression,
    targetFile: std.fs.File,
    tmpDir: std.fs.Dir,
) DecompressError!std.fs.Dir {
    _ = alloc;

    std.debug.assert(compression == .uncompressed);

    var readerBuf: [16 * 1024]u8 = undefined;
    var reader = targetFile.reader(&readerBuf);

    const exeName = if (builtin.target.os.tag == .windows) "jq.exe" else "jq";
    const copy = tmpDir.createFile(exeName, .{}) catch return error.FailedCreatingCopyFile;
    defer copy.close();

    var writer = copy.writer(&.{});

    _ = reader.interface.streamRemaining(&writer.interface) catch return error.FailedCopying;

    if (builtin.target.os.tag != .windows) {
        // Make it executable by adding execute permissions for user, group, and others
        // 0o755 means: rwxr-xr-x (user: read+write+execute, group: read+execute, others: read+execute)
        copy.chmod(0o755) catch return error.FailedCopying;
    }

    return tmpDir;
}

fn getTargetFilename() ?[]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return null,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .x86 => "i386",
        .s390x => "s390x",
        .mips => "mips",
        .mips64 => "mips64",
        .mips64el => "mips64el",
        .powerpc64le => "ppc64el",
        else => return null,
    };

    if (builtin.target.os.tag == .windows) {
        return std.fmt.comptimePrint("jq-{s}-{s}.exe", .{ os, arch });
    }

    return std.fmt.comptimePrint("jq-{s}-{s}", .{ os, arch });
}
