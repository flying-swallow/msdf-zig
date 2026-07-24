const std = @import("std");

const Contour = @import("Contour.zig");
const convergent_curve_ordering = @import("convergent_curve_ordering.zig");
const EdgeSegment = @import("EdgeSegment.zig");
const math = @import("math.zig");
const Scanline = @import("Scanline.zig");

const Vec2 = @Vector(2, f64);

const deconverge_overshoot = 1.11111111111111111;
const corner_dot_epsilon = 0.000001;

const Shape = @This();
pub const Bounds = struct {
    left: f64 = 0.0,
    right: f64 = 0.0,
    bottom: f64 = 0.0,
    top: f64 = 0.0,
};

contours: std.ArrayList(Contour) = .empty,

pub fn format(self: Shape, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("Number of contours: {}\n", .{self.contours.items.len});
    for (self.contours.items, 0..) |contour, i| {
        try writer.print("Contour {}: [\n", .{i});
        for (contour.edges.items, 0..) |edge, j| try writer.print(" Edge {}: {f}\n", .{ j, edge });
        try writer.print("];\n", .{});
    }
}

pub fn validate(self: Shape) bool {
    for (self.contours.items) |contour| if (contour.edges.items.len > 0) {
        var corner = contour.edges.items[contour.edges.items.len - 1].point(1);
        for (contour.edges.items) |edge| {
            const p0 = edge.point(0);
            if (!std.meta.eql(p0, corner)) return false;
            corner = edge.point(1);
        }
    };

    return true;
}

pub fn normalize(self: *Shape, allocator: std.mem.Allocator) !void {
    for (self.contours.items) |*contour| {
        if (contour.edges.items.len == 1) {
            const parts = contour.edges.items[0].splitInThirds();
            contour.edges.clearRetainingCapacity();
            try contour.edges.appendSlice(allocator, &parts);
        } else if (contour.edges.items.len > 0) {
            var prev_edge = &contour.edges.items[contour.edges.items.len - 1];
            for (contour.edges.items) |*edge| {
                const prev_dir = math.normal(prev_edge.direction(1), true);
                const cur_dir = math.normal(edge.direction(0), true);
                if (math.dot(prev_dir, cur_dir) < corner_dot_epsilon - 1) {
                    const factor = deconverge_overshoot *
                        @sqrt(1 - (corner_dot_epsilon - 1) * (corner_dot_epsilon - 1)) / (corner_dot_epsilon - 1);
                    var axis = math.normal(cur_dir - prev_dir, true) * math.v2(factor);
                    if (convergent_curve_ordering.convergentCurveOrdering(prev_edge.*, edge.*) < 0)
                        axis *= math.v2(-1.0);
                    prev_edge.* = prev_edge.deconverge(1, math.ortho(axis, true));
                    edge.* = edge.deconverge(0, math.ortho(axis, false));
                }
                prev_edge = edge;
            }
        }
    }
}

pub fn bound(self: Shape, a: math.RectangleBound(f64)) math.RectangleBound(f64) {
    var bounds = a;
    for (self.contours.items) |contour| bounds = contour.bound(bounds);
    return bounds;
}

pub fn boundMiters(self: Shape, a: math.RectangleBound(f64), border: f64, miter_limit: f64, polarity: i32) math.RectangleBound(f64) {
    var bounds = a;
    for (self.contours.items) |contour| bounds = contour.boundMiters(bounds, border, miter_limit, polarity);
    return bounds;
}

pub fn getBounds(self: Shape, border: f64, miter_limit: f64, polarity: i32) Bounds {
    var bounds = self.bound(.empty);
    if (border > 0) {
        bounds.l -= border;
        bounds.b -= border;
        bounds.r += border;
        bounds.t += border;
        if (miter_limit > 0)
            bounds = self.boundMiters(bounds, border, miter_limit, polarity);
    }
    return .{ .left = bounds.l, .bottom = bounds.b, .right = bounds.r, .top = bounds.t };
}

pub fn scanline(self: Shape, line: *Scanline, y: f64, allocator: std.mem.Allocator) !void {
    line.intersections.clearRetainingCapacity();
    defer line.preprocess();

    var x: [3]f64 = @splat(0.0);
    var dy: [3]i32 = @splat(0);
    for (self.contours.items) |contour| for (contour.edges.items) |edge| {
        const len = edge.scanlineIntersections(&x, &dy, y);
        for (0..len) |i| try line.intersections.append(allocator, .{ .x = x[i], .dir = dy[i] });
    };
}

pub fn orientContours(self: *Shape, allocator: std.mem.Allocator) !void {
    const Intersection = struct {
        x: f64,
        direction: i32,
        contour_index: i32,

        pub fn lessThan(_: void, a: @This(), b: @This()) bool {
            return a.x < b.x;
        }
    };

    const ratio = 0.5 * (@sqrt(5.0) - 1);
    var intersections: std.ArrayList(Intersection) = .empty;
    defer intersections.deinit(allocator);
    var orientations: std.ArrayList(i32) = .empty;
    defer orientations.deinit(allocator);
    const contours_len = self.contours.items.len;
    try orientations.ensureTotalCapacity(allocator, contours_len);
    try orientations.appendNTimes(allocator, 0, contours_len);
    for (0..contours_len) |i| {
        // Skip contours already resolved by an earlier scanline, and empty ones.
        // Note the polarity: a zero orientation means "not yet determined", so
        // that is exactly the case this loop exists to handle.
        if (orientations.items[i] != 0 or self.contours.items[i].edges.items.len == 0) continue;

        // Find a Y that actually crosses the contour. Both loops stop as soon as
        // they find one -- without the guard the last edge would simply win, and
        // the second pass (which samples mid-edge, for contours whose endpoints
        // are all colinear in Y) would clobber the first.
        const y0 = self.contours.items[i].edges.items[0].point(0)[1];
        var y1 = y0;
        for (self.contours.items[i].edges.items) |edge| {
            if (y0 != y1) break;
            y1 = edge.point(1)[1];
        }
        for (self.contours.items[i].edges.items) |edge| {
            if (y0 != y1) break;
            y1 = edge.point(ratio)[1];
        }
        const y = math.mix(y0, y1, ratio);
        var x: [3]f64 = @splat(0.0);
        var dy: [3]i32 = @splat(0);
        for (0..self.contours.items.len) |j|
            for (self.contours.items[j].edges.items) |edge|
                for (0..edge.scanlineIntersections(&x, &dy, y)) |k|
                    try intersections.append(allocator, .{ .x = x[k], .direction = dy[k], .contour_index = @intCast(j) });

        if (intersections.items.len == 0) continue;
        std.sort.pdq(Intersection, intersections.items, {}, Intersection.lessThan);
        for (1..intersections.items.len) |j| if (intersections.items[j].x == intersections.items[j - 1].x) {
            intersections.items[j].direction = 0;
            intersections.items[j - 1].direction = 0;
        };
        for (0..intersections.items.len) |j| if (intersections.items[j].direction != 0) {
            orientations.items[@intCast(intersections.items[j].contour_index)] +=
                2 * ((@as(i32, @intCast(j)) & 1) ^ @intFromBool(intersections.items[j].direction > 0)) - 1;
        };
        intersections.clearRetainingCapacity();
    }

    for (self.contours.items, orientations.items) |*contour, orientation| if (orientation < 0) contour.reverse();
}
