//! FreeType-free signed-distance-field pipeline.
//!
//! This is the geometry-driven half of msdf-zig, split out of `Generator.zig` so it can be reached
//! without pulling in FreeType: it turns a `Shape` (however it was built) into SDF/MSDF/MTSDF
//! pixels. `Generator.zig` layers the FreeType font frontend on top and calls straight into here;
//! `core.zig` re-exports this plus the `Shape`/`Contour`/`EdgeSegment` types for consumers who
//! build shapes by hand and want no FreeType dependency.

const std = @import("std");

const coloring = @import("coloring.zig");
const edge_selectors = @import("edge_selectors.zig");
const ErrorCorrection = @import("ErrorCorrection.zig");
const math = @import("math.zig");
const pixel_conversion = @import("pixel_conversion.zig");
const Scanline = @import("Scanline.zig");
const Shape = @import("Shape.zig");
const SignedDistance = @import("SignedDistance.zig");

const Vec2 = @Vector(2, f64);

pub const f64i = math.f64i;

pub const Msdf10Pixel = packed struct(u32) {
    r: u10 = 0,
    g: u10 = 0,
    b: u10 = 0,
    a: u2 = std.math.maxInt(u2),
};

pub const Pixels = union(enum) {
    normal: []const u8,
    msdf10: []const Msdf10Pixel,
};

pub const SdfType = enum {
    sdf,
    psdf,
    msdf,
    mtsdf,
    /// Experimental: A packed BGR MSDF where each channel is 10-bit,
    /// with a 2-bit alpha channel that is ignored (set to u2 max).
    ///
    /// Can prove useful in place of MSDFs as native `R8G8B8_X` (and equivalents)
    /// support is scarce and 3-channel images are often padded to have an
    /// alignment of 4 bytes per pixel on a lot of hardware, resulting in
    /// the final byte getting wasted.
    ///
    /// For use with the `A2B10G10R10_UNORM_PACK32` format (and equivalents).
    msdf10,

    pub fn numChannels(self: SdfType) u8 {
        return switch (self) {
            .sdf, .psdf => 1,
            .msdf, .msdf10 => 3,
            .mtsdf => 4,
        };
    }
};

pub const OrientationType = enum {
    guess,
    keep,
    reverse,
};

pub const VarFontArgument = struct {
    name: []const u8,
    value: f64,
};

pub const GenerationOptions = struct {
    sdf_type: SdfType,
    px_size: u16,
    px_range: u16,
    /// Selects one of the deterministic edge colorings. Not an RNG seed: the
    /// same value always yields the same coloring, matching msdfgen.
    coloring_seed: u64 = 0,
    corner_angle_threshold: f64 = 3.0,
    orientation: OrientationType = .guess,
    geometry_preprocess: bool = false,
    /// Requires geometry preprocessing to be disabled
    scanline_fill_rule: ?Scanline.FillRule = null,
    /// Only MSDFs and MTSDFs can be error corrected
    error_correction_opts: ?ErrorCorrection.Options = .{},
    var_font_args: []const VarFontArgument = &.{},
};

/// An SDF/MSDF/MTSDF bitmap rasterized straight from a `Shape`, no font involved. Caller owns it.
pub const ShapeData = struct {
    pixels: Pixels,
    width: u16,
    height: u16,

    pub fn deinit(self: ShapeData, allocator: std.mem.Allocator) void {
        switch (self.pixels) {
            inline else => |inner| allocator.free(inner),
        }
    }
};

