const std = @import("std");
const builtin = @import("builtin");
const common = @import("./common.zig");

const Alloc = std.mem.Allocator;
const Runner = common.Runner;

const MIRROR_URLS = [_][]const u8{
    "https://pkg.machengine.org/zig",
    "https://zigmirror.hryx.net/zig",
    "https://zig.linus.dev/zig",
    "https://zig.squirl.dev",
    "https://zig.florent.dev",
    "https://zig.mirror.mschae23.de/zig",
    "https://zigmirror.meox.dev",
    "https://ziglang.org/download",
};

const logger = std.log.scoped(.zig);

const Self = @This();

alloc: Alloc,

client: std.http.Client,

runner: Runner,

mirrors: std.array_list.Aligned([]const u8, null),

pub fn init(alloc: Alloc) Self {
    var mirrors = std.array_list.Aligned([]const u8, null).initCapacity(alloc, MIRROR_URLS.len) catch unreachable;

    inline for (MIRROR_URLS) |mirror| {
        mirrors.appendAssumeCapacity(mirror);
    }

    var r: std.Random.DefaultPrng = .init(@intCast(std.time.timestamp()));
    const random = r.random();

    random.shuffle([]const u8, mirrors.items);

    return Self{
        .alloc = alloc,
        .client = std.http.Client{ .allocator = alloc },
        .mirrors = mirrors,
        .runner = .{
            .add = add,
            .remove = remove,
            .list = list,
            .use = use,
        },
    };
}

pub fn deinit(self: *Self) void {
    self.client.deinit();
    self.mirrors.deinit(self.alloc);
}

pub fn add(runner: *Runner) void {
    const self: *Self = @fieldParentPtr("runner", runner);
    _ = self;
}

pub fn remove(runner: *Runner) void {
    const self: *Self = @fieldParentPtr("runner", runner);
    _ = self;
}

pub fn use(runner: *Runner) void {
    const self: *Self = @fieldParentPtr("runner", runner);
    _ = self;
}

const DownloadTarget = struct {
    version: []const u8,
    shasum: []const u8,
    size: []const u8,
    tarball: []const u8,

    pub fn fromValue(alloc: Alloc, key: *const []const u8, value: *std.json.Value) !?DownloadTarget {
        const versionValue = value.object.get("version");
        const version = if (versionValue) |v| v.string else key.*;

        const target = value.object.get(try getTargetString()) orelse return null;

        const shasum = target.object.get("shasum") orelse return error.NoShasumField;
        const size = target.object.get("size") orelse return error.NoSizeField;
        const tarball = target.object.get("tarball") orelse return error.NoTarballField;

        return DownloadTarget{
            .version = try alloc.dupe(u8, version),
            .shasum = try alloc.dupe(u8, shasum.string),
            .size = try alloc.dupe(u8, size.string),
            .tarball = try alloc.dupe(u8, tarball.string),
        };
    }

    pub fn deinit(self: DownloadTarget, alloc: Alloc) void {
        alloc.free(self.version);
        alloc.free(self.shasum);
        alloc.free(self.size);
        alloc.free(self.tarball);
    }
};

test "DownloadTarget" {
    const testing = std.testing;

    const versionsString = @embedFile("./zig-versions.json");

    var json: std.json.Parsed(VersionsMap) = std.json.parseFromSlice(VersionsMap, testing.allocator, versionsString, .{}) catch unreachable;
    defer json.deinit();

    var targets: std.array_list.Aligned(DownloadTarget, null) = .empty;
    defer {
        for (targets.items) |target| target.deinit(testing.allocator);
        targets.deinit(testing.allocator);
    }

    var iter = json.value.map.iterator();
    while (iter.next()) |entry| {
        const download = try DownloadTarget.fromValue(testing.allocator, entry.key_ptr, entry.value_ptr) orelse continue;

        try targets.append(testing.allocator, download);
    }

    for (targets.items) |item| {
        std.debug.print("version {s}\n", .{item.version});
    }

    try testing.expectEqual(10, targets.items.len);
}

const Versions = std.array_list.Aligned(DownloadTarget, null);
const VersionsMap = std.json.ArrayHashMap(std.json.Value);
fn fetchVersions(
    alloc: Alloc,
    client: *std.http.Client,
    mirrors: *[][]const u8,
) !Versions {
    var stream: std.io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    var versionMapUrlBuf: [64]u8 = undefined;
    var maybeJson: ?std.json.Parsed(VersionsMap) = null;

    for (mirrors.*) |mirror| {
        stream.clearRetainingCapacity();

        const versionMapUrl = std.fmt.bufPrint(&versionMapUrlBuf, "{s}/index.json", .{mirror}) catch unreachable;

        const res = client.fetch(.{
            .method = .GET,
            .keep_alive = false,
            .headers = .{ .user_agent = .{ .override = "copper" } },
            .location = .{ .url = versionMapUrl },
            .response_writer = &stream.writer,
        }) catch {
            logger.warn("Failed fetching versions json from {s}", .{versionMapUrl});
            continue;
        };

        if (res.status == .ok and stream.written().len > 0) {
            maybeJson = std.json.parseFromSlice(VersionsMap, alloc, stream.written(), .{}) catch {
                logger.warn("Failed parsing versions json from {s}", .{versionMapUrl});
                continue;
            };

            break;
        }
    } else return error.UnableToFetchVersionsFile;

    const versionsMapJson = maybeJson orelse return error.FailedToFetchVersionsJson;
    defer versionsMapJson.deinit();

    var versions: Versions = .empty;
    errdefer {
        for (versions.items) |item| item.deinit(alloc);
        versions.deinit(alloc);
    }

    var verIter = versionsMapJson.value.map.iterator();

    while (verIter.next()) |entry| {
        const target = try DownloadTarget.fromValue(alloc, entry.key_ptr, entry.value_ptr)  orelse continue;

        versions.append(alloc, target) catch return error.FailedAppendingDownloadTarget;
    }

    return versions;
}

pub fn list(runner: *Runner) void {
    const self: *Self = @fieldParentPtr("runner", runner);

    self.client.initDefaultProxies(self.alloc) catch |err| {
        logger.err("Failed initializing default proxies: {s}", .{@errorName(err)});
        return;
    };

    var versions = fetchVersions(self.alloc, &self.client, &self.mirrors.items) catch |err| {
        logger.err("Failed fetching versions map: {s}", .{@errorName(err)});
        return;
    };
    defer {
        for (versions.items) |item| item.deinit(self.alloc);
        versions.deinit(self.alloc);
    }

    logger.info("Available zig versions:", .{});
    for (versions.items) |item| {
        logger.info("{s}", .{item.version});
    }
}

test "list" {
    const testing = std.testing;

    var self: Self = .init(testing.allocator);
    defer self.deinit();

    self.list();
}

fn getTargetString() ![]const u8 {
    const os = switch (builtin.target.os.tag) {
        .macos => "macos",
        .windows => "windows",
        .linux => "linux",
        .freebsd => "freebsd",
        .netbsd => "netbsd",
        else => return error.UnsupportedOS,
    };

    const arch = switch (builtin.target.cpu.arch) {
        .x86 => "x86",
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .loongarch64 => "loongarch64",
        .powerpc64 => "powerpc",
        .powerpc64le => "powerpc64le",
        .arm => "arm",
        .riscv64 => "riscv64",
        else => return error.UnsupportedCPU,
    };

    return std.fmt.comptimePrint("{s}-{s}", .{ arch, os });
}
