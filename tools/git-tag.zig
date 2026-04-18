const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 2) return error.WrongNumberOfArguments;

    const tag = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], alloc, .limited(64));
    const trimmed = std.mem.trim(u8, tag, &std.ascii.whitespace);

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ "git", "tag", trimmed },
    });

    _ = try child.wait(init.io);
}
