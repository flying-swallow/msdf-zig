const std = @import("std");

/// Edge color as an RGB bitmask, matching msdfgen's EdgeColor.
pub const EdgeColor = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
};

/// Deterministic color sequence, ported from msdfgen's edge-coloring.cpp.
///
/// msdfgen does not use a PRNG here: it consumes the seed one bit (or one trit)
/// at a time, so a given seed always yields the same coloring and the caller can
/// reproduce it. The seed is threaded explicitly rather than held in module
/// state, which is what keeps colorShape reentrant and thread-safe.
pub const Seed = struct {
    value: u64,

    pub fn init(value: u64) Seed {
        return .{ .value = value };
    }

    /// msdfgen `seedExtract2`: takes one bit.
    fn extract2(self: *Seed) u32 {
        const v: u32 = @intCast(self.value & 1);
        self.value >>= 1;
        return v;
    }

    /// msdfgen `seedExtract3`: takes one base-3 digit.
    fn extract3(self: *Seed) u32 {
        const v: u32 = @intCast(self.value % 3);
        self.value /= 3;
        return v;
    }

    /// msdfgen `initColor`.
    pub fn initColor(self: *Seed) EdgeColor {
        const colors = [3]EdgeColor{ .cyan, .magenta, .yellow };
        return colors[self.extract3()];
    }

    /// msdfgen `switchColor(EdgeColor &, unsigned long long &)`: rotates the
    /// two-channel color left by 1 or 2 places, wrapping bit 3 back to bit 0.
    pub fn switchColor(self: *Seed, color: *EdgeColor) void {
        const shifted: u32 = @as(u32, @intFromEnum(color.*)) << @intCast(1 + self.extract2());
        color.* = @enumFromInt((shifted | shifted >> 3) & @intFromEnum(EdgeColor.white));
    }

    /// msdfgen `switchColor(EdgeColor &, unsigned long long &, EdgeColor banned)`.
    /// If the current and banned colors share exactly one channel, the result is
    /// forced to the complement of that channel; otherwise it falls back to a
    /// plain switch. Passing `.black` bans nothing.
    pub fn switchColorBanned(self: *Seed, color: *EdgeColor, banned: EdgeColor) void {
        const combined: EdgeColor = @enumFromInt(@intFromEnum(color.*) & @intFromEnum(banned));
        switch (combined) {
            .red, .green, .blue => color.* = @enumFromInt(
                @intFromEnum(combined) ^ @intFromEnum(EdgeColor.white),
            ),
            else => self.switchColor(color),
        }
    }
};

test "initColor matches msdfgen for low seeds" {
    // colors[] = { CYAN, MAGENTA, YELLOW } indexed by seed%3.
    for ([_]struct { seed: u64, want: EdgeColor }{
        .{ .seed = 0, .want = .cyan },
        .{ .seed = 1, .want = .magenta },
        .{ .seed = 2, .want = .yellow },
        .{ .seed = 3, .want = .cyan },
    }) |case| {
        var seed: Seed = .init(case.seed);
        try std.testing.expectEqual(case.want, seed.initColor());
    }
}

test "switchColor rotates channels" {
    // With seed 0 every extract2 yields 0, so each switch shifts left by 1:
    // CYAN(6) -> 12 -> (12|1)&7 = 5 MAGENTA -> 10 -> (10|1)&7 = 3 YELLOW -> 6 CYAN.
    var seed: Seed = .init(0);
    var color: EdgeColor = .cyan;
    seed.switchColor(&color);
    try std.testing.expectEqual(EdgeColor.magenta, color);
    seed.switchColor(&color);
    try std.testing.expectEqual(EdgeColor.yellow, color);
    seed.switchColor(&color);
    try std.testing.expectEqual(EdgeColor.cyan, color);
}

test "switchColor stays within the two-channel colors" {
    // Every reachable color must keep exactly two channels set, or the MSDF
    // loses a channel and the median reconstruction degrades.
    var seed: Seed = .init(0x9e3779b97f4a7c15);
    var color: EdgeColor = .cyan;
    for (0..64) |_| {
        seed.switchColor(&color);
        const bits = @popCount(@intFromEnum(color));
        try std.testing.expectEqual(@as(u8, 2), bits);
    }
}

test "switchColorBanned avoids the banned channel" {
    // CYAN(110) & YELLOW(011) = GREEN(010) -> forced to GREEN^WHITE = MAGENTA(101).
    var seed: Seed = .init(0);
    var color: EdgeColor = .cyan;
    seed.switchColorBanned(&color, .yellow);
    try std.testing.expectEqual(EdgeColor.magenta, color);

    // A banned color of black shares nothing, so it degrades to a plain switch.
    var seed2: Seed = .init(0);
    var color2: EdgeColor = .cyan;
    seed2.switchColorBanned(&color2, .black);
    try std.testing.expectEqual(EdgeColor.magenta, color2);
}
