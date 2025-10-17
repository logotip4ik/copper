const std = @import("std");
const builtin = @import("builtin");
const common = @import("./common.zig");

const logger = std.log.scoped(.node);

// TODO: this should be exported but used in fetchDist funcrtion ?
 const MIRROR_URLS = .{"https://nodejs.org/dist"};

const Self = @This();

alloc: std.mem.Allocator,

client: *std.http.Client,

pub fn init(alloc: std.mem.Allocator) Self {
    const client = alloc.create(std.http.Client) catch @panic("Could not create http client");

    client.* = std.http.Client{ .allocator = alloc };

    return Self{ .alloc = alloc, .client = client };
}

pub fn deinit(self: Self) void {
    self.client.deinit();
    self.alloc.destroy(self.client);
}

 const Dist = struct {
    version: std.SemanticVersion,
    date: []const u8,
    files: []const []const u8,

    pub fn fromValue(alloc: std.mem.Allocator, value: std.json.Value) !Dist {
        const root = value.object;

        const rootFiles = root.get("files").?.array;
        const files = try alloc.alloc([]const u8, rootFiles.items.len);
        for (rootFiles.items, 0..) |item, i| {
            files[i] = try alloc.dupe(u8, item.string);
        }

        const dateField = root.get("date").?.string;
        const date = try alloc.dupe(u8, dateField);

        const versionField = root.get("version").?.string;
        const version = try toSemanticVersion(versionField);

        return Dist{
            .files = files,
            .date = date,
            .version = version,
        };
    }

    pub fn deinit(self: Dist, alloc: std.mem.Allocator) void {
        for (self.files) |file| {
            alloc.free(file);
        }

        alloc.free(self.files);
        alloc.free(self.date);
    }
};

 const Dists = std.ArrayList(Dist);

 fn deinitDists(dists: *Dists, alloc: std.mem.Allocator) void {
    for (dists.items) |item| item.deinit(alloc);
    dists.deinit(alloc);
}

 fn fetchVersions(self: Self) void {
    inline for (MIRROR_URLS) |mirror| {
        const url = std.fmt.comptimePrint("{s}/{s}", .{ mirror, "index.json" });

        var stream: std.io.Writer.Allocating = .init(self.alloc);
        defer stream.deinit();

        const result = self.client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &stream.writer,
        }) catch |err| {
            logger.err("Error while fetching: {s}\n", .{@errorName(err)});
            return;
        };

        std.debug.print("{any}\n", .{result.status});
    }
}

/// Expects dists to be sorted list by semantic version
 fn resolveVersion(dists: []const Dist, userVersion: std.SemanticVersion.Range) ?Dist {
    var version: ?Dist = null;

    for (dists) |dist| {
        if (userVersion.includesVersion(dist.version)) {
            version = dist;
        }
    }

    return version;
}

 fn isTargetSupported(dist: Dist, target: std.Target) bool {
    const os = switch (target.os.tag) {
        .aix => "aix",
        .windows => "win",
        .macos => "osx",
        .linux => "linux",
        else => return false,
    };

    const arch = switch (target.cpu.arch) {
        .powerpc64 => "ppc64",
        .powerpc64le => "ppc64le",
        .aarch64 => "arm64",
        .s390x => "s390x",
        .x86_64 => "x64",
        else => return false,
    };

    var buf: [512]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "{s}-{s}", .{ os, arch }) catch return false;

    for (dist.files) |file| {
        if (std.mem.startsWith(u8, file, needle)) {
            return true;
        }
    }

    return false;
}

