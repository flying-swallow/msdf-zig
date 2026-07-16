//! Port of msdfgen's core/convergent-curve-ordering.cpp (added in 1.13).
//!
//! For curves a, b converging at P = a.point(1) = b.point(0) with the same
//! (opposite) direction, determines which of them exits P on the left and which
//! on the right, at the smallest positive radius around P.
//!
//! The derivation, from the original:
//!
//! For non-degenerate curves A(t), B(t) both originating at P, we want the limit
//! of sign(cross(A(t/|A'(0)|) - P, B(t/|B'(0)|) - P)) as t -> 0 from above. The
//! parameter has to be normed by the first derivative at P so that the limit
//! approaches P at the same rate along both curves; omitting that normalization
//! was the main error of earlier versions of deconverge, and is why msdf-zig's
//! inlined cross-product test was not good enough.
//!
//! For degenerate cubics (first control point equal to the origin point) |A'(0)|
//! is zero, so we approach with the square root of t and use the derivative of
//! A(sqrt(t)), which at t = 0 equals A''(0)/2.
//!
//! The cross product is a polynomial (in t, or t^2 in the degenerate case) whose
//! sign at zero is decided by the lowest-order non-zero derivative -- that is,
//! by the first non-zero coefficient in order of increasing exponent. Its
//! constant and linear terms are zero, and the second derivative is zero by
//! assumption (the curves are convergent -- that is an input requirement;
//! otherwise the answer is just the sign of the cross product of their
//! directions at t = 0). So the search starts at the third derivative.

const std = @import("std");

const EdgeSegment = @import("EdgeSegment.zig");
const math = @import("math.zig");

const Vec2 = @Vector(2, f64);
const zero: Vec2 = @splat(0.0);

fn eql(a: Vec2, b: Vec2) bool {
    return @reduce(.And, a == b);
}

/// True when the vector is not exactly zero, mirroring the C++ `if (vector)`.
fn nonZero(v: Vec2) bool {
    return v[0] != 0 or v[1] != 0;
}

/// Three-way sign: -1, 0, or 1. msdfgen's arithmetics.hpp `sign`.
fn sign(x: f64) i32 {
    return @as(i32, @intFromBool(0 < x)) - @as(i32, @intFromBool(x < 0));
}

/// Collapses curves whose inner control points sit on an endpoint down to the
/// lowest order that describes them.
fn simplifyDegenerateCurve(cp: []Vec2, order: *u8) void {
    if (order.* == 3 and
        (eql(cp[1], cp[0]) or eql(cp[1], cp[3])) and
        (eql(cp[2], cp[0]) or eql(cp[2], cp[3])))
    {
        cp[1] = cp[3];
        order.* = 1;
    }
    if (order.* == 2 and (eql(cp[1], cp[0]) or eql(cp[1], cp[2]))) {
        cp[1] = cp[2];
        order.* = 1;
    }
    if (order.* == 1 and eql(cp[0], cp[1])) order.* = 0;
}

fn copyControlPoints(edge: EdgeSegment, out: []Vec2) u8 {
    switch (edge.segment) {
        .linear => |p| {
            @memcpy(out[0..2], &p);
            return 1;
        },
        .quadratic_bezier => |p| {
            @memcpy(out[0..3], &p);
            return 2;
        },
        .cubic_bezier => |p| {
            @memcpy(out[0..4], &p);
            return 3;
        },
    }
}

