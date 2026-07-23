const std = @import("std");

const edge_color = @import("edge_color.zig");
const EdgeColor = edge_color.EdgeColor;
const Seed = edge_color.Seed;
const EdgeSegment = @import("EdgeSegment.zig");
const math = @import("math.zig");
const Shape = @import("Shape.zig");

const Vec2 = @Vector(2, f64);

/// For each position < n, returns -1, 0, or 1 depending on whether the position
/// is closer to the beginning, middle, or end. Balanced: the total over
/// positions 0..n-1 is zero.
fn symmetricalTrichotomy(pos: usize, n: usize) i32 {
    const fpos: f64 = @floatFromInt(pos);
    const fn1: f64 = @floatFromInt(n - 1);
    return @as(i32, @intFromFloat(@floor(3 + 2.875 * fpos / fn1 - 1.4375 + 0.5))) - 3;
}

fn isCorner(a: Vec2, b: Vec2, cross_threshold: f64) bool {
    return math.dot(a, b) <= 0 or @abs(math.cross(a, b)) > cross_threshold;
}

/// Port of msdfgen's `edgeColoringSimple`.
pub fn colorShape(allocator: std.mem.Allocator, shape: *Shape, angle_threshold: f64, seed_value: u64) !void {
    const cross_threshold = @sin(angle_threshold);
    var seed: Seed = .init(seed_value);
    var color: EdgeColor = seed.initColor();
    var corners: std.ArrayList(u32) = .empty;
    defer corners.deinit(allocator);

    for (shape.contours.items) |*contour| {
        if (contour.edges.items.len == 0) continue;

        // Identify corners
        corners.clearRetainingCapacity();
        var prev_dir = contour.edges.getLast().?.direction(1);
        for (contour.edges.items, 0..) |edge, i| {
            if (isCorner(math.normal(prev_dir, true), math.normal(edge.direction(0), true), cross_threshold))
                try corners.append(allocator, @intCast(i));
            prev_dir = edge.direction(1);
        }

        switch (corners.items.len) {
            // Smooth contour
            0 => {
                seed.switchColor(&color);
                for (contour.edges.items) |*edge| edge.color = color;
            },
            // "Teardrop" case
            1 => {
                var colors: [3]EdgeColor = undefined;
                seed.switchColor(&color);
                colors[0] = color;
                colors[1] = .white;
                seed.switchColor(&color);
                colors[2] = color;

                const corner = corners.items[0];
                const m = contour.edges.items.len;
                if (m >= 3) {
                    // The pattern is anchored at the corner, so the walk starts
                    // there and wraps.
                    for (0..m) |i|
                        contour.edges.items[(corner + i) % m].color =
                            colors[@intCast(1 + symmetricalTrichotomy(i, m))];
                } else {
                    // Fewer than three edges for three colors, so they must be
                    // split. `parts` is laid out so that the corner's edge always
                    // occupies the first slot of its triple.
                    var parts: [7]EdgeSegment = @splat(.{});
                    var filled: [7]bool = @splat(false);
                    const base = 3 * corner;
                    parts[base..][0..3].* = contour.edges.items[0].splitInThirds();
                    for (base..base + 3) |i| filled[i] = true;
                    if (m >= 2) {
                        const other = 3 - 3 * corner;
                        parts[other..][0..3].* = contour.edges.items[1].splitInThirds();
                        for (other..other + 3) |i| filled[i] = true;
                        parts[0].color = colors[0];
                        parts[1].color = colors[0];
                        parts[2].color = colors[1];
                        parts[3].color = colors[1];
                        parts[4].color = colors[2];
                        parts[5].color = colors[2];
                    } else {
                        parts[0].color = colors[0];
                        parts[1].color = colors[1];
                        parts[2].color = colors[2];
                    }
                    contour.edges.clearRetainingCapacity();
                    for (parts, filled) |part, is_filled|
                        if (is_filled) try contour.edges.append(allocator, part);
                }
            },
            // Multiple corners
            else => {
                const corner_count = corners.items.len;
                var spline: u32 = 0;
                const start = corners.items[0];
                const m = contour.edges.items.len;
                seed.switchColor(&color);
                const initial_color = color;
                for (0..m) |i| {
                    const index = (start + i) % m;
                    if (spline + 1 < corner_count and corners.items[spline + 1] == index) {
                        spline += 1;
                        // Banning the initial color on the last spline keeps the
                        // wrap-around seam from repeating a color.
                        seed.switchColorBanned(
                            &color,
                            if (spline == corner_count - 1) initial_color else .black,
                        );
                    }
                    contour.edges.items[index].color = color;
                }
            },
        }
    }
}
