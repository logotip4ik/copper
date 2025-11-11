const std = @import("std");
const builtin = @import("builtin");
const buildOptions = @import("build_options");
const consts = @import("consts");

const Store = @import("./store.zig");
const common = @import("./config/common.zig");

const logger = std.log.scoped(.utils);

pub fn concatComptime(comptime strings: []const []const u8, comptime sep: []const u8) []const u8 {
    return comptime blk: {
        var length: usize = 0;
        for (strings) |string| {
            length += string.len;
        }
        length += sep.len * (strings.len - 1);

        var buf: [length]u8 = undefined;
        var writer: std.io.Writer = .fixed(&buf);

        for (strings, 0..) |string, i| {
            if (i == 0) {
                try writer.print("{s}", .{string});
            } else {
                try writer.print("{s}{s}", .{ sep, string });
            }
        }

        const final = buf;
        break :blk &final;
    };
}