/// Rasterize a hand-built `Shape` into an SDF/MSDF/MTSDF bitmap.
///
/// Mirrors `Generator.generateSingle` from the point its glyph outline has been decomposed: it
/// validates, optionally reorients (`geometry_preprocess`), and normalizes the shape, frames it
/// with `px_range` padding, and rasterizes. `shape` is mutated (normalize / edge coloring /
/// optional reorientation) and remains the caller's to free; the returned pixels are owned by the
/// caller (`ShapeData.deinit`). `var_font_args` on the options is ignored here (font-only).
pub fn generateFromShape(
    allocator: std.mem.Allocator,
    shape: *Shape,
    gen_opts: GenerationOptions,
) !ShapeData {
    if (!shape.validate()) return error.InvalidShape;
    if (gen_opts.geometry_preprocess) try shape.orientContours(allocator);
    try shape.normalize(allocator);

    const f_px_size = f64i(gen_opts.px_size);
    const px_range = f64i(gen_opts.px_range) / f_px_size;

    var bounds = shape.getBounds(0, 0, 0);
    if (bounds.left >= bounds.right or bounds.bottom >= bounds.top)
        bounds = .{ .left = 0, .bottom = 0, .right = 1, .top = 1 };

    const translate_x = -bounds.left + px_range / 2.0;
    const translate_y = -bounds.bottom + px_range / 2.0;
    const w: u16 = @intFromFloat((bounds.right - bounds.left + px_range) * f_px_size);
    const h: u16 = @intFromFloat((bounds.top - bounds.bottom + px_range) * f_px_size);

    const oob_point: Vec2 = if (gen_opts.orientation == .guess)
        .{ bounds.left - (bounds.right - bounds.left) - 1, bounds.bottom - (bounds.top - bounds.bottom) - 1 }
    else
        undefined;

    return .{
        .width = w,
        .height = h,
        .pixels = switch (gen_opts.sdf_type) {
            .msdf10 => .{ .msdf10 = try getMsdf10Pixels(allocator, gen_opts, w, h, shape, translate_x, translate_y, oob_point) },
            else => .{ .normal = try getSdfPixels(allocator, gen_opts, w, h, shape, translate_x, translate_y, oob_point) },
        },
    };
}

fn getSdfPixelsInner(
    allocator: std.mem.Allocator,
    opts: GenerationOptions,
    w: u16,
    h: u16,
    shape: *Shape,
    translate_x: f64,
    translate_y: f64,
    oob_point: Vec2,
) ![]const f64 {
    const f_px_size = f64i(opts.px_size);
    const px_range = f64i(opts.px_range) / f_px_size;

    var error_correction: ?ErrorCorrection =
        if (opts.error_correction_opts) |ec_opts| b: {
            break :b if (opts.sdf_type == .msdf or opts.sdf_type == .mtsdf)
                try .create(allocator, shape, w, h, ec_opts, opts.scanline_fill_rule != null)
            else
                null;
        } else null;
    defer if (error_correction) |*ec| ec.destroy(allocator);

    const channels = opts.sdf_type.numChannels();

    const pixels = try allocator.alloc(f64, @as(u32, w) * @as(u32, h) * @as(u32, channels));
    const invert_pixels = opts.orientation == .reverse or
        (opts.orientation == .guess and findDistanceAt(shape.*, oob_point, px_range) > 0);
    switch (opts.sdf_type) {
        .sdf => generateSdf(pixels, w, h, f_px_size, shape.*, px_range, translate_x, translate_y, invert_pixels),
        .psdf => generatePsdf(pixels, w, h, f_px_size, shape.*, px_range, translate_x, translate_y, invert_pixels),
        .msdf, .msdf10 => {
            try coloring.colorShape(allocator, shape, opts.corner_angle_threshold, opts.coloring_seed);
            generateMsdf(pixels, w, h, f_px_size, shape.*, px_range, translate_x, translate_y, invert_pixels);
        },
        .mtsdf => {
            try coloring.colorShape(allocator, shape, opts.corner_angle_threshold, opts.coloring_seed);
            generateMtsdf(pixels, w, h, f_px_size, shape.*, px_range, translate_x, translate_y, invert_pixels);
        },
    }

    if (!opts.geometry_preprocess) if (opts.scanline_fill_rule) |fill_rule|
        switch (opts.sdf_type) {
            .sdf, .psdf => try sdfSignCorrection(
                allocator,
                pixels,
                w,
                h,
                f_px_size,
                shape.*,
                translate_x,
                translate_y,
                fill_rule,
            ),
            .msdf, .msdf10, .mtsdf => try msdfSignCorrection(
                allocator,
                pixels,
                w,
                h,
                f_px_size,
                shape.*,
                translate_x,
                translate_y,
                fill_rule,
                channels,
            ),
        };

    if (error_correction) |*ec|
        ec.correct(shape, f_px_size, px_range, translate_x, translate_y, pixels, w, h, channels, invert_pixels);
    return pixels;
}

