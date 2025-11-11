const std = @import("std");
const utils = @import("./utils.zig");

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

test "genPathExtentions - zsh" {
    var buf: [128]u8 = undefined;

    var bufwriter: std.Io.Writer = .fixed(&buf);

    try addPathExtention(&bufwriter, .zsh, "/path/to/store/aliases");

    try std.testing.expectEqualStrings(
        "export PATH=\"$PATH:/path/to/store/aliases\"\n",
        bufwriter.buffered(),
    );
}

test "genPathExtentions - pwsh" {
    var buf: [128]u8 = undefined;

    var bufwriter: std.Io.Writer = .fixed(&buf);

    try addPathExtention(&bufwriter, .pwsh, "/path/to/store/aliases");

    try std.testing.expectEqualStrings(
        "$env:PATH += \";/path/to/store/aliases\"\n",
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

pub fn addAutocomplete(
    writer: *std.Io.Writer,
    shell: Shell,
    comptime commands: []const []const u8,
    comptime packages: []const []const u8,
    comptime storeCommands: []const []const u8,
    comptime commandsWithoutConf: []const []const u8,
) !void {
    switch (shell) {
        .zsh => {
            try writer.print(
                \\
                \\#compdef copper
                \\
                \\_copper() {{
                \\    local -a commands packages store_commands
                \\
                \\    commands=({s})
                \\    packages=({s})
                \\    store_commands=({s})
                \\
                \\    _arguments -C \
                \\        "1: :_values 'command' $commands" \
                \\        "2: :_copper_second_level"
                \\}}
                \\
                \\_copper_second_level() {{
                \\    case $words[1] in
                \\        (store)
                \\        _values 'store command' $store_commands
                \\        ;;
                \\        ({s})
                \\        # no second level arguments
                \\        ;;
                \\        (*)
                \\        _values 'package' $packages
                \\        ;;
                \\    esac
                \\}}
                \\
                \\compdef _copper copper
                \\
            ,
                .{
                    utils.concatComptime(commands, " "),
                    utils.concatComptime(packages, " "),
                    utils.concatComptime(storeCommands, " "),
                    utils.concatComptime(commandsWithoutConf, " "),
                },
            );
        },
        .bash => {
            try writer.print(
                \\
                \\_copper_autocomplete() {{
                \\    local cur prev
                \\    COMPREPLY=()
                \\    cur="${{COMP_WORDS[COMP_CWORD]}}"
                \\    prev="${{COMP_WORDS[COMP_CWORD-1]}}"
                \\
                \\    local commands="{s}"
                \\    local packages="{s}"
                \\    local store_commands="{s}"
                \\    local commands_without_conf="{s}"
                \\
                \\    if [ $COMP_CWORD -eq 1 ]; then
                \\        COMPREPLY=( $(compgen -W "${{commands}}" -- "${{cur}}") )
                \\        return 0
                \\    fi
                \\
                \\    if [ $COMP_CWORD -eq 2 ]; then
                \\        case "${{prev}}" in
                \\            store)
                \\                COMPREPLY=( $(compgen -W "${{store_commands}}" -- "${{cur}}") )
                \\                return 0
                \\                ;;
                \\            *)
                \\                if [[ ! " ${{commands_without_conf}} " =~ " ${{prev}} " ]]; then
                \\                    COMPREPLY=( $(compgen -W "${{packages}}" -- "${{cur}}") )
                \\                fi
                \\                return 0
                \\                ;;
                \\        esac
                \\    fi
                \\}}
                \\
                \\complete -F _copper_autocomplete copper
                \\
            ,
                .{
                    utils.concatComptime(commands, " "),
                    utils.concatComptime(packages, " "),
                    utils.concatComptime(storeCommands, " "),
                    utils.concatComptime(commandsWithoutConf, " "),
                },
            );
        },
        .fish => {
            try writer.print(
                \\
                \\set -l commands {s}
                \\set -l packages {s}
                \\set -l store_commands {s}
                \\set -l commands_without_conf {s}
                \\
                \\complete -c copper -n "count (commandline -opc) < 2" -a "$commands" -d "Copper command"
                \\complete -c copper -n "not contains -- (commandline -opc)[1] $commands_without_conf" -a "$packages" -d "Package"
                \\complete -c copper -n "contains -- (commandline -opc)[1] store" -a "$store_commands" -d "Store command"
                \\
            ,
                .{
                    utils.concatComptime(commands, " "),
                    utils.concatComptime(packages, " "),
                    utils.concatComptime(storeCommands, " "),
                    utils.concatComptime(commandsWithoutConf, " "),
                },
            );
        },
        .pwsh => {
            try writer.print(
                \\
                \\# PowerShell autocompletion script for copper
                \\Register-ArgumentCompleter -Native -CommandName copper -ScriptBlock {{
                \\    param($wordToComplete, $commandAst, $cursorPosition)
                \\
                \\    $commands = @({s})
                \\    $packages = @({s})
                \\    $store_commands = @({s})
                \\    $commands_without_conf = @({s})
                \\
                \\    $commandElements = $commandAst.CommandElements
                \\    $previousWord = if ($commandElements.Count -gt 1) {{ $commandElements[-2].Value }} else {{ '' }}
                \\
                \\    if ($commandElements.Count -le 2) {{
                \\        $commands | Where-Object {{ $_ -like "$wordToComplete*" }} | ForEach-Object {{ [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }}
                \\    }} elseif ($previousWord -eq 'store') {{
                \\        $store_commands | Where-Object {{ $_ -like "$wordToComplete*" }} | ForEach-Object {{ [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }}
                \\    }} elseif (-not ($commands_without_conf -contains $previousWord)) {{
                \\        $packages | Where-Object {{ $_ -like "$wordToComplete*" }} | ForEach-Object {{ [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }}
                \\    }}
                \\}}
                \\
            ,
                .{
                    utils.concatComptime(commands, ", "),
                    utils.concatComptime(packages, ", "),
                    utils.concatComptime(storeCommands, ", "),
                    utils.concatComptime(commandsWithoutConf, ", "),
                },
            );
        },
    }
}
