const std = @import("std");
const backend_options = @import("backend_options");

pub const backend_name: []const u8 = backend_options.backend;

pub const SelectedBackend = blk: {
    if (std.mem.eql(u8, backend_name, "libhv")) {
        break :blk @import("backends/libhv.zig");
    } else {
        break :blk @import("backends/zzz.zig");
    }
};
