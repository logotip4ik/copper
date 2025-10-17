const std = @import("std");

const Self = @This();

pub const node = @import("./node.zig");

test {
    const allConfigs = std.meta.DeclEnum(Self);
    const typeInfo = @typeInfo(allConfigs);

    const requiredMethods = [_][]const u8{
        "init",
        "deinit",
        "add",
        "remove",
        "list",
        "use",
    };

    inline for (typeInfo.@"enum".fields) |field| {
        const conf = @field(Self, field.name);

        inline for (requiredMethods) |method| {
            if (!@hasDecl(conf, method)) {
                @compileError(
                    std.fmt.comptimePrint("{s} missing {s}\n", .{@typeName(conf), method }),
                );
            }
        }
    }
}
