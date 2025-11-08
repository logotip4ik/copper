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
    configs: []const []const u8,
    triggerFiles: []const []const u8,
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
                \\  if [[ 
            );

            for (triggerFiles, 0..) |file, i| {
                const orString = if (i == 0) "" else " || ";
                try writer.print("{s}-f {s}", .{ orString, file });
            }
            _ = try writer.write(" ]]; then\n");

            try writer.print("      {s}\n", .{commandToRun});

            _ = try writer.write(
                \\  fi
                \\}
                \\
                \\add-zsh-hook chpwd _copper_file_hook && _copper_file_hook
                \\
            );
        },
        .bash => {
            _ = try writer.write(
                \\_copper_file_hook() {
                \\  if [[ 
            );

            for (triggerFiles, 0..) |file, i| {
                const orString = if (i == 0) "" else " || ";
                try writer.print("{s}-f {s}", .{ orString, file });
            }
            _ = try writer.write(" ]]; then\n");

            try writer.print("    {s}\n", .{commandToRun});

            _ = try writer.write(
                \\  fi
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
                \\  if test 
            );

            for (triggerFiles, 0..) |file, i| {
                const orString = if (i == 0) "" else " -o ";
                try writer.print("{s}-f {s}", .{ orString, file });
            }
            _ = try writer.write("\n");

            try writer.print("    {s}\n", .{commandToRun});

            _ = try writer.write(
                \\  end
                \\end
                \\
                \\_copper_file_hook
                \\
            );
        },
        .pwsh => {
            _ = try writer.write(
                \\function _copper_file_hook {
                \\  if (
            );

            for (triggerFiles, 0..) |file, i| {
                const orString = if (i == 0) "" else " -or ";
                try writer.print("{s}(Test-Path {s})", .{ orString, file });
            }
            _ = try writer.write(") {\n");

            try writer.print("    {s}\n", .{commandToRun});

            _ = try writer.write(
                \\  }
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

test "addUseOnPathChange - zsh" {
    const testing = std.testing;

    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();

    const configs = &.{"node"};
    const files = &.{ ".nvmrc", ".node-version" };

    try addUseOnPathChange(&writer.writer, .zsh, configs, files);
    try testing.expectEqualStrings(
        \\_copper_file_hook () {
        \\  if [[ -f .nvmrc || -f .node-version ]]; then
        \\      copper file-hook node
        \\  fi
        \\}
        \\
        \\add-zsh-hook chpwd _copper_file_hook && _copper_file_hook
        \\
    , writer.written());
}

test "addUseOnPathChange - bash" {
    const testing = std.testing;

    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();

    const configs = &.{"node"};
    const files = &.{ ".nvmrc", ".node-version" };

    try addUseOnPathChange(&writer.writer, .bash, configs, files);
    try testing.expectEqualStrings(
        \\_copper_file_hook() {
        \\  if [[ -f .nvmrc || -f .node-version ]]; then
        \\    copper file-hook node
        \\  fi
        \\}
        \\
        \\if [ -n "$BASH_VERSION" ]; then
        \\  PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }_copper_file_hook"
        \\fi
        \\
        \\_copper_file_hook
        \\
    , writer.written());
}

test "addUseOnPathChange - fish" {
    const testing = std.testing;

    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();

    const configs = &.{"node"};
    const files = &.{ ".nvmrc", ".node-version" };

    try addUseOnPathChange(&writer.writer, .fish, configs, files);
    try testing.expectEqualStrings(
        \\function _copper_file_hook --on-variable PWD
        \\  if test -f .nvmrc -o -f .node-version
        \\    copper file-hook node
        \\  end
        \\end
        \\
        \\_copper_file_hook
        \\
    , writer.written());
}

test "addUseOnPathChange - pwsh" {
    const testing = std.testing;

    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();

    const configs = &.{"node"};
    const files = &.{ ".nvmrc", ".node-version" };

    try addUseOnPathChange(&writer.writer, .pwsh, configs, files);
    try testing.expectEqualStrings(
        \\function _copper_file_hook {
        \\  if ((Test-Path .nvmrc) -or (Test-Path .node-version)) {
        \\    copper file-hook node
        \\  }
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
    , writer.written());
}
