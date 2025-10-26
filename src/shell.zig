const std = @import("std");

pub const Shell = enum {
    zsh,
    bash,
    fish,
    pwsh,
};

pub fn addPathExtention(
    writer: *std.io.Writer,
    shell: Shell,
    path: []const u8,
) !void {
    defer writer.flush() catch {};

    switch (shell) {
        .zsh, .bash => {
            try writer.print("export PATH=\"$PATH{c}{s}\"\n", .{ std.fs.path.delimiter, path });
        },
        .fish => {
            try writer.print(
                "fish_add_path \"{s}\"\n",
                .{path},
            );
        },
        .pwsh => {
            try writer.print("$env:PATH += \"{c}{s}\"\n", .{ std.fs.path.delimiter, path });
        },
    }
}

test "genPathExtentions" {
    var buf: [128]u8 = undefined;

    var bufwriter: std.io.Writer = .fixed(&buf);

    try addPathExtention(&bufwriter, .zsh, "/path/to/store/aliases");

    try std.testing.expectEqualStrings(
        std.fmt.comptimePrint("export PATH=\"$PATH{c}/path/to/store/aliases\"\n", .{std.fs.path.delimiter}),
        bufwriter.buffered(),
    );
}
