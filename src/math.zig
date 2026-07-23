const std = @import("std");

const Vec2 = @Vector(2, f64);

pub fn RectangleBound(T: type) type {
    return struct {
        l: T,
        b: T,
        r: T,
        t: T,
        const Self = @This();

        pub const empty: RectangleBound(T) = switch (@typeInfo(T)) {
            .float, .comptime_float => .{
                .l = std.math.floatMax(T),
                .b = std.math.floatMax(T),
                .r = -std.math.floatMax(T),
                .t = -std.math.floatMax(T),
            },
            else => .{
                .l = std.math.maxInt(T),
                .b = std.math.maxInt(T),
                .r = std.math.minInt(T),
                .t = std.math.minInt(T),
            },
        };

        pub fn addBound(a: Self, b: Self) Self {
            return .{
                .l = @min(a.l, b.l),
                .b = @min(a.b, b.b),
                .r = @max(a.r, b.r),
                .t = @max(a.t, b.t),
            };
        }

        pub fn addPoint(self: Self, a: @Vector(2, T)) Self {
            return .{
                .l = @min(a[0], self.l),
                .b = @min(a[1], self.b),
                .r = @max(a[0], self.r),
                .t = @max(a[1], self.t),
            };
        }
    };
}

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

pub const QuadraticRoots = struct { num: u8, solutions: [2]f64 };
pub const CubicRoots = struct { num: u8, solutions: [3]f64 };

pub fn solveQuadratic(a: f64, b: f64, c: f64) QuadraticRoots {
    if (a == 0 or @abs(b) > 1e12 * @abs(a)) {
        if (b == 0) return .{ .num = 0, .solutions = .{ 0, 0 } };
        return .{ .num = 1, .solutions = .{ -c / b, 0 } };
    }
    const dscr = b * b - 4.0 * a * c;
    if (dscr > 0) {
        const dscr_sqrt = @sqrt(dscr);
        return .{ .num = 2, .solutions = .{ (-b + dscr_sqrt) / (2 * a), (-b - dscr_sqrt) / (2 * a) } };
    } else if (dscr == 0) {
        return .{ .num = 1, .solutions = .{ -b / (2 * a), 0 } };
    } else {
        return .{ .num = 0, .solutions = .{ 0, 0 } };
    }
}

fn solveCubicNormed(a: f64, b: f64, c: f64) CubicRoots {
    const a2 = a * a;
    var q = 1.0 / 9.0 * (a2 - 3 * b);
    const r = 1.0 / 54.0 * (a * (2 * a2 - 9 * b) + 27 * c);
    const r2 = r * r;
    const q3 = q * q * q;
    const one_third = 1.0 / 3.0;
    const mod_a = a * one_third;
    if (r2 < q3) {
        var t = r / @sqrt(q3);
        if (t < -1) t = -1;
        if (t > 1) t = 1;
        t = std.math.acos(t);
        q = -2 * @sqrt(q);
        return .{ .num = 3, .solutions = .{ q * @cos(one_third * t) - mod_a, q * @cos(one_third * (t + 2 * std.math.pi)) - mod_a, q * @cos(one_third * (t - 2 * std.math.pi)) - mod_a } };
    } else {
        const u = @as(f64, (if (r < 0) 1.0 else -1.0)) * std.math.pow(f64, @abs(r) + @sqrt(r2 - q3), one_third);
        const v = if (u == 0) 0 else q / u;
        if (u == v or @abs(u - v) < 1e-12 * @abs(u + v)) {
            return .{ .num = 2, .solutions = .{ (u + v) - mod_a, -0.5 * (u + v) - mod_a, 0.0 } };
        }
        return .{ .num = 1, .solutions = .{ (u + v) - mod_a, 0.0, 0.0 } };
    }
}

pub fn solveCubic(a: f64, b: f64, c: f64, d: f64) CubicRoots {
    if (a != 0) {
        const bn = b / a;
        if (@abs(bn) < 1e6) return solveCubicNormed(bn, c / a, d / a);
    }

    const quad_res = solveQuadratic(b, c, d);
    return .{ .num = quad_res.num, .solutions = .{ quad_res.solutions[0], quad_res.solutions[1], 0.0 } };
}

fn hasRoot(roots: []const f64, count: u8, expected: f64, tolerance: f64) bool {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (@abs(roots[i] - expected) <= tolerance) return true;
    }
    return false;
}

test "solveQuadratic: 2 real roots" {
    // x^2 - 3x + 2 = 0 -> roots: 2, 1
    const res = solveQuadratic(1.0, -3.0, 2.0);
    try std.testing.expectEqual(@as(u8, 2), res.num);
    try std.testing.expect(hasRoot(&res.solutions, res.num, 2.0, 1e-6));
    try std.testing.expect(hasRoot(&res.solutions, res.num, 1.0, 1e-6));
}

test "solveQuadratic: 1 double root" {
    // x^2 - 2x + 1 = 0 -> root: 1
    const res = solveQuadratic(1.0, -2.0, 1.0);
    try std.testing.expectEqual(@as(u8, 1), res.num);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), res.solutions[0], 1e-6);
}

test "solveQuadratic: 0 real roots" {
    // x^2 + 1 = 0 -> no real roots
    const res = solveQuadratic(1.0, 0.0, 1.0);
    try std.testing.expectEqual(@as(u8, 0), res.num);
}

test "solveQuadratic: degenerate to linear" {
    // 0x^2 + 2x - 4 = 0 -> root: 2
    const res = solveQuadratic(0.0, 2.0, -4.0);
    try std.testing.expectEqual(@as(u8, 1), res.num);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), res.solutions[0], 1e-6);
}

test "solveCubic: 3 real distinct roots" {
    // x^3 - 6x^2 + 11x - 6 = 0 -> roots: 1, 2, 3
    const res = solveCubic(1.0, -6.0, 11.0, -6.0);
    try std.testing.expectEqual(@as(u8, 3), res.num);
    try std.testing.expect(hasRoot(&res.solutions, res.num, 1.0, 1e-6));
    try std.testing.expect(hasRoot(&res.solutions, res.num, 2.0, 1e-6));
    try std.testing.expect(hasRoot(&res.solutions, res.num, 3.0, 1e-6));
}

test "solveCubic: 1 real root, 2 complex" {
    // x^3 - x^2 + x - 1 = 0 -> root: 1
    // (factored: (x-1)(x^2+1) = 0)
    const res = solveCubic(1.0, -1.0, 1.0, -1.0);
    try std.testing.expectEqual(@as(u8, 1), res.num);
    try std.testing.expect(hasRoot(&res.solutions, res.num, 1.0, 1e-6));
}

test "solveCubic: 2 real roots (1 distinct, 1 double)" {
    // x^3 - 3x + 2 = 0 -> roots: 1 (double), -2
    const res = solveCubic(1.0, 0.0, -3.0, 2.0);
    try std.testing.expectEqual(@as(u8, 2), res.num);
    try std.testing.expect(hasRoot(&res.solutions, res.num, 1.0, 1e-6));
    try std.testing.expect(hasRoot(&res.solutions, res.num, -2.0, 1e-6));
}

test "solveCubic: degenerate to quadratic" {
    // 0x^3 + x^2 - 5x + 6 = 0 -> roots: 2, 3
    const res = solveCubic(0.0, 1.0, -5.0, 6.0);
    try std.testing.expectEqual(@as(u8, 2), res.num);
    try std.testing.expect(hasRoot(&res.solutions, res.num, 2.0, 1e-6));
    try std.testing.expect(hasRoot(&res.solutions, res.num, 3.0, 1e-6));
}
