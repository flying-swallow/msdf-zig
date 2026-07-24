//! Distance selectors, ported from msdfgen's core/edge-selectors.cpp.
//!
//! A selector accumulates the contribution of every edge in the shape for one
//! sample point, then reports the distance. The perpendicular variants are what
//! separate a PSDF/MSDF from a plain SDF: near a corner the true distance to the
//! nearest edge is not the right answer, so each edge also contributes a
//! *perpendicular* distance over the domain bounded by the angle bisectors it
//! forms with its neighbours. That is why addEdge needs prev/next context.
//!
//! Deliberately omitted: msdfgen's EdgeCache / DISTANCE_DELTA_FACTOR. That cache
//! only skips edges which provably cannot improve a running minimum, so dropping
//! it is numerically identical -- every accumulation here is a min or a max, and
//! feeding a superset of edges through them yields the same result. It costs
//! speed, not accuracy. Restoring it (together with the boustrophedon scan in
//! msdfgen's generateDistanceField) is the main perf win still on the table.
//!
//! Only the single-selector-per-shape arrangement is modelled, matching
//! msdfgen's SimpleContourCombiner. msdf-zig has no overlapping-contour support,
//! so OverlappingContourCombiner has no analogue here.

const std = @import("std");

const EdgeColor = @import("edge_color.zig").EdgeColor;
const EdgeSegment = @import("EdgeSegment.zig");
const Contour = @import("Contour.zig");
const math = @import("math.zig");
const Shape = @import("Shape.zig");
const SignedDistance = @import("SignedDistance.zig");

const Vec2 = @Vector(2, f64);

const red = @intFromEnum(EdgeColor.red);
const green = @intFromEnum(EdgeColor.green);
const blue = @intFromEnum(EdgeColor.blue);

pub const MultiDistance = struct { r: f64, g: f64, b: f64 };
pub const MultiAndTrueDistance = struct { r: f64, g: f64, b: f64, a: f64 };

/// Nearest-edge true distance. Backs `sdf`.
pub const TrueDistanceSelector = struct {
    p: Vec2,
    min_distance: SignedDistance = .{},

    pub fn init(p: Vec2) TrueDistanceSelector {
        return .{ .p = p };
    }

    pub fn addEdge(self: *TrueDistanceSelector, _: *const EdgeSegment, edge: *const EdgeSegment, _: *const EdgeSegment) void {
        const d = edge.signedDistance(self.p)[1];
        if (d.lessThan(self.min_distance)) self.min_distance = d;
    }

    pub fn distance(self: TrueDistanceSelector) f64 {
        return self.min_distance.distance;
    }

    pub fn merge(self: *TrueDistanceSelector, other: TrueDistanceSelector) void {
        if (other.min_distance.lessThan(self.min_distance)) self.min_distance = other.min_distance;
    }
};

/// Shared state of the perpendicular selectors: one channel's worth of
/// accumulation. `MultiDistanceSelector` holds three of these.
pub const PerpendicularDistanceSelectorBase = struct {
    min_true_distance: SignedDistance = .{},
    // msdfgen seeds these from +-fabs(minTrueDistance.distance), which for the
    // default SignedDistance is the float maximum.
    min_negative_perpendicular_distance: f64 = -std.math.floatMax(f64),
    min_positive_perpendicular_distance: f64 = std.math.floatMax(f64),
    near_edge: ?*const EdgeSegment = null,
    near_edge_param: f64 = 0,

    pub fn addEdgeTrueDistance(
        self: *PerpendicularDistanceSelectorBase,
        edge: *const EdgeSegment,
        distance: SignedDistance,
        param: f64,
    ) void {
        if (distance.lessThan(self.min_true_distance)) {
            self.min_true_distance = distance;
            self.near_edge = edge;
            self.near_edge_param = param;
        }
    }

    pub fn addEdgePerpendicularDistance(self: *PerpendicularDistanceSelectorBase, distance: f64) void {
        if (distance <= 0 and distance > self.min_negative_perpendicular_distance)
            self.min_negative_perpendicular_distance = distance;
        if (distance >= 0 and distance < self.min_positive_perpendicular_distance)
            self.min_positive_perpendicular_distance = distance;
    }

    pub fn computeDistance(self: PerpendicularDistanceSelectorBase, p: Vec2) f64 {
        var min_distance = if (self.min_true_distance.distance < 0)
            self.min_negative_perpendicular_distance
        else
            self.min_positive_perpendicular_distance;
        if (self.near_edge) |edge| {
            // A null result means no perpendicular improvement, so the true
            // distance still competes — matching msdfgen, which leaves `distance`
            // as min_true_distance in that case.
            const distance = edge.distanceToPerpendicularDistance(self.min_true_distance, p, self.near_edge_param) orelse self.min_true_distance;
            if (@abs(distance.distance) < @abs(min_distance)) min_distance = distance.distance;
        }
        return min_distance;
    }

    pub fn trueDistance(self: PerpendicularDistanceSelectorBase) SignedDistance {
        return self.min_true_distance;
    }

    pub fn merge(self: *PerpendicularDistanceSelectorBase, other: PerpendicularDistanceSelectorBase) void {
        if (other.min_true_distance.lessThan(self.min_true_distance)) {
            self.min_true_distance = other.min_true_distance;
            self.near_edge = other.near_edge;
            self.near_edge_param = other.near_edge_param;
        }
        self.min_negative_perpendicular_distance = @max(self.min_negative_perpendicular_distance, other.min_negative_perpendicular_distance);
        self.min_positive_perpendicular_distance = @min(self.min_positive_perpendicular_distance, other.min_positive_perpendicular_distance);
    }
};

