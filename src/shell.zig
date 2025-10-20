const std = @import("std");

pub const Shell = enum {
    zsh,
};

pub fn writePathExtentions(
    writer: *std.io.Writer,
    shell: Shell,
    storePrefix: []const u8,
    confs: []const []const u8,
) !void {
    defer writer.flush() catch {};

    switch (shell) {
        .zsh => {
            //export PATH="$HOME/Library/Application Support/fnm:$PATH"
            _ = try writer.write("export PATH=\"$PATH");
            for (confs) |conf,| {
                try writer.print("{c}{f}", .{
                    std.fs.path.delimiter,
                    std.fs.path.fmtJoin(&[_][]const u8{ storePrefix, conf, "default" }),
                });
            }
            _ = try writer.write("\"\n");
        },
    }
}

test "genPathExtentions" {
    var buf: [128]u8 = undefined;

    var bufwriter: std.io.Writer = .fixed(&buf);

    try writePathExtentions(&bufwriter, .zsh, "/path/to/store", &[_][]const u8{ "zig", "node" });

    try std.testing.expectEqualStrings(
        "export PATH=\"$PATH:/path/to/store/zig/default:/path/to/store/node/default\"\n",
        bufwriter.buffered(),
    );
}
