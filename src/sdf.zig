const std = @import("std");

const coloring = @import("coloring.zig");
const distance_eval = @import("distance.zig");
const ErrorCorrection = @import("ErrorCorrection.zig");
const math = @import("math.zig");
const Scanline = @import("Scanline.zig");
const Shape = @import("Shape.zig");
const types = @import("sdf_types.zig");

const Vec2 = @Vector(2, f64);
const f64i = math.f64i;

pub const SdfType = types.SdfType;
pub const ColoringMethod = types.ColoringMethod;
pub const Winding = types.Winding;
pub const Msdf10Pixel = types.Msdf10Pixel;

pub const Options = struct {
    sdf_type: SdfType,
    px_size: u16,
    px_range: u16,
    /// Has no effect if `sdf_type.requiresColoring()` is false.
    coloring_rng_seed: u64 = 0,
    /// The method with which to perform the MSDF 3-coloring.
    /// While the implementations are based on msdfgen, they're (intentionally)
    /// not equivalent, but should resolve corners similarly well.
    ///
    /// Has no effect if `sdf_type.requiresColoring()` is false.
    coloring_method: ColoringMethod = .distance,
    /// The angle which is considered to be a corner, in radians.
    corner_angle_threshold: f64 = 3.0,
    winding: Winding = .guess,
    /// Validates that the given (or generated) shapes' contours form a
    /// closed loop, with each edge connecting to each other properly.
    validate_shape: bool = false,
    normalize_shape: bool = false,
    orient_contours: bool = false,
    /// Requires `orient_contours` to be disabled.
    scanline_fill_rule: ?Scanline.FillRule = null,
    /// Only MSDFs (both their normal and their 10-bit versions) and MTSDFs can be error corrected.
    error_correction_opts: ?ErrorCorrection.Options = .{},
};

pub const findDistanceAt = distance_eval.findDistanceAt;

