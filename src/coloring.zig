const std = @import("std");

const EdgeColor = @import("edge_color.zig").EdgeColor;
const EdgeSegment = @import("EdgeSegment.zig");
const math = @import("math.zig");
const Shape = @import("Shape.zig");

const Vec2 = @Vector(2, f64);

fn symmetricalTrichotomy(pos: usize, n: usize) i32 {
    const fpos: f64 = @floatFromInt(pos);
    const fn1: f64 = @floatFromInt(n - 1);
    return @as(i32, @intFromFloat(@floor(3 + 2.875 * fpos / fn1 - 1.4375 + 0.5))) - 3;
}

pub fn colorShape(
    allocator: std.mem.Allocator,
    rng_seed: u64,
    shape: *Shape,
    angle_threshold: f64,
) !void {
    const cross_threshold = @sin(angle_threshold);

    var rng: std.Random.DefaultPrng = .init(rng_seed);
    var color: EdgeColor = .init(&rng);

    var corners: std.ArrayList(u32) = .empty;
    defer corners.deinit(allocator);

    for (shape.contours.items) |*contour| {
        if (contour.edges.items.len == 0)
            continue;

        corners.clearRetainingCapacity();
        var prev_dir = math.normal(contour.edges.getLast().direction(1), true);
        for (contour.edges.items, 0..) |edge, i| {
            const edge_dir = math.normal(edge.direction(0), true);
            if (math.dot(prev_dir, edge_dir) <= 0 or
                @abs(math.cross(prev_dir, edge_dir)) > cross_threshold)
                try corners.append(allocator, @intCast(i));

            prev_dir = math.normal(edge.direction(1), true);
        }

        const corners_len = corners.items.len;
        switch (corners_len) {
            0 => {
                color.random(&rng);
                for (contour.edges.items) |*edge| edge.color = color;
            },
            1 => {
                const colors: [3]EdgeColor = .{ .init(&rng), .white, .init(&rng) };
                const corner = corners.items[0];
                const corner_idx = 3 * corner;
                const edges_len = contour.edges.items.len;
                if (edges_len >= 3) {
                    for (contour.edges.items, 0..) |*edge, i| edge.color = colors[@intCast(1 + symmetricalTrichotomy(i, edges_len))];
                } else if (edges_len >= 1) {
                    var parts: [7]EdgeSegment = @splat(.{});
                    contour.edges.items[0].splitInThirds(parts[corner_idx..][0..3]);
                    if (edges_len >= 2) {
                        contour.edges.items[1].splitInThirds(parts[3 - corner_idx ..][0..3]);
                        for (0..6) |i| parts[i].color = colors[@divFloor(i, 2)];
                    } else for (0..3) |i| parts[i].color = colors[i];
                    contour.edges.clearRetainingCapacity();
                    for (0..@min(corner_idx, 3 - corner_idx)) |i|
                        try contour.edges.append(allocator, parts[i]);
                }
            },
            else => {
                const start = corners.items[0];
                const edges_len = contour.edges.items.len;

                color.random(&rng);
                const initial_color = color;

                var spline: u32 = 0;
                for (0..edges_len) |i| {
                    const idx = (start + i) % edges_len;
                    if (spline + 1 < corners_len and corners.items[spline + 1] == idx) {
                        spline += 1;
                        color.change(&rng, if (spline == corners_len - 1) initial_color else .black);
                    }
                    contour.edges.items[idx].color = color;
                }
            },
        }
    }
}
