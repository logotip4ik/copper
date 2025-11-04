const std = @import("std");

pub const Shell = enum {
    zsh,
    bash,
    fish,
    pwsh,
};

pub fn addPathExtention(
    writer: *std.Io.Writer,
    shell: Shell,
    path: []const u8,
) !void {
    defer writer.flush() catch {};

    switch (shell) {
        .zsh, .bash => {
            try writer.print("export PATH=\"$PATH:{s}\"\n", .{path});
        },
        .fish => {
            try writer.print(
                "fish_add_path \"{s}\"\n",
                .{path},
            );
        },
        .pwsh => {
            try writer.print("$env:PATH += \";{s}\"\n", .{path});
        },
    }
}

test "genPathExtentions" {
    var buf: [128]u8 = undefined;

    var bufwriter: std.Io.Writer = .fixed(&buf);

    try addPathExtention(&bufwriter, .zsh, "/path/to/store/aliases");

    try std.testing.expectEqualStrings(
        std.fmt.comptimePrint("export PATH=\"$PATH{c}/path/to/store/aliases\"\n", .{std.fs.path.delimiter}),
        bufwriter.buffered(),
    );
}

pub fn addUseOnPathChange(
    writer: *std.Io.Writer,
    shell: Shell,
    configs: [][]const u8,
) !void {
    if (configs.len == 0) {
        return;
    }

    var runCommandBuf: [256]u8 = undefined;
    var runCommandWriter: std.Io.Writer = .fixed(&runCommandBuf);

    try runCommandWriter.print("copper file-hook", .{});
    for (configs) |config| {
        try runCommandWriter.print(" {s}", .{config});
    }

    const commandToRun = runCommandWriter.buffered();

    switch (shell) {
        .zsh => {
            _ = try writer.write(
                \\_copper_file_hook () {
                \\
            );
            try writer.print("  {s}\n", .{commandToRun});
            _ = try writer.write(
                \\}
                \\
                \\add-zsh-hook chpwd _copper_file_hook && _copper_file_hook
                \\
            );
        },
        .bash => {
            _ = try writer.write(
                \\_copper_file_hook() {
                \\
            );
            try writer.print("  {s}\n", .{commandToRun});
            _ = try writer.write(
                \\}
                \\
                \\if [ -n "$BASH_VERSION" ]; then
                \\  PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }_copper_file_hook"
                \\fi
                \\
                \\_copper_file_hook
                \\
            );
        },
        .fish => {
            _ = try writer.write(
                \\function _copper_file_hook --on-variable PWD
                \\
            );
            try writer.print("  {s}\n", .{commandToRun});
            _ = try writer.write(
                \\end
                \\
                \\_copper_file_hook
                \\
            );
        },
        .pwsh => {
            _ = try writer.write(
                \\function _copper_file_hook {
                \\
            );
            try writer.print("  {s}\n", .{commandToRun});
            _ = try writer.write(
                \\}
                \\
                \\$global:_copper_original_prompt = $function:prompt
                \\
                \\function global:prompt {
                \\  & $global:_copper_original_prompt
                \\  _copper_file_hook
                \\}
                \\
                \\_copper_file_hook
                \\
            );
        },
    }
}
