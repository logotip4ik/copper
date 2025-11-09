const std = @import("std");
const common = @import("./common.zig");

pub const node = @import("./node.zig");
pub const zig = @import("./zig.zig");
pub const go = @import("./go.zig");
pub const jq = @import("./jq.zig");
pub const gitDelta = @import("./git-delta.zig");
pub const fd = @import("./fd.zig");
pub const ripgrep = @import("./ripgrep.zig");
pub const fzf = @import("./fzf.zig");
pub const lazygit = @import("./lazygit.zig");
pub const tailspin = @import("./tailspin.zig");
pub const zoxide = @import("./zoxide.zig");
pub const hyperfine = @import("./hyperfine.zig");
pub const neovim = @import("./neovim.zig");
pub const bun = @import("./bun.zig");
pub const jj = @import("./jj.zig");
pub const just = @import("./just.zig");
pub const python = @import("./python.zig");

const ConfKeyVal = struct { []const u8, common.ConfInterface };

pub const configs = std.StaticStringMap(common.ConfInterface).initComptime([_]ConfKeyVal{
    .{ "node", node.interface },
    .{ "zig", zig.interface },
    .{ "go", go.interface },
    .{ "jq", jq.interface },
    .{ "git-delta", gitDelta.interface },
    .{ "fd", fd.interface },
    .{ "ripgrep", ripgrep.interface },
    .{ "fzf", fzf.interface },
    .{ "lazygit", lazygit.interface },
    .{ "tailspin", tailspin.interface },
    .{ "zoxide", zoxide.interface },
    .{ "hyperfine", hyperfine.interface },
    .{ "neovim", neovim.interface },
    .{ "bun", bun.interface },
    .{ "jj", jj.interface },
    .{ "just", just.interface },
    .{ "python", python.interface },
});
