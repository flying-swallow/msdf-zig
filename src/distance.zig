const coloring = @import("coloring.zig");
const EdgeColor = coloring.EdgeColor;
const EdgeSegment = @import("EdgeSegment.zig");
const Shape = @import("Shape.zig");
const SdfType = @import("sdf_types.zig").SdfType;

const Vec2 = @Vector(2, f64);

fn pxRangeNorm(dist: f64, px_range: f64) f64 {
    return (dist + px_range / 2.0) / px_range;
}

pub fn findDistanceAt(
    comptime sdf_type: SdfType,
    shape: Shape,
    p: Vec2,
    px_range: f64,
) switch (sdf_type) {
    .sdf, .psdf => f64,
    inline .msdf, .msdf10, .mtsdf => |ty| [ty.numChannels()]f64,
} {
    const PsdfData = struct {
        dist: EdgeSegment.SignedDist = .init,
        edge: ?*const EdgeSegment = null,
        point_pos: EdgeSegment.PointPosition = .within_segment,
    };

    var true_ch: EdgeSegment.SignedDist = .init;
    var perp_ch: [if (sdf_type == .psdf) 1 else 3]PsdfData = @splat(.{});
    for (shape.contours.items) |contour| for (contour.edges.items) |*edge| {
        const dist, const point_pos = edge.signedDistance(p);

        switch (sdf_type) {
            .sdf, .mtsdf => if (dist.lessThan(true_ch)) {
                true_ch = dist;
            },
            .psdf => if (dist.lessThan(perp_ch[0].dist)) {
                perp_ch[0] = .{
                    .dist = dist,
                    .edge = edge,
                    .point_pos = point_pos,
                };
            },
            else => {},
        }

        if (sdf_type != .sdf and sdf_type != .psdf)
            for ([_]struct { channel: EdgeColor, target: *PsdfData }{
                .{ .channel = .red, .target = &perp_ch[0] },
                .{ .channel = .green, .target = &perp_ch[1] },
                .{ .channel = .blue, .target = &perp_ch[2] },
            }) |params|
                if (edge.color.hasChannel(params.channel) and dist.lessThan(params.target.dist)) {
                    params.target.* = .{
                        .dist = dist,
                        .edge = edge,
                        .point_pos = point_pos,
                    };
                };
    };

    if (sdf_type != .sdf) for (&perp_ch) |*psdf|
        if (psdf.edge) |edge|
            edge.perpDistConvert(&psdf.dist, p, psdf.point_pos);

    return switch (sdf_type) {
        .sdf => pxRangeNorm(true_ch.distance, px_range),
        .psdf => pxRangeNorm(perp_ch[0].dist.distance, px_range),
        .msdf, .msdf10 => .{
            pxRangeNorm(perp_ch[0].dist.distance, px_range),
            pxRangeNorm(perp_ch[1].dist.distance, px_range),
            pxRangeNorm(perp_ch[2].dist.distance, px_range),
        },
        .mtsdf => .{
            pxRangeNorm(perp_ch[0].dist.distance, px_range),
            pxRangeNorm(perp_ch[1].dist.distance, px_range),
            pxRangeNorm(perp_ch[2].dist.distance, px_range),
            pxRangeNorm(true_ch.distance, px_range),
        },
    };
}
