const std = @import("std");

pub const EXE_NAME = "copper";

pub const DEFAULT_HEADERS: std.http.Client.Request.Headers = .{
    .user_agent = .{ .override =  "xyz.bogdankostyuk.copper/v1" },
};