/// `cp[corner]` is the shared point; curve A's control points run backwards from
/// `corner-1`, curve B's forwards from `corner+1`.
fn orderingAt(cp: []const Vec2, corner: usize, points_before: u8, points_after: u8) i32 {
    if (!(points_before > 0 and points_after > 0)) return 0;

    var a1: Vec2 = zero;
    var a2: Vec2 = zero;
    var a3: Vec2 = zero;
    var b1: Vec2 = zero;
    var b2: Vec2 = zero;
    var b3: Vec2 = zero;

    a1 = cp[corner - 1] - cp[corner];
    b1 = cp[corner + 1] - cp[corner];
    if (points_before >= 2) a2 = cp[corner - 2] - cp[corner - 1] - a1;
    if (points_after >= 2) b2 = cp[corner + 2] - cp[corner + 1] - b1;
    if (points_before >= 3) {
        a3 = cp[corner - 3] - cp[corner - 2] - (cp[corner - 2] - cp[corner - 1]) - a2;
        a2 *= math.v2(3.0);
    }
    if (points_after >= 3) {
        b3 = cp[corner + 3] - cp[corner + 2] - (cp[corner + 2] - cp[corner + 1]) - b2;
        b2 *= math.v2(3.0);
    }
    a1 *= math.v2(@as(f64, @floatFromInt(points_before)));
    b1 *= math.v2(@as(f64, @floatFromInt(points_after)));

    // Non-degenerate case
    if (nonZero(a1) and nonZero(b1)) {
        const as = math.length(a1);
        const bs = math.length(b1);
        // Third derivative
        var d = as * math.cross(a1, b2) + bs * math.cross(a2, b1);
        if (d != 0) return sign(d);
        // Fourth derivative
        d = as * as * math.cross(a1, b3) + as * bs * math.cross(a2, b2) + bs * bs * math.cross(a3, b1);
        if (d != 0) return sign(d);
        // Fifth derivative
        d = as * math.cross(a2, b3) + bs * math.cross(a3, b2);
        if (d != 0) return sign(d);
        // Sixth derivative
        return sign(math.cross(a3, b3));
    }

    // Degenerate curve after the corner: swap A <-> B and fall into the branch
    // below, remembering to flip the result.
    var s: i32 = 1;
    if (nonZero(a1)) { // and not nonZero(b1)
        b1 = a1;
        var tmp = b2;
        b2 = a2;
        a2 = tmp;
        tmp = b3;
        b3 = a3;
        a3 = tmp;
        s = -1;
    }

    // Degenerate curve before the corner
    if (nonZero(b1)) {
        // Two-and-a-half-th derivative
        var d = math.cross(a3, b1);
        if (d != 0) return s * sign(d);
        // Third derivative
        d = math.cross(a2, b2);
        if (d != 0) return s * sign(d);
        // Three-and-a-half-th derivative
        d = math.cross(a3, b2);
        if (d != 0) return s * sign(d);
        // Fourth derivative
        d = math.cross(a2, b3);
        if (d != 0) return s * sign(d);
        // Four-and-a-half-th derivative
        return s * sign(math.cross(a3, b3));
    }

    // Degenerate on both sides of the corner
    // Two-and-a-half-th derivative
    const d = @sqrt(math.length(a2)) * math.cross(a2, b3) + @sqrt(math.length(b2)) * math.cross(a3, b2);
    if (d != 0) return sign(d);
    // Third derivative
    return sign(math.cross(a3, b3));
}

/// Returns -1, 0, or 1. Zero means "cannot tell", which callers treat as no
/// reordering.
pub fn convergentCurveOrdering(a: EdgeSegment, b: EdgeSegment) i32 {
    // Layout mirrors the C++: one buffer, with the shared corner at index 4 so
    // that curve A's points can be written at negative offsets from it.
    var cp: [12]Vec2 = @splat(zero);
    const corner = 4;
    const a_tmp = 8;

    var a_order = copyControlPoints(a, cp[a_tmp..]);
    var b_order = copyControlPoints(b, cp[corner..]);

    // The curves must actually meet.
    if (!eql(cp[a_tmp + a_order], cp[corner])) return 0;

    simplifyDegenerateCurve(cp[a_tmp..], &a_order);
    simplifyDegenerateCurve(cp[corner..], &b_order);

    for (0..a_order) |i| cp[corner - a_order + i] = cp[a_tmp + i];
    return orderingAt(&cp, corner, a_order, b_order);
}

test "linear curves meeting head-on are ordered by their turn" {
    // Two opposite linear segments meeting at the origin. They are colinear, so
    // every cross product vanishes and there is no ordering to report.
    const a: EdgeSegment = .{ .segment = .{ .linear = .{ .{ -1, 0 }, .{ 0, 0 } } } };
    const b: EdgeSegment = .{ .segment = .{ .linear = .{ .{ 0, 0 }, .{ -1, 0 } } } };
    try std.testing.expectEqual(@as(i32, 0), convergentCurveOrdering(a, b));
}

test "curves that do not meet report no ordering" {
    const a: EdgeSegment = .{ .segment = .{ .linear = .{ .{ -1, 0 }, .{ 0, 0 } } } };
    const b: EdgeSegment = .{ .segment = .{ .linear = .{ .{ 5, 5 }, .{ 6, 6 } } } };
    try std.testing.expectEqual(@as(i32, 0), convergentCurveOrdering(a, b));
}

test "convergent quadratics are ordered by curvature" {
    // Both leave the origin heading -x, but bend to opposite sides, so the
    // ordering is decided and must invert when the two are swapped.
    const a: EdgeSegment = .{ .segment = .{ .quadratic_bezier = .{ .{ -2, 1 }, .{ -1, 0 }, .{ 0, 0 } } } };
    const b: EdgeSegment = .{ .segment = .{ .quadratic_bezier = .{ .{ 0, 0 }, .{ -1, 0 }, .{ -2, -1 } } } };
    const ab = convergentCurveOrdering(a, b);
    try std.testing.expect(ab != 0);

    const b_rev: EdgeSegment = .{ .segment = .{ .quadratic_bezier = .{ .{ -2, -1 }, .{ -1, 0 }, .{ 0, 0 } } } };
    const a_fwd: EdgeSegment = .{ .segment = .{ .quadratic_bezier = .{ .{ 0, 0 }, .{ -1, 0 }, .{ -2, 1 } } } };
    try std.testing.expectEqual(-ab, convergentCurveOrdering(b_rev, a_fwd));
}
