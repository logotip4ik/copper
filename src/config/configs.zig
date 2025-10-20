const std = @import("std");
const common = @import("./common.zig");

pub const node = @import("./node.zig");
pub const zig = @import("./zig.zig");

pub const configs = std.StaticStringMap(common.ConfInterface).initComptime([_]struct { []const u8, common.ConfInterface }{
    .{ "node", node.interface },
    .{ "zig", zig.interface },
});
