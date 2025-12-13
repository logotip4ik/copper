const std = @import("std");
const common = @import("./common.zig");

const fileConfigs = .{
    @import("./node.zig"),
    @import("./zig.zig"),
    @import("./go.zig"),
    @import("./jq.zig"),
    @import("./git-delta.zig"),
    @import("./fd.zig"),
    @import("./ripgrep.zig"),
    @import("./fzf.zig"),
    @import("./lazygit.zig"),
    @import("./tailspin.zig"),
    @import("./zoxide.zig"),
    @import("./hyperfine.zig"),
    @import("./neovim.zig"),
    @import("./bun.zig"),
    @import("./jj.zig"),
    @import("./just.zig"),
    @import("./python.zig"),
    @import("./television.zig"),
    @import("./skhd.zig"),
    @import("./btop.zig"),
    @import("./git.zig"),
    @import("./claude-code.zig"),
    @import("./ziglay.zig"),
    @import("./dufs.zig"),
    @import("./trippy.zig"),
    @import("./nrz.zig"),
    @import("./try-cli.zig"),
    @import("./mongodb-database-tools.zig"),
    @import("./cyber.zig"),
    @import("./zf.zig"),
    @import("./rust.zig"),
    @import("./helix.zig"),
    @import("./wrkflw.zig"),
    @import("./fresh-editor.zig"),
    @import("./samply.zig"),
    @import("./tree-sitter.zig"),
    @import("./dust.zig"),
    @import("./ouch.zig"),
};

const ConfKeyVal = struct { []const u8, common.ConfInterface };

pub const configs = std.StaticStringMap(common.ConfInterface).initComptime(blk: {
    var confArr: [fileConfigs.len]ConfKeyVal = undefined;

    for (fileConfigs, 0..) |conf, i| {
        confArr[i] = .{
            conf.interface.name,
            conf.interface,
        };
    }

    break :blk confArr;
});

test "no name collisions" {
    const testing = std.testing;

    var hashset: std.BufSet = .init(testing.allocator);
    defer hashset.deinit();

    inline for (fileConfigs) |config| {
        try hashset.insert(config.interface.name);
    }
}
