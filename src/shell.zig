const std = @import("std");

pub const Shell = enum {
    zsh,
};

pub fn writePathExtentions(
    writer: *std.io.Writer,
    shell: Shell,
    paths: []const []const u8,
) !void {
    defer writer.flush() catch {};

    switch (shell) {
        .zsh => {
            //export PATH="$HOME/Library/Application Support/fnm:$PATH"
            _ = try writer.write("export PATH=\"$PATH");
            for (paths) |path,| {
                try writer.print("{c}{s}", .{
                    std.fs.path.delimiter,
                    path,
                });
            }
            _ = try writer.write("\"\n");
        },
    }
}

test "genPathExtentions" {
    var buf: [128]u8 = undefined;

    var bufwriter: std.io.Writer = .fixed(&buf);

    try writePathExtentions(&bufwriter, .zsh, &[_][]const u8{ "/path/to/store/zig/default", "/path/to/store/node/default" });

    try std.testing.expectEqualStrings(
        "export PATH=\"$PATH:/path/to/store/zig/default:/path/to/store/node/default\"\n",
        bufwriter.buffered(),
    );
}
