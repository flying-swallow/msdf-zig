const std = @import("std");

const Vec2 = @Vector(2, f64);

// Cubic Bezier and its first two derivatives, in the (qa, ab, br, as) basis the
// distance search works in: qa = p0-origin, ab = p1-p0, br = p2-p1-ab,
// as = (p3-p2)-(p2-p1)-br.
pub fn cubicPoint(qa: Vec2, ab: Vec2, br: Vec2, as: Vec2, t: f64) Vec2 {
    return qa + ab * v2(3.0 * t) + br * v2(3.0 * t * t) + as * v2(t * t * t);
}

pub fn cubicDerivative(ab: Vec2, br: Vec2, as: Vec2, t: f64) Vec2 {
    return ab * v2(3.0) + br * v2(6.0 * t) + as * v2(3.0 * t * t);
}

pub fn cubicDerivative2(br: Vec2, as: Vec2, t: f64) Vec2 {
    return br * v2(6.0) + as * v2(6.0 * t);
}

pub fn f64i(int: anytype) f64 {
    return @floatFromInt(int);
}

pub fn lengthSqr(vec: Vec2) f64 {
    return @mulAdd(f64, vec[0], vec[0], vec[1] * vec[1]);
}

pub fn length(vec: Vec2) f64 {
    return @sqrt(lengthSqr(vec));
}

pub fn ortho(vec: Vec2, polarity: bool) Vec2 {
    return if (polarity)
        .{ -vec[1], vec[0] }
    else
        .{ vec[1], -vec[0] };
}

fn boolToF64(b: bool) f64 {
    return @floatFromInt(@intFromBool(b));
}

pub fn normal(vec: Vec2, disallow_zero: bool) Vec2 {
    const len = length(vec);
    if (len != 0.0) return vec / v2(len);
    return .{ 0.0, boolToF64(disallow_zero) };
}

pub fn orthonormal(vec: Vec2, polarity: bool, disallow_zero: bool) Vec2 {
    const len = length(vec);
    if (len != 0.0)
        return ortho(vec, polarity) / v2(len);

    return if (polarity)
        .{ 0.0, boolToF64(disallow_zero) }
    else
        .{ 0.0, -boolToF64(disallow_zero) };
}

pub fn dot(a: Vec2, b: Vec2) f64 {
    return @mulAdd(f64, a[0], b[0], a[1] * b[1]);
}

pub fn cross(a: Vec2, b: Vec2) f64 {
    return @mulAdd(f64, a[0], b[1], -a[1] * b[0]);
}

pub fn median(a: anytype, b: anytype, c: anytype) @TypeOf(a) {
    return @max(@min(a, b), @min(@max(a, b), c));
}

pub fn mix(a: anytype, b: anytype, t: anytype) @TypeOf(a, b) {
    const BaseType = @TypeOf(a, b);
    const WeightType = @TypeOf(t);
    const weight_info = @typeInfo(WeightType);
    switch (@typeInfo(BaseType)) {
        .float, .comptime_float => {
            if (weight_info != .float and weight_info != .comptime_float)
                @compileError("Invalid weight type, float base types require float weight types");
            return @mulAdd(@TypeOf(a, b), 1 - t, a, t * b);
        },
        .vector => {
            const weight: BaseType = if (weight_info == .vector) t else @splat(t);
            const one: BaseType = @splat(1);
            return @mulAdd(@TypeOf(a, b), one - weight, a, weight * b);
        },
        else => @compileError("Invalid base type, only floats and their vectors are supported"),
    }
}

/// Perpendicular distance from the edge's supporting line, valid only ahead of
/// the endpoint (`ts > 0`). Returns null when it does not improve on `dist`.
pub fn perpendicularDistance(dist: f64, ep: Vec2, edge_dir: Vec2) ?f64 {
    const ts = dot(ep, edge_dir);
    if (ts > 0) {
        const perpendicular = cross(ep, edge_dir);
        if (@abs(perpendicular) < @abs(dist)) {
            return perpendicular;
        }
    }
    return null;
}

pub fn boolSign(b: bool) i2 {
    return @intCast(@as(i3, @intFromBool(b)) * 2 - 1);
}

pub fn nonZeroSign(n: anytype) @TypeOf(n) {
    const sign = boolSign(n > 0);
    switch (@typeInfo(@TypeOf(n))) {
        .float, .comptime_float => return @floatFromInt(sign),
        .int, .comptime_int => return sign,
        else => @compileError("Invalid type, only floats and ints are supported"),
    }
}

pub fn v2(scalar: anytype) Vec2 {
    return @splat(scalar);
}
