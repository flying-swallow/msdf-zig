const std = @import("std");

/// Quantizes a normalized distance to an unsigned-normalized integer channel.
///
/// Port of msdfgen's `pixelFloatToByte` (core/pixel-conversion.hpp), generalized
/// over the channel width so the 10-bit packed format can share it:
///
///     byte(~int(255.5f - 255.f*clamp(x)))
///
/// The `~int(...)` is a round-to-nearest in disguise, and it matters: a plain
/// `@intFromFloat(max * clamp(x))` truncates instead, landing a LSB dark on
/// roughly half of all inputs. msdfgen switched to this form in 1.12 to match
/// how graphics hardware converts UNORM.
pub fn floatToUnorm(comptime T: type, x: f64) T {
    const max = std.math.maxInt(T);
    const fmax: f64 = @floatFromInt(max);
    // Mirrors the C++ `~int(...)`: complementing an integer is `-v - 1`, so
    // `byte(~int(v))` on a value in [0, max] is exactly `max - int(v)`.
    const complement: f64 = fmax + 0.5 - fmax * std.math.clamp(x, 0.0, 1.0);
    const truncated: i32 = @intFromFloat(complement);
    return @intCast(max - truncated);
}

test "floatToUnorm matches msdfgen pixelFloatToByte" {
    // Expected values computed from the C++ `byte(~int(255.5f-255.f*clamp(x)))`.
    // The 0.25/0.61/0.999 cases are exactly where a truncating conversion
    // disagrees, so they are the ones that would catch a regression.
    try std.testing.expectEqual(@as(u8, 0), floatToUnorm(u8, 0.0));
    try std.testing.expectEqual(@as(u8, 0), floatToUnorm(u8, 0.001));
    try std.testing.expectEqual(@as(u8, 64), floatToUnorm(u8, 0.25));
    try std.testing.expectEqual(@as(u8, 127), floatToUnorm(u8, 0.5));
    try std.testing.expectEqual(@as(u8, 153), floatToUnorm(u8, 0.6));
    try std.testing.expectEqual(@as(u8, 156), floatToUnorm(u8, 0.61));
    try std.testing.expectEqual(@as(u8, 191), floatToUnorm(u8, 0.75));
    try std.testing.expectEqual(@as(u8, 229), floatToUnorm(u8, 0.9));
    try std.testing.expectEqual(@as(u8, 255), floatToUnorm(u8, 0.999));
    try std.testing.expectEqual(@as(u8, 255), floatToUnorm(u8, 1.0));
}

test "floatToUnorm clamps out-of-range input" {
    try std.testing.expectEqual(@as(u8, 0), floatToUnorm(u8, -5.0));
    try std.testing.expectEqual(@as(u8, 255), floatToUnorm(u8, 5.0));
    try std.testing.expectEqual(@as(u10, 0), floatToUnorm(u10, -0.001));
    try std.testing.expectEqual(@as(u10, 1023), floatToUnorm(u10, 1.5));
}

test "floatToUnorm spans the full range for each width" {
    try std.testing.expectEqual(@as(u10, 0), floatToUnorm(u10, 0.0));
    // Ties round down, matching u8's 0.5 -> 127: the `+0.5` lands the midpoint
    // exactly on an integer, which the truncation in the complement then keeps.
    try std.testing.expectEqual(@as(u10, 511), floatToUnorm(u10, 0.5));
    try std.testing.expectEqual(@as(u10, 1023), floatToUnorm(u10, 1.0));
}