test "isTargetSupported" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const verionsFile = @embedFile("./node-versions.json");
    var dists = try parseVersionsJsonIntoDists(alloc, verionsFile);
    defer deinitDists(&dists, alloc);

    const userVersion = try common.parseUserVersion("22");
    const version = resolveVersion(dists.items, userVersion).?;

    try testing.expectEqual(isTargetSupported(version, std.Target{
        .abi = .android,
        .cpu = .{
            .arch = .aarch64,
            .features = .empty,
            .model = std.Target.Cpu.Model.generic(.aarch64),
        },
        .ofmt = .c,
        .os = .{
            .tag = .macos,
            .version_range = std.Target.Os.VersionRange.default(.aarch64, .macos, .android),
        },
    }), true);

    try testing.expectEqual(isTargetSupported(version, std.Target{
        .abi = .android,
        .cpu = .{
            .arch = .arc,
            .features = .empty,
            .model = std.Target.Cpu.Model.generic(.arc),
        },
        .ofmt = .c,
        .os = .{
            .tag = .amdhsa,
            .version_range = std.Target.Os.VersionRange.default(.arc, .amdhsa, .android),
        },
    }), false);
}

 fn buildTarLink(alloc: std.mem.Allocator, mirror: []const u8, target: std.Target, dist: Dist) ?[]const u8 {
    const osName = switch (target.os.tag) {
        .macos => "darwin",
        .windows => "win",
        .linux => "linux",
        .aix => "aix",
        else => return null,
    };

    const arch = switch (target.cpu.arch) {
        .aarch64 => "arm64",
        .s390x => "s390x",
        .x86_64 => "x64",
        .powerpc64 => "ppc64",
        .powerpc64le => "ppc64le",
        else => return null,
    };

    const ext = switch (target.os.tag) {
        .windows => ".zip",
        else => ".tar.gz",
    };

    return std.fmt.allocPrint(alloc, "{[mirror]s}/v{[version]f}/node-v{[version]f}-{[os]s}-{[arch]s}{[ext]s}", .{
        .mirror = mirror,
        .version = dist.version,
        .os = osName,
        .arch = arch,
        .ext = ext,
    }) catch return null;
}

test "buildTarLink" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const link = buildTarLink(
        alloc,
        MIRROR_URLS[0],
        std.Target{
            .abi = .android,
            .cpu = .{
                .arch = .aarch64,
                .features = .empty,
                .model = std.Target.Cpu.Model.generic(.aarch64),
            },
            .ofmt = .c,
            .os = .{
                .tag = .macos,
                .version_range = std.Target.Os.VersionRange.default(.aarch64, .macos, .android),
            },
        },
        Dist{
            .date = "",
            .files = &[_][]const u8{},
            .version = .{ .major = 22, .minor = 19, .patch = 0 },
        },
    );
    defer if (link) |l| alloc.free(l);

    try testing.expectEqualStrings(
        std.fmt.comptimePrint("{s}/v22.19.0/node-v22.19.0-darwin-arm64.tar.gz", .{MIRROR_URLS[0]}),
        link.?,
    );
}

fn toSemanticVersion(version: []const u8) !std.SemanticVersion {
    // skip leading `v`
    return std.SemanticVersion.parse(version[1..]);
}

/// caller owns Dists
 fn parseVersionsJsonIntoDists(alloc: std.mem.Allocator, noalias input: []const u8) !Dists {
    const json: std.json.Parsed(std.json.Value) = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trimEnd(u8, input, "\r\n "), .{});
    defer json.deinit();

    var dists = try Dists.initCapacity(alloc, json.value.array.items.len);

    for (json.value.array.items) |item| {
        dists.appendAssumeCapacity(try Dist.fromValue(alloc, item));
    }

    std.sort.heap(Dist, dists.items, {}, common.compareVersionField(Dist));

    return dists;
}

test "resolveVerion" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const verionsFile = @embedFile("./node-versions.json");

    var dists = try parseVersionsJsonIntoDists(alloc, verionsFile);
    defer deinitDists(&dists, alloc);

    const userVersion = common.parseUserVersion("22") catch unreachable;

    const resolvedDist = resolveVersion(dists.items, userVersion).?;

    const expectedFiles = &[_][]const u8{
        "aix-ppc64",
        "headers",
        "linux-arm64",
        "linux-armv7l",
        "linux-ppc64le",
        "linux-s390x",
        "linux-x64",
        "osx-arm64-tar",
        "osx-x64-pkg",
        "osx-x64-tar",
        "src",
        "win-arm64-7z",
        "win-arm64-zip",
        "win-x64-7z",
        "win-x64-exe",
        "win-x64-msi",
        "win-x64-zip",
        "win-x86-7z",
        "win-x86-exe",
        "win-x86-msi",
        "win-x86-zip",
    };

    try testing.expectEqualDeep(Dist{
        .date = "2025-08-28",
        .files = expectedFiles,
        .version = std.SemanticVersion{ .major = 22, .minor = 19, .patch = 0 },
    }, resolvedDist);
}

pub fn add(self: Self) !void {
    _ = self;
    logger.info("help from add", .{});
}

pub fn use(self: Self) !void {
    _ = self;
}

pub fn list(self: Self) !void {
    _ = self;
}

pub fn remove(self: Self) !void {
    _ = self;
}