pub const ShapeData = struct {
    pixels: []const u8,
    width: u16,
    height: u16,

    pub fn deinit(self: ShapeData, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// Rasterize a caller-owned shape without loading a font.
///
/// Shape preprocessing and coloring follow the same options and mutate the
/// shape in the same way as `Generator.generateSingle`.
pub fn generateFromShape(
    allocator: std.mem.Allocator,
    shape: *Shape,
    opts: *const Options,
) !ShapeData {
    if (opts.validate_shape and !shape.validate()) return error.InvalidShape;
    if (opts.orient_contours) try shape.orientContours(allocator);
    if (opts.normalize_shape) try shape.normalize(allocator);

    const px_size = f64i(opts.px_size);
    const px_range = f64i(opts.px_range) / px_size;

    var bounds = shape.calcBounds();
    if (bounds.left >= bounds.right or bounds.bottom >= bounds.top)
        bounds = .whole_frame;

    const bound_w = bounds.right - bounds.left;
    const bound_h = bounds.top - bounds.bottom;
    const width: u16 = @trunc((bound_w + px_range) * px_size);
    const height: u16 = @trunc((bound_h + px_range) * px_size);

    if (opts.winding == .negative or
        opts.winding == .guess and findDistanceAt(
            .sdf,
            shape.*,
            .{
                bounds.left - px_range - bound_w - 1.0,
                bounds.bottom - px_range - bound_h - 1.0,
            },
            px_range,
        ) > 0) for (shape.contours.items) |*contour| contour.reverse();

    return .{
        .width = width,
        .height = height,
        .pixels = try getSdfPixels(
            allocator,
            opts,
            width,
            height,
            shape,
            .{
                bounds.left - px_range / 2.0,
                bounds.bottom - px_range / 2.0,
            },
        ),
    };
}

pub fn getSdfPixels(
    allocator: std.mem.Allocator,
    opts: *const Options,
    w: u16,
    h: u16,
    shape: *Shape,
    tfm: Vec2,
) ![]const u8 {
    const px_size = f64i(opts.px_size);
    const px_range = f64i(opts.px_range) / px_size;

    var error_correction: ?ErrorCorrection = null;
    if (opts.sdf_type == .msdf or
        opts.sdf_type == .mtsdf or
        opts.sdf_type == .msdf10)
        if (opts.error_correction_opts) |ec_opts| {
            error_correction = try .create(allocator, shape, w, h, ec_opts, opts.scanline_fill_rule != null);
        };
    defer if (error_correction) |*ec| ec.destroy(allocator);

    const channels = opts.sdf_type.numChannels();
    const dist_pixels = try allocator.alloc(f64, @as(usize, w) * @as(usize, h) * @as(usize, channels));
    defer allocator.free(dist_pixels);

    switch (opts.sdf_type) {
        inline else => |ty| {
            if (ty.requiresColoring()) switch (opts.coloring_method) {
                .simple => try coloring.colorSimple(allocator, opts.coloring_rng_seed, shape, opts.corner_angle_threshold),
                .ink_trap => try coloring.colorInkTrap(allocator, opts.coloring_rng_seed, shape, opts.corner_angle_threshold),
                .distance => try coloring.colorDistance(allocator, opts.coloring_rng_seed, shape, opts.corner_angle_threshold),
            };
            generate(ty, dist_pixels, w, h, px_size, shape.*, px_range, tfm);
        },
    }

    if (!opts.orient_contours)
        if (opts.scanline_fill_rule) |fill_rule|
            switch (opts.sdf_type) {
                .sdf, .psdf => try sdfSignCorrection(
                    allocator,
                    dist_pixels,
                    w,
                    h,
                    px_size,
                    shape.*,
                    tfm,
                    fill_rule,
                ),
                .msdf, .msdf10, .mtsdf => try msdfSignCorrection(
                    allocator,
                    dist_pixels,
                    w,
                    h,
                    px_size,
                    shape.*,
                    tfm,
                    fill_rule,
                    channels,
                ),
            };

    if (error_correction) |*ec|
        ec.correct(shape, px_size, px_range, tfm, dist_pixels, w, h, channels);

    const mod_channels = if (opts.sdf_type == .msdf10)
        4
    else
        opts.sdf_type.numChannels();
    const pixels = try allocator.alloc(u8, @as(usize, w) * @as(usize, h) * @as(usize, mod_channels));

    for (0..h) |y| for (0..w) |x| {
        const pixel_idx = y * w * mod_channels + x * mod_channels;
        const distance_idx = y * w * channels + x * channels;
        if (opts.sdf_type == .msdf10)
            pixels[y * w * 4 + x * 4 ..][0..4].* = std.mem.toBytes(Msdf10Pixel{
                .r = math.floatToUnorm(u10, dist_pixels[distance_idx]),
                .g = math.floatToUnorm(u10, dist_pixels[distance_idx + 1]),
                .b = math.floatToUnorm(u10, dist_pixels[distance_idx + 2]),
                .a = std.math.maxInt(u2),
            })
        else for (0..mod_channels) |i|
            pixels[pixel_idx + i] = math.floatToUnorm(u8, dist_pixels[distance_idx + i]);
    };
    return pixels;
}

fn sdfSignCorrection(
    allocator: std.mem.Allocator,
    out_pixels: []f64,
    w: u16,
    h: u16,
    scale: f64,
    shape: Shape,
    tfm: Vec2,
    fill_rule: Scanline.FillRule,
) !void {
    var scanline: Scanline = .{};
    defer scanline.intersections.deinit(allocator);
    for (0..h) |y| {
        const row = h - y - 1;
        try shape.scanline(&scanline, (f64i(y) + 0.5) / scale + tfm[1], allocator);
        for (0..w) |x| {
            const idx = row * w + x;
            const distance = out_pixels[idx];
            if ((distance > 0.5) != scanline.filled((f64i(x) + 0.5) / scale + tfm[0], fill_rule))
                out_pixels[idx] = 1.0 - distance;
        }
    }
}

fn msdfSignCorrection(
    allocator: std.mem.Allocator,
    out_pixels: []f64,
    w: u16,
    h: u16,
    scale: f64,
    shape: Shape,
    tfm: Vec2,
    fill_rule: Scanline.FillRule,
    channels: u8,
) !void {
    var scanline: Scanline = .{};
    defer scanline.intersections.deinit(allocator);

    const match_map = try allocator.alloc(i32, w * h);
    defer allocator.free(match_map);
    @memset(match_map, 0);

    var ambiguous = false;
    var match_idx: usize = 0;
    const scaled_w = w * channels;
    for (0..h) |y| {
        const row = h - y - 1;
        try shape.scanline(&scanline, (f64i(y) + 0.5) / scale + tfm[1], allocator);
        for (0..w) |x| {
            const filled = scanline.filled((f64i(x) + 0.5) / scale + tfm[0], fill_rule);
            const idx = row * scaled_w + x * channels;
            const distance = math.median(out_pixels[idx], out_pixels[idx + 1], out_pixels[idx + 2]);
            if (distance == 0.5) {
                ambiguous = true;
            } else if ((distance > 0.5) != filled) {
                for (0..3) |i| out_pixels[idx + i] = 1.0 - out_pixels[idx + i];
                match_map[match_idx] = -1;
            } else match_map[match_idx] = 1;
            if (channels >= 4 and (out_pixels[idx + 3] > 0.5) != filled)
                out_pixels[idx + 3] = 1.0 - out_pixels[idx + 3];
            match_idx += 1;
        }
    }

    if (!ambiguous) return;

    match_idx = 0;
    for (0..h) |y| {
        const row = h - y - 1;
        for (0..w) |x| {
            const match = match_map[match_idx];
            if (match == 0) {
                var neighbor_match: i32 = 0;
                if (x > 0) neighbor_match += match - 1;
                if (x < w - 1) neighbor_match += match + 1;
                if (y > 0) neighbor_match += match - w;
                if (y < h - 1) neighbor_match += match + w;
                if (neighbor_match < 0) {
                    for (out_pixels[row * scaled_w + x * channels ..][0..3]) |*px|
                        px.* = 1.0 - px.*;
                }
            }
            match_idx += 1;
        }
    }
}

fn generate(
    comptime sdf_type: SdfType,
    out_pixels: []f64,
    w: u16,
    h: u16,
    scale: f64,
    shape: Shape,
    px_range: f64,
    tfm: Vec2,
) void {
    for (0..h) |y| {
        const row = h - y - 1;
        for (0..w) |x| {
            const p = Vec2{
                (f64i(x) + 0.5),
                (f64i(y) + 0.5),
            } / math.v2(scale) + tfm;

            switch (sdf_type) {
                .sdf, .psdf => {
                    const dist = findDistanceAt(sdf_type, shape, p, px_range);
                    out_pixels[row * w + x] = dist;
                },
                .msdf, .msdf10, .mtsdf => {
                    const channels = sdf_type.numChannels();
                    for (
                        out_pixels[row * w * channels + x * channels ..][0..channels],
                        findDistanceAt(sdf_type, shape, p, px_range),
                    ) |*v, dist| v.* = dist;
                },
            }
        }
    }
}
