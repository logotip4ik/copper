const std = @import("std");
const builtin = @import("builtin");

const configs = @import("./config/configs.zig");

const Command = enum {
    add,
    use,
    list,
    remove,
    help,
};

const Configs = std.meta.DeclEnum(configs);

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    const alloc = debug.allocator();
    defer _ = debug.deinit();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    // skip executable
    _ = args.next() orelse return error.NoExecutableArg;

    const command = std.meta.stringToEnum(
        Command,
        args.next() orelse "help",
    ) orelse return error.UnrecognisedCommand;

    if (command == .help) {
        std.debug.print("Help menu\n", .{});
        return;
    }

    const config = std.meta.stringToEnum(
        Configs,
        args.next() orelse return error.NoConfig,
    ) orelse return error.UnrecognisedConfig;

    const Config = @field(configs, @tagName(config));

    const runner: Config = .init(alloc);
    defer runner.deinit();

    try switch (command) {
        .add => runner.add(),
        .use => runner.use(),
        .list => runner.list(),
        .remove => runner.remove(),
        else => {},
    };
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}

test {
    std.testing.refAllDecls(configs);
}
