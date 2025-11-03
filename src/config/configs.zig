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
    .{ "hyperfine", hyperfine.interface },
});
