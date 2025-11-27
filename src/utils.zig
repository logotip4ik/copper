const std = @import("std");
const builtin = @import("builtin");
const buildOptions = @import("build_options");
const consts = @import("consts");

const Store = @import("./store.zig");
const common = @import("./config/common.zig");
const configs = @import("./config/configs.zig");

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

pub fn resolveConfig(configName: []const u8) !common.ConfInterface {
    return configs.configs.get(configName) orelse {
        const stdoutFile = std.fs.File.stdout();
        defer stdoutFile.close();

        var buf: [128]u8 = undefined;
        var w = stdoutFile.writer(&buf);
        const stdout = &w.interface;
        defer stdout.flush() catch {};

        stdout.print("available configs: ", .{}) catch unreachable;

        const available = comptime configs.configs.keys();
        inline for (available, 0..) |conf, i| {
            if (i == 0) {
                stdout.print("{s}", .{available[0]}) catch unreachable;
            } else {
                stdout.print(", {s}", .{conf}) catch unreachable;
            }
        }
        stdout.writeByte('\n') catch unreachable;

        return error.UnrecognisedConfig;
    };
}

/// ext - result of running `std.fs.path.extension`
pub fn guessCompression(filepath: []const u8) ?common.Compression {
    const ext = std.fs.path.extension(filepath);

    return std.meta.stringToEnum(
        common.Compression,
        if (ext.len == 0) "uncompressed" else ext[1..],
    ) orelse {
        @branchHint(.unlikely);

        std.log.err("unrecognised compression for {s}", .{filepath});
        return null;
    };
}
