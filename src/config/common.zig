const std = @import("std");

const SemanticVersion = std.SemanticVersion;
pub fn parseUserVersion(input: []const u8) !SemanticVersion.Range {
    var iter = std.mem.splitScalar(u8, input, '.');

    const majorStr = iter.next() orelse input;
    const major = std.fmt.parseUnsigned(u32, majorStr, 10) catch return error.InvalidMajor;

    var minor: u32 = 0;
    if (iter.next()) |minorStr| {
        minor = std.fmt.parseUnsigned(u32, minorStr, 10) catch return error.InvalidMinor;
    }

    var patch: u32 = 0;
    if (iter.next()) |patchStr| {
        patch = std.fmt.parseUnsigned(u32, patchStr, 10) catch return error.InvalidPatch;
    }

    return SemanticVersion.Range{
        .min = SemanticVersion{
            .major = major,
            .minor = minor,
            .patch = patch,
        },
        .max = SemanticVersion{
            .major = major,
            .minor = std.math.maxInt(usize),
            .patch = std.math.maxInt(usize),
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
}

pub fn compareVersionField(comptime T: type) fn (void, T, T) bool {
    std.debug.assert(@FieldType(T, "version") == std.SemanticVersion);

    return struct {
        pub fn inner(_: void, a: T, b: T) bool {
            return std.SemanticVersion.order(a.version, b.version) == .lt;
        }
    }.inner;
}

pub const Runner = struct {
    const Self = @This();

    add: *const fn (runner: *Self) void,
    remove: *const fn (runner: *Self) void,
    list: *const fn (runner: *Self) void,
    use: *const fn (runner: *Self) void,
};
