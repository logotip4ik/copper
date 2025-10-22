const std = @import("std");
const builtin = @import("builtin");

pub fn getHeap() type {
    if (builtin.mode == .ReleaseFast) {
        return struct {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

            pub fn allocator() std.mem.Allocator {
                return arena.allocator();
            }

            pub fn deinit() void {
                arena.deinit();
            }
        };
    } else {
        return struct {
            var gpa: std.heap.DebugAllocator(.{}) = .init;

            pub fn allocator() std.mem.Allocator {
                return gpa.allocator();
            }

            pub fn deinit() void {
                _ = gpa.detectLeaks();
                _ = gpa.deinit();
            }
        };
    }
}