pub fn getSdfPixels(
    allocator: std.mem.Allocator,
    opts: GenerationOptions,
    w: u16,
    h: u16,
    shape: *Shape,
    translate_x: f64,
    translate_y: f64,
    oob_point: Vec2,
) ![]const u8 {
    const float_pixels = try getSdfPixelsInner(
        allocator,
        opts,
        w,
        h,
        shape,
        translate_x,
        translate_y,
        oob_point,
    );
    defer allocator.free(float_pixels);

    const channels = opts.sdf_type.numChannels();
    const pixels = try allocator.alloc(u8, @as(u32, w) * @as(u32, h) * @as(u32, channels));

    for (0..h) |y| for (0..w) |x| {
        const idx = y * w * channels + x * channels;
        for (0..channels) |i|
            pixels[idx + i] = pixel_conversion.floatToUnorm(u8, float_pixels[idx + i]);
    };
    return pixels;
}

pub fn getMsdf10Pixels(
    allocator: std.mem.Allocator,
    opts: GenerationOptions,
    w: u16,
    h: u16,
    shape: *Shape,
    translate_x: f64,
    translate_y: f64,
    oob_point: Vec2,
) ![]const Msdf10Pixel {
    const float_pixels = try getSdfPixelsInner(
        allocator,
        opts,
        w,
        h,
        shape,
        translate_x,
        translate_y,
        oob_point,
    );
    defer allocator.free(float_pixels);

    const channels = opts.sdf_type.numChannels();
    const pixels = try allocator.alloc(Msdf10Pixel, @as(u32, w) * @as(u32, h));

    for (0..h) |y| for (0..w) |x| {
        const dist_rgb = float_pixels[y * w * channels + x * channels ..];
        pixels[y * w + x] = .{
            .a = std.math.maxInt(u2),
            .b = pixel_conversion.floatToUnorm(u10, dist_rgb[2]),
            .g = pixel_conversion.floatToUnorm(u10, dist_rgb[1]),
            .r = pixel_conversion.floatToUnorm(u10, dist_rgb[0]),
        };
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
    tx: f64,
    ty: f64,
    fill_rule: Scanline.FillRule,
) !void {
    var scanline: Scanline = .{};
    defer scanline.intersections.deinit(allocator);
    for (0..h) |y| {
        const row = h - y - 1;
        try shape.scanline(&scanline, (f64i(y) + 0.5) / scale - ty, allocator);
        for (0..w) |x| {
            const idx = row * w + x;
            const distance = out_pixels[idx];
            if ((distance > 0.5) != scanline.filled((f64i(x) + 0.5) / scale - tx, fill_rule))
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
    tx: f64,
    ty: f64,
    fill_rule: Scanline.FillRule,
    channels: u8,
) !void {
    var scanline: Scanline = .{};
    defer scanline.intersections.deinit(allocator);
    var ambiguous = false;
    const match_map: []i32 = try allocator.alloc(i32, w * h);
    defer allocator.free(match_map);
    // The ambiguous branch below leaves an entry unwritten, and the second pass
    // keys on it being 0. C++ gets this from std::vector's value-initialization;
    // alloc here hands back undefined memory, so it has to be done explicitly.
    @memset(match_map, 0);
    var match_idx: usize = 0;
    const scaled_w = w * channels;
    for (0..h) |y| {
        const row = h - y - 1;
        try shape.scanline(&scanline, (f64i(y) + 0.5) / scale - ty, allocator);
        for (0..w) |x| {
            const filled = scanline.filled((f64i(x) + 0.5) / scale - tx, fill_rule);
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
            // Only texels left ambiguous above (median exactly on the boundary)
            // are resolved here, by taking the sign their neighbours agreed on.
            if (match_map[match_idx] == 0) {
                var neighbor_match: i32 = 0;
                if (x > 0) neighbor_match += match_map[match_idx - 1];
                if (x < w - 1) neighbor_match += match_map[match_idx + 1];
                if (y > 0) neighbor_match += match_map[match_idx - w];
                if (y < h - 1) neighbor_match += match_map[match_idx + w];
                if (neighbor_match < 0) {
                    for (out_pixels[row * scaled_w + x * channels ..][0..3]) |*px|
                        px.* = 1.0 - px.*;
                }
            }
            match_idx += 1;
        }
    }
}

fn findDistanceAt(shape: Shape, p: Vec2, px_range: f64) f64 {
    var dummy: f64 = 0;
    var min_dist: SignedDistance = .{};
    for (shape.contours.items) |contour| for (contour.edges.items) |*edge| {
        const dist = edge.signedDistance(p, &dummy);
        if (dist.lessThan(min_dist)) min_dist = dist;
    };
    return (min_dist.distance + px_range / 2.0) / px_range;
}

/// Maps a signed distance to the normalized [0,1] the bitmap stores, applying
/// the whole-bitmap flip when the shape's winding reads inside-out.
fn mapDistance(distance: f64, px_range: f64, invert_pixels: bool) f64 {
    const d = (distance + px_range / 2.0) / px_range;
    return if (invert_pixels) 1.0 - d else d;
}

/// Sample point for bitmap column `x` / shape row `y`, i.e. the inverse of
/// msdfgen's Projection::project.
fn samplePoint(x: usize, y: usize, scale: f64, tx: f64, ty: f64) Vec2 {
    return .{
        (f64i(x) + 0.5) / scale - tx,
        (f64i(y) + 0.5) / scale - ty,
    };
}

fn generateSdf(out_pixels: []f64, w: u16, h: u16, scale: f64, shape: Shape, px_range: f64, tx: f64, ty: f64, invert_pixels: bool) void {
    for (0..h) |y| {
        const row = h - y - 1;
        for (0..w) |x| {
            var selector: edge_selectors.TrueDistanceSelector = .init(samplePoint(x, y, scale, tx, ty));
            edge_selectors.accumulate(&selector, shape);
            out_pixels[row * w + x] = mapDistance(selector.distance(), px_range, invert_pixels);
        }
    }
}

fn generatePsdf(out_pixels: []f64, w: u16, h: u16, scale: f64, shape: Shape, px_range: f64, tx: f64, ty: f64, invert_pixels: bool) void {
    for (0..h) |y| {
        const row = h - y - 1;
        for (0..w) |x| {
            var selector: edge_selectors.PerpendicularDistanceSelector = .init(samplePoint(x, y, scale, tx, ty));
            edge_selectors.accumulate(&selector, shape);
            out_pixels[row * w + x] = mapDistance(selector.distance(), px_range, invert_pixels);
        }
    }
}

fn generateMsdf(out_pixels: []f64, w: u16, h: u16, scale: f64, shape: Shape, px_range: f64, tx: f64, ty: f64, invert_pixels: bool) void {
    const channels = 3;
    for (0..h) |y| {
        const row = h - y - 1;
        for (0..w) |x| {
            var selector: edge_selectors.MultiDistanceSelector = .init(samplePoint(x, y, scale, tx, ty));
            edge_selectors.accumulate(&selector, shape);
            const md = selector.distance();

            const out = out_pixels[row * w * channels + x * channels ..][0..3];
            out[0] = mapDistance(md.r, px_range, invert_pixels);
            out[1] = mapDistance(md.g, px_range, invert_pixels);
            out[2] = mapDistance(md.b, px_range, invert_pixels);
        }
    }
}

fn generateMtsdf(out_pixels: []f64, w: u16, h: u16, scale: f64, shape: Shape, px_range: f64, tx: f64, ty: f64, invert_pixels: bool) void {
    const channels = 4;
    for (0..h) |y| {
        const row = h - y - 1;
        for (0..w) |x| {
            var selector: edge_selectors.MultiDistanceSelector = .init(samplePoint(x, y, scale, tx, ty));
            edge_selectors.accumulate(&selector, shape);
            const mtd = selector.multiAndTrueDistance();

            const out = out_pixels[row * w * channels + x * channels ..][0..4];
            out[0] = mapDistance(mtd.r, px_range, invert_pixels);
            out[1] = mapDistance(mtd.g, px_range, invert_pixels);
            out[2] = mapDistance(mtd.b, px_range, invert_pixels);
            out[3] = mapDistance(mtd.a, px_range, invert_pixels);
        }
    }
}
