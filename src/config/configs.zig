const std = @import("std");
const common = @import("./common.zig");

pub const node = @import("./node.zig");
pub const zig = @import("./zig.zig");

const ConfKeyVal = struct { []const u8, common.ConfInterface };

pub const configs = std.StaticStringMap(common.ConfInterface).initComptime([_]ConfKeyVal{
    .{ "node", node.interface },
    .{ "zig", zig.interface },
});