/// The angle-bisector domain of an edge relative to its neighbours.
///
/// `a` is how far past the start bisector the sample lies, `b` how far before
/// the end bisector; each is positive only where this edge owns the sample, so
/// the perpendicular extension applies there and nowhere else.
const DomainDistances = struct {
    a: f64,
    b: f64,
    ap: Vec2,
    bp: Vec2,
    a_dir: Vec2,
    b_dir: Vec2,
};

fn domainDistances(p: Vec2, prev_edge: *const EdgeSegment, edge: *const EdgeSegment, next_edge: *const EdgeSegment) DomainDistances {
    const ap = p - edge.point(0);
    const bp = p - edge.point(1);
    // msdfgen normalizes with allowZero = true here; math.normal's flag is the
    // negation of that, hence `false`.
    const a_dir = math.normal(edge.direction(0), false);
    const b_dir = math.normal(edge.direction(1), false);
    const prev_dir = math.normal(prev_edge.direction(1), false);
    const next_dir = math.normal(next_edge.direction(0), false);
    return .{
        .a = math.dot(ap, math.normal(prev_dir + a_dir, false)),
        .b = -math.dot(bp, math.normal(b_dir + next_dir, false)),
        .ap = ap,
        .bp = bp,
        .a_dir = a_dir,
        .b_dir = b_dir,
    };
}

/// Single-channel perpendicular distance. Backs `psdf`.
pub const PerpendicularDistanceSelector = struct {
    p: Vec2,
    base: PerpendicularDistanceSelectorBase = .{},

    pub fn init(p: Vec2) PerpendicularDistanceSelector {
        return .{ .p = p };
    }

    pub fn addEdge(
        self: *PerpendicularDistanceSelector,
        prev_edge: *const EdgeSegment,
        edge: *const EdgeSegment,
        next_edge: *const EdgeSegment,
    ) void {
        const param, const sd = edge.signedDistance(self.p);
        self.base.addEdgeTrueDistance(edge, sd, param);

        const d = domainDistances(self.p, prev_edge, edge, next_edge);
        if (d.a > 0) {
            if (math.perpendicularDistance(sd.distance, d.ap, -d.a_dir)) |pd|
                self.base.addEdgePerpendicularDistance(-pd);
        }
        if (d.b > 0) {
            if (math.perpendicularDistance(sd.distance, d.bp, d.b_dir)) |pd|
                self.base.addEdgePerpendicularDistance(pd);
        }
    }

    pub fn distance(self: PerpendicularDistanceSelector) f64 {
        return self.base.computeDistance(self.p);
    }

    pub fn merge(self: *PerpendicularDistanceSelector, other: PerpendicularDistanceSelector) void {
        self.base.merge(other.base);
    }
};

/// Three independent perpendicular channels, routed by edge color. Backs `msdf`.
pub const MultiDistanceSelector = struct {
    p: Vec2,
    r: PerpendicularDistanceSelectorBase = .{},
    g: PerpendicularDistanceSelectorBase = .{},
    b: PerpendicularDistanceSelectorBase = .{},

    pub fn init(p: Vec2) MultiDistanceSelector {
        return .{ .p = p };
    }

    pub fn addEdge(
        self: *MultiDistanceSelector,
        prev_edge: *const EdgeSegment,
        edge: *const EdgeSegment,
        next_edge: *const EdgeSegment,
    ) void {
        const color = @intFromEnum(edge.color);
        const param, const sd = edge.signedDistance(self.p);
        if (color & red != 0) self.r.addEdgeTrueDistance(edge, sd, param);
        if (color & green != 0) self.g.addEdgeTrueDistance(edge, sd, param);
        if (color & blue != 0) self.b.addEdgeTrueDistance(edge, sd, param);

        const d = domainDistances(self.p, prev_edge, edge, next_edge);
        if (d.a > 0) {
            if (math.perpendicularDistance(sd.distance, d.ap, -d.a_dir)) |pd| {
                const npd = -pd;
                if (color & red != 0) self.r.addEdgePerpendicularDistance(npd);
                if (color & green != 0) self.g.addEdgePerpendicularDistance(npd);
                if (color & blue != 0) self.b.addEdgePerpendicularDistance(npd);
            }
        }
        if (d.b > 0) {
            if (math.perpendicularDistance(sd.distance, d.bp, d.b_dir)) |pd| {
                if (color & red != 0) self.r.addEdgePerpendicularDistance(pd);
                if (color & green != 0) self.g.addEdgePerpendicularDistance(pd);
                if (color & blue != 0) self.b.addEdgePerpendicularDistance(pd);
            }
        }
    }

    pub fn distance(self: MultiDistanceSelector) MultiDistance {
        return .{
            .r = self.r.computeDistance(self.p),
            .g = self.g.computeDistance(self.p),
            .b = self.b.computeDistance(self.p),
        };
    }

    /// The nearest true distance across the three channels. Becomes the alpha of
    /// an MTSDF.
    pub fn trueDistance(self: MultiDistanceSelector) SignedDistance {
        var d = self.r.trueDistance();
        if (self.g.trueDistance().lessThan(d)) d = self.g.trueDistance();
        if (self.b.trueDistance().lessThan(d)) d = self.b.trueDistance();
        return d;
    }

    pub fn multiAndTrueDistance(self: MultiDistanceSelector) MultiAndTrueDistance {
        const md = self.distance();
        return .{ .r = md.r, .g = md.g, .b = md.b, .a = self.trueDistance().distance };
    }

    pub fn merge(self: *MultiDistanceSelector, other: MultiDistanceSelector) void {
        self.r.merge(other.r);
        self.g.merge(other.g);
        self.b.merge(other.b);
    }
};

