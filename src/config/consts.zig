const std = @import("std");

pub const DEFAULT_HEADERS: std.http.Client.Request.Headers = .{
    .user_agent = .{ .override =  "xyz.bogdankostyuk.copper/v1" },
};
