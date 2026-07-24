const std = @import("std");

const Contour = @import("Contour.zig");
const EdgeSegment = @import("EdgeSegment.zig");
const math = @import("math.zig");
const Vec2 = @Vector(2, f64);

edges: std.ArrayList(EdgeSegment) = .empty,

pub fn winding(self: Contour) i32 {
    if (self.edges.items.len == 0) return 0;
    const shoelace = struct {
        fn at(a: Vec2, b: Vec2) f64 {
            return (b[0] - a[0]) * (a[1] + b[1]);
        }
    }.at;
    var total: f64 = 0;
    if (self.edges.items.len == 1) {
        const edge = self.edges.items[0];
        const a = edge.point(0);
        const b = edge.point(1.0 / 3.0);
        const c = edge.point(2.0 / 3.0);
        total = shoelace(a, b) + shoelace(b, c) + shoelace(c, a);
    } else if (self.edges.items.len == 2) {
        const a = self.edges.items[0].point(0);
        const b = self.edges.items[0].point(0.5);
        const c = self.edges.items[1].point(0);
        const d = self.edges.items[1].point(0.5);
        total = shoelace(a, b) + shoelace(b, c) + shoelace(c, d) + shoelace(d, a);
    } else {
        var prev = self.edges.items[self.edges.items.len - 1].point(0);
        for (self.edges.items) |edge| {
            const cur = edge.point(0);
            total += shoelace(prev, cur);
            prev = cur;
        }
    }
    return @as(i32, @intFromBool(total > 0)) - @as(i32, @intFromBool(total < 0));
}

pub fn bound(self: Contour, a: math.RectangleBound(f64)) math.RectangleBound(f64) {
    var bounds = a;
    for (self.edges.items) |edge| bounds = edge.bound(bounds);
    return bounds;
}

pub fn boundMiters(self: Contour, a: math.RectangleBound(f64), border: f64, miter_limit: f64, polarity: i32) math.RectangleBound(f64) {
    var bounds = a;
    if (self.edges.items.len == 0) return bounds;
    var prev_dir = math.normal(self.edges.items[self.edges.items.len - 1].direction(1), false);
    for (self.edges.items) |edge| {
        const dir = math.normal(edge.direction(0), false) * math.v2(-1.0);
        if (@as(f64, @floatFromInt(polarity)) * math.cross(prev_dir, dir) >= 0) {
            var miter_length = miter_limit;
            const q = 0.5 * (1 - math.dot(prev_dir, dir));
            if (q > 0) miter_length = @min(1 / @sqrt(q), miter_limit);
            const miter = edge.point(0) + math.normal(prev_dir + dir, false) * math.v2(border * miter_length);
            bounds = bounds.addPoint(miter);
        }
        prev_dir = math.normal(edge.direction(1), false);
    }
    return bounds;
}

pub fn reverse(self: *Contour) void {
    std.mem.reverse(EdgeSegment, self.edges.items);
    for (self.edges.items) |*edge| edge.reverse();
}
