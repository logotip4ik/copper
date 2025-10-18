const std = @import("std");
const builtin = @import("builtin");

const configs = @import("./config/configs.zig");
const common = @import("./config/common.zig");

const Command = enum {
    alias,
    add,
    use,
    list,
    installed,
    @"list-installed",
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

    switch (command) {
        .help => {
            std.debug.print("Help menu\n", .{});
            return;
        },
        .installed, .@"list-installed" => {
            std.debug.print("installed\n", .{});
            return;
        },
        .alias => {
            std.debug.print("installed\n", .{});
            return;
        },
        else => {},
    }

    const config = std.meta.stringToEnum(
        Configs,
        args.next() orelse return error.NoConfig,
    ) orelse return error.UnrecognisedConfig;

    inline for (@typeInfo(configs).@"struct".decls) |decl| {
        if (std.mem.eql(u8, @tagName(config), decl.name)) {
            var conf = @field(configs, decl.name).init(alloc);
            defer conf.deinit();

            var runner = &conf.runner;

            switch (command) {
                .add => runner.add(runner, &args),
                .use => runner.use(runner),
                .list => runner.list(runner),
                .remove => runner.remove(runner),
                else => unreachable,
            }
        }
    }
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
    std.testing.refAllDecls(common);
}
