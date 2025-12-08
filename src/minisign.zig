/// copied from - https://github.com/jedisct1/zig-minisign/blob/6b1fbdcb30059508ac6ed3abfd8573ae72a94458/src/lib.zig
/// removed not necessary stuff for signing and file reading
const std = @import("std");
const base64 = std.base64;
const crypto = std.crypto;
const fs = std.fs;
const fmt = std.fmt;
const heap = std.heap;
const io = std.io;
const math = std.math;
const mem = std.mem;
const os = std.os;
const process = std.process;
const Blake2b256 = crypto.hash.blake2.Blake2b256;
const Blake2b512 = crypto.hash.blake2.Blake2b512;
const Ed25519 = crypto.sign.Ed25519;
const Endian = std.builtin.Endian;

pub const Signature = struct {
    arena: heap.ArenaAllocator,
    untrusted_comment: []u8,
    signature_algorithm: [2]u8,
    key_id: [8]u8,
    signature: [64]u8,
    trusted_comment: []u8,
    global_signature: [64]u8,

    pub fn deinit(self: *Signature) void {
        self.arena.deinit();
    }

    pub const Algorithm = enum { Prehash, Legacy };

    pub fn algorithm(sig: Signature) !Algorithm {
        const signature_algorithm = sig.signature_algorithm;
        const prehashed = if (signature_algorithm[0] == 0x45 and signature_algorithm[1] == 0x64)
            false
        else if (signature_algorithm[0] == 0x45 and signature_algorithm[1] == 0x44)
            true
        else
            return error.UnsupportedAlgorithm;
        return if (prehashed) .Prehash else .Legacy;
    }

    pub fn decode(child_allocator: mem.Allocator, lines_str: []const u8) !Signature {
        var arena = heap.ArenaAllocator.init(child_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        var it = mem.tokenizeScalar(u8, lines_str, '\n');
        const untrusted_comment = try allocator.dupe(u8, it.next() orelse return error.InvalidEncoding);
        var bin1: [74]u8 = undefined;
        try base64.standard.Decoder.decode(&bin1, it.next() orelse return error.InvalidEncoding);
        var trusted_comment = try allocator.dupe(u8, it.next() orelse return error.InvalidEncoding);
        if (!mem.startsWith(u8, trusted_comment, "trusted comment: ")) {
            return error.InvalidEncoding;
        }
        trusted_comment = trusted_comment["Trusted comment: ".len..];
        var bin2: [64]u8 = undefined;
        try base64.standard.Decoder.decode(&bin2, it.next() orelse return error.InvalidEncoding);
        const sig = Signature{
            .arena = arena,
            .untrusted_comment = untrusted_comment,
            .signature_algorithm = bin1[0..2].*,
            .key_id = bin1[2..10].*,
            .signature = bin1[10..74].*,
            .trusted_comment = trusted_comment,
            .global_signature = bin2,
        };
        return sig;
    }
};

pub const PublicKey = struct {
    untrusted_comment: ?[]u8 = null,
    signature_algorithm: [2]u8 = "Ed".*,
    key_id: [8]u8,
    key: [key_length]u8,

    const key_length = 32;
    const key_type = "ssh-ed25519";
    const key_id_prefix = "minisign key ";

    pub fn decodeFromBase64(str: []const u8) !PublicKey {
        if (str.len != 56) {
            return error.InvalidEncoding;
        }
        var bin: [42]u8 = undefined;
        try base64.standard.Decoder.decode(&bin, str);
        const signature_algorithm = bin[0..2];
        if (bin[0] != 0x45 or (bin[1] != 0x64 and bin[1] != 0x44)) {
            return error.UnsupportedAlgorithm;
        }
        const pk = PublicKey{
            .signature_algorithm = signature_algorithm.*,
            .key_id = bin[2..10].*,
            .key = bin[10..42].*,
        };
        return pk;
    }

    pub fn verifier(self: *const PublicKey, sig: *const Signature) !Verifier {
        const key_id_len = self.key_id.len;
        const null_key_id: [key_id_len]u8 = @splat(0);
        if (!mem.eql(u8, &null_key_id, &self.key_id) and !mem.eql(u8, &sig.key_id, &self.key_id)) {
            return error.KeyIdMismatch;
        }

        const ed25519_pk = try Ed25519.PublicKey.fromBytes(self.key);

        return Verifier{
            .pk = self,
            .sig = sig,
            .format = switch (try sig.algorithm()) {
                .Prehash => .{ .Prehash = Blake2b512.init(.{}) },
                .Legacy => .{ .Legacy = try Ed25519.Signature.fromBytes(sig.signature).verifier(ed25519_pk) },
            },
        };
    }
};

pub const Verifier = struct {
    pk: *const PublicKey,
    sig: *const Signature,
    format: union(enum) {
        Prehash: Blake2b512,
        Legacy: Ed25519.Verifier,
    },

    pub fn update(self: *Verifier, bytes: []const u8) void {
        switch (self.format) {
            .Prehash => |*prehash| prehash.update(bytes),
            .Legacy => |*legacy| legacy.update(bytes),
        }
    }

    pub fn verify(self: *Verifier, allocator: std.mem.Allocator) !void {
        const ed25519_pk = try Ed25519.PublicKey.fromBytes(self.pk.key);
        switch (self.format) {
            .Prehash => |*prehash| {
                var digest: [64]u8 = undefined;

                prehash.final(&digest);

                try Ed25519.Signature.fromBytes(self.sig.signature).verify(&digest, ed25519_pk);
            },
            .Legacy => |*legacy| {
                try legacy.verify();
            },
        }

        var global = try allocator.alloc(u8, self.sig.signature.len + self.sig.trusted_comment.len);
        defer allocator.free(global);
        @memcpy(global[0..self.sig.signature.len], self.sig.signature[0..]);
        @memcpy(global[self.sig.signature.len..], self.sig.trusted_comment);
        try Ed25519.Signature.fromBytes(self.sig.global_signature).verify(global, ed25519_pk);
    }
};
