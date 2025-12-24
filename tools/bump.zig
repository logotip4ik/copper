const std = @import("std");
const options = @import("build_options");

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);

    if (args.len != 4) return error.WrongNumberOfArguments;

    var outputFile = std.fs.cwd().createFile(args[1], .{}) catch return error.UnableToOpenOutputFile;
    defer outputFile.close();

    const commitsFile = std.fs.cwd().openFile(args[2], .{}) catch return error.UnableToOpenCommitsFile;
    var readerBuf: [1024]u8 = undefined;
    var commitsReeader = commitsFile.reader(&readerBuf);

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

    const input = try std.fs.cwd().readFileAlloc(alloc, args[3], 10 * 1024);
    const output = try alloc.alloc(
        u8,
        std.mem.replacementSize(u8, input, currentVersionString, newVersionString),
    );

    _ = std.mem.replace(u8, input, currentVersionString, newVersionString, output);

    var outputWriter = outputFile.writer(&.{});
    try outputWriter.interface.writeAll(output);

    // used by `build.zig` to create tag with updated version
    std.debug.print("v{f}", .{newVersion});

    return std.process.cleanExit();
}
