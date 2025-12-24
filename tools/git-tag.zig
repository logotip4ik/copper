const std = @import("std");

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len != 2) return error.WrongNumberOfArguments;

    const tag = try std.fs.cwd().readFileAlloc(alloc, args[1], 64);

    const trimmed = std.mem.trim(u8, tag, &std.ascii.whitespace);

    var child: std.process.Child = .init(
        &.{ "git", "tag", trimmed },
        alloc,
    );
    _ = try child.spawnAndWait();
}