/// Drives `selector` over every edge of `shape`, handing each one its cyclic
/// prev/next neighbours. Mirrors msdfgen's ShapeDistanceFinder::distance walk.
pub fn accumulate(selector: anytype, shape: Shape) void {
    for (shape.contours.items) |contour| {
        accumulateContour(selector, contour);
    }
}

pub fn accumulateContour(selector: anytype, contour: Contour) void {
    const edges = contour.edges.items;
    if (edges.len == 0) return;
    var prev_edge: *const EdgeSegment = if (edges.len >= 2) &edges[edges.len - 2] else &edges[0];
    var cur_edge: *const EdgeSegment = &edges[edges.len - 1];
    for (edges) |*next_edge| {
        selector.addEdge(prev_edge, cur_edge, next_edge);
        prev_edge = cur_edge;
        cur_edge = next_edge;
    }
}

fn resolveDistance(distance: anytype) f64 {
    return switch (@typeInfo(@TypeOf(distance))) {
        .float => distance,
        else => math.median(distance.r, distance.g, distance.b),
    };
}

/// msdfgen's `OverlappingContourCombiner`, using caller-owned per-contour
/// selector storage so rasterization does not allocate per texel.
pub fn accumulateOverlapping(comptime Selector: type, selectors: []Selector, shape: Shape, p: Vec2) Selector {
    var shape_selector = Selector.init(p);
    var inner_selector = Selector.init(p);
    var outer_selector = Selector.init(p);
    for (shape.contours.items, selectors) |contour, *selector| {
        selector.* = Selector.init(p);
        accumulateContour(selector, contour);
        const contour_distance = selector.distance();
        shape_selector.merge(selector.*);
        if (contour.winding() > 0 and resolveDistance(contour_distance) >= 0)
            inner_selector.merge(selector.*);
        if (contour.winding() < 0 and resolveDistance(contour_distance) <= 0)
            outer_selector.merge(selector.*);
    }
    const shape_distance = shape_selector.distance();
    const inner_distance = inner_selector.distance();
    const outer_distance = outer_selector.distance();
    var distance: Selector = undefined;
    var winding: i32 = 0;
    if (resolveDistance(inner_distance) >= 0 and @abs(resolveDistance(inner_distance)) <= @abs(resolveDistance(outer_distance))) {
        distance = inner_selector;
        winding = 1;
        for (shape.contours.items, selectors) |contour, selector| if (contour.winding() > 0) {
            const candidate = selector.distance();
            if (@abs(resolveDistance(candidate)) < @abs(resolveDistance(outer_distance)) and resolveDistance(candidate) > resolveDistance(distance.distance()))
                distance = selector;
        };
    } else if (resolveDistance(outer_distance) <= 0 and @abs(resolveDistance(outer_distance)) < @abs(resolveDistance(inner_distance))) {
        distance = outer_selector;
        winding = -1;
        for (shape.contours.items, selectors) |contour, selector| if (contour.winding() < 0) {
            const candidate = selector.distance();
            if (@abs(resolveDistance(candidate)) < @abs(resolveDistance(inner_distance)) and resolveDistance(candidate) < resolveDistance(distance.distance()))
                distance = selector;
        };
    } else return shape_selector;
    for (shape.contours.items, selectors) |contour, selector| if (contour.winding() != winding) {
        const candidate = selector.distance();
        if (resolveDistance(candidate) * resolveDistance(distance.distance()) >= 0 and @abs(resolveDistance(candidate)) < @abs(resolveDistance(distance.distance())))
            distance = selector;
    };
    return if (resolveDistance(distance.distance()) == resolveDistance(shape_distance)) shape_selector else distance;
}
