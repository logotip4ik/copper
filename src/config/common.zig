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

    return SemanticVersion.Range{
        .min = SemanticVersion{
            .major = major,
            .minor = minor orelse 0,
            .patch = patch orelse 0,
        },
        .max = SemanticVersion{
            .major = major,
            .minor = minor orelse std.math.maxInt(usize),
            .patch = patch orelse std.math.maxInt(usize),
        }
    };
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

pub const DownloadTarget = struct {
    versionString: []const u8,
    version: std.SemanticVersion,
    shasum: []const u8,
    size: []const u8,
    tarball: []const u8,

    pub fn copy(self: DownloadTarget, alloc: std.mem.Allocator) !DownloadTarget {
        return DownloadTarget{
            .versionString = try alloc.dupe(u8, self.versionString),
            .version = std.SemanticVersion{
                .major =  self.version.major,
                .minor =  self.version.minor,
                .patch =  self.version.patch,
                .build =  self.version.build,
                .pre =  self.version.pre,
            },
            .shasum = try alloc.dupe(u8, self.shasum),
            .size = try alloc.dupe(u8, self.size),
            .tarball = try alloc.dupe(u8, self.tarball),
        };
    }

    pub fn deinit(self: DownloadTarget, alloc: std.mem.Allocator) void {
        alloc.free(self.versionString);
        alloc.free(self.shasum);
        alloc.free(self.size);
        alloc.free(self.tarball);
    }
};


pub const Runner = struct {
    const Self = @This();

    add: *const fn (runner: *Self, args: *std.process.ArgIterator) ?DownloadTarget,
    remove: *const fn (runner: *Self) void,
    list: *const fn (runner: *Self) void,
    use: *const fn (runner: *Self) void,
};
