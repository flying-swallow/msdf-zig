const std = @import("std");

pub const SdfType = enum {
    sdf,
    psdf,
    msdf,
    mtsdf,
    /// Experimental packed BGR MSDF with three 10-bit channels.
    msdf10,

    pub fn numChannels(self: SdfType) u8 {
        return switch (self) {
            .sdf, .psdf => 1,
            .msdf, .msdf10 => 3,
            .mtsdf => 4,
        };
    }

    pub fn requiresColoring(self: SdfType) bool {
        return switch (self) {
            .msdf, .msdf10, .mtsdf => true,
            else => false,
        };
    }
};

pub const ColoringMethod = enum {
    simple,
    ink_trap,
    distance,
};

pub const Winding = enum {
    guess,
    positive,
    negative,
};

pub const Msdf10Pixel = packed struct(u32) {
    r: u10 = 0,
    g: u10 = 0,
    b: u10 = 0,
    a: u2 = std.math.maxInt(u2),
};
