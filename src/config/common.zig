const std = @import("std");

const SemanticVersion = std.SemanticVersion;
pub fn parseUserVersion(input: []const u8) !SemanticVersion.Range {
    var iter = std.mem.splitScalar(u8, input, '.');

    const majorStr = iter.next() orelse input;
    const major = std.fmt.parseUnsigned(u32, majorStr, 10) catch return error.InvalidMajor;

    var minor: ?u32 = null;
    if (iter.next()) |minorStr| {
        minor = std.fmt.parseUnsigned(u32, minorStr, 10) catch return error.InvalidMinor;
    }

    var patch: ?u32 = null;
    if (iter.next()) |patchStr| {
        patch = std.fmt.parseUnsigned(u32, patchStr, 10) catch return error.InvalidPatch;
    }

    return SemanticVersion.Range{ .min = SemanticVersion{
        .major = major,
        .minor = minor orelse 0,
        .patch = patch orelse 0,
    }, .max = SemanticVersion{
        .major = major,
        .minor = minor orelse std.math.maxInt(usize),
        .patch = patch orelse std.math.maxInt(usize),
    } };
}

test "parseUserVersion" {
    const testing = std.testing;

    try testing.expectEqual(SemanticVersion.Range{
        .min = SemanticVersion{ .major = 22, .minor = 0, .patch = 0 },
        .max = SemanticVersion{
            .major = 22,
            .minor = std.math.maxInt(usize),
            .patch = std.math.maxInt(usize),
        },
    }, try parseUserVersion("22"));

    try testing.expectEqual(SemanticVersion.Range{
        .min = SemanticVersion{ .major = 0, .minor = 15, .patch = 0 },
        .max = SemanticVersion{
            .major = 0,
            .minor = 15,
            .patch = std.math.maxInt(usize),
        },
    }, try parseUserVersion("0.15"));
}

pub fn compareVersionField(comptime T: type) fn (void, T, T) bool {
    std.debug.assert(@hasField(T, "version"));

    const t = @FieldType(T, "version");
    if (t == std.SemanticVersion) {
        return struct {
            pub fn inner(_: void, a: T, b: T) bool {
                return std.SemanticVersion.order(a.version, b.version) == .gt;
            }
        }.inner;
    } else if (t == *std.SemanticVersion) {
        return struct {
            pub fn inner(_: void, a: T, b: T) bool {
                return std.SemanticVersion.order(a.version.*, b.version.*) == .gt;
            }
        }.inner;
    } else {
        @compileError(t ++ " unresolved type for version field");
    }
}

pub fn openFirstDirWithLog(
    dir: std.fs.Dir,
    comptime logger: anytype,
    comptime message: []const u8,
) !?std.fs.Dir {
    var iter = dir.iterate();
    while(iter.next() catch null) |entry| {
        if (entry.kind == .directory) {
            if (message.len > 0) {
                logger.info(message, .{entry.name});
            }
            return try dir.openDir(entry.name, .{});
        }
    }

    return null;
}

pub const DownloadTarget = struct {
    versionString: []const u8,
    version: std.SemanticVersion,
    tarball: []const u8,

    /// use getTarballShasum function from ConfInterface if null
    shasum: ?[]const u8 = null,

    pub fn copy(self: DownloadTarget, alloc: std.mem.Allocator) !DownloadTarget {
        return DownloadTarget{
            .versionString = try alloc.dupe(u8, self.versionString),
            .version = std.SemanticVersion{
                .major = self.version.major,
                .minor = self.version.minor,
                .patch = self.version.patch,
                .build = self.version.build,
                .pre = self.version.pre,
            },
            .shasum = try alloc.dupe(u8, self.shasum),
            .size = try alloc.dupe(u8, self.size),
            .tarball = try alloc.dupe(u8, self.tarball),
        };
    }

    pub fn deinit(self: DownloadTarget, alloc: std.mem.Allocator) void {
        alloc.free(self.versionString);
        alloc.free(self.tarball);
        if (self.shasum) |shasum| alloc.free(shasum);
    }
};
pub const DownloadTargets = std.array_list.Aligned(DownloadTarget, null);

pub const DownloadTargetError = error{
    FailedParsingJson,
    FailedFetchingVersionJson,
    FailedConvertingToDownloadTarget,
};

pub const DecompressError = error{
    FailedCreatingDecompressor,
    FailedAllocatingBuffer,
    FailedUnzipping,
    DirNotExists,
    InvalidResultDir,
    FailedCreatingWalker,
};

pub const DecompressResult = struct {
    dir: std.fs.Dir,
    /// should be absolute path
    path: []const u8,
};

pub const GetTarballShasumError = error{
    FailedFetching,
    InvalidShasumFile,
    ShasumNotFound,
    FailedGeneratingTarballName,
};

pub const ConfInterface = struct {
    /// relative to root of extracted folder, so:
    /// `copper/node/default` + binPath = `copper/node/default/bin`
    binPath: []const u8 = "",

    getDownloadTargets: *const fn (
        alloc: std.mem.Allocator,
        client: *std.http.Client,
        progress: std.Progress.Node,
    ) DownloadTargetError!DownloadTargets,
    decompressTargetFile: *const fn (
        alloc: std.mem.Allocator,
        target: std.fs.File,
        tmpDir: std.fs.Dir,
    ) DecompressError!std.fs.Dir,

    /// get be noop function if `DownloadTarget` has already resolved `shasum` field
    getTarballShasum: *const fn (
        alloc: std.mem.Allocator,
        client: *std.http.Client,
        target: DownloadTarget,
        progress: std.Progress.Node,
    ) GetTarballShasumError![]const u8 = noopGetTarballShasum,
};

pub fn noopGetTarballShasum(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    target: DownloadTarget,
    progress: std.Progress.Node,
) GetTarballShasumError![]const u8 {
    _ = alloc;
    _ = client;
    _ = target;
    _ = progress;
    unreachable;
}

pub const Compression = enum { xz, gz, zip };
