const std = @import("std");
const options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 4) return error.WrongNumberOfArguments;

    var outputFile = std.Io.Dir.cwd().createFile(init.io, args[1], .{}) catch return error.UnableToOpenOutputFile;
    defer outputFile.close(init.io);

    const commitsFile = std.Io.Dir.cwd().openFile(init.io, args[2], .{}) catch return error.UnableToOpenCommitsFile;
    var readerBuf: [1024]u8 = undefined;
    var commitsReeader = commitsFile.reader(init.io, &readerBuf);

    var bumpRange: enum { major, minor, patch } = .patch;

    while (try commitsReeader.interface.takeDelimiter('\n')) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const colIdx = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        if (trimmed[colIdx - 1] == '!') {
            bumpRange = .major;
            break;
        }

        if (std.mem.startsWith(u8, trimmed, "feat")) {
            bumpRange = .minor;
        }
    }

    var newVersion = options.version;
    switch (bumpRange) {
        .major => {
            newVersion.major += 1;
            newVersion.minor = 0;
            newVersion.patch = 0;
        },
        .minor => {
            newVersion.minor += 1;
            newVersion.patch = 0;
        },
        .patch => {
            newVersion.patch += 1;
        },
    }

    const currentVersionString = std.fmt.allocPrint(alloc, "{f}", .{options.version}) catch unreachable;
    const newVersionString = std.fmt.allocPrint(alloc, "{f}", .{newVersion}) catch unreachable;

    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], alloc, .limited(10 * 1024));
    const output = try alloc.alloc(
        u8,
        std.mem.replacementSize(u8, input, currentVersionString, newVersionString),
    );

    _ = std.mem.replace(u8, input, currentVersionString, newVersionString, output);

    var outputWriter = outputFile.writer(init.io, &.{});
    try outputWriter.interface.writeAll(output);

    // used by `build.zig` to create tag with updated version
    std.debug.print("v{f}", .{newVersion});

    std.process.cleanExit(init.io);
}
