const std = @import("std");

const ft = @import("mach-freetype");
const pack = @import("turbopack");

const coloring = @import("coloring.zig");
const Contour = @import("Contour.zig");
const edge_color = @import("edge_color.zig");
const EdgeColor = edge_color.EdgeColor;
const EdgeSegment = @import("EdgeSegment.zig");
const ErrorCorrection = @import("ErrorCorrection.zig");
const math = @import("math.zig");
const Scanline = @import("Scanline.zig");
const Shape = @import("Shape.zig");
const SignedDistance = @import("SignedDistance.zig");

const Vec2 = @Vector(2, f64);
const f64_nan = std.math.nan(f64);

const Generator = @This();

pub const FontMetrics = struct {
    line_height: f64,
    ascender: f64,
    descender: f64,
    underline_y: f64,
    underline_thickness: f64,
};

pub const GlyphData = struct {
    advance: f64,
    bearing_x: f64,
    bearing_y: f64,
    width: u16,
    height: u16,
};

pub const KerningPair = struct {
    codepoint_1: u21,
    codepoint_2: u21,
    x: f64,
    y: f64,
};

pub const AtlasGlyphData = struct {
    glyph_data: GlyphData,
    codepoint: u21,
    /// This is the glyph's unscaled, unnormalized
    /// bounding box on the atlas, with padding included.
    tex_bounds: pack.Rect,
};

pub const Msdf10Pixel = packed struct(u32) {
    r: u10 = 0,
    g: u10 = 0,
    b: u10 = 0,
    a: u2 = std.math.maxInt(u2),
};

pub const SingleGlyphData = struct {
    glyph_data: GlyphData,
    pixels: []const u8,

    pub fn deinit(self: SingleGlyphData, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const AtlasData = struct {
    glyphs: []const AtlasGlyphData,
    kernings: []const KerningPair,
    /// In case of `msdf10` you should reinterpret this as a `Msdf10Pixel` slice,
    /// like with 10-bit ABGR GPU formats (assuming a little endian host).
    pixels: []const u8,

    pub fn deinit(self: AtlasData, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        allocator.free(self.kernings);
        allocator.free(self.pixels);
    }
};

pub const SdfType = enum {
    sdf,
    psdf,
    msdf,
    mtsdf,
    /// Experimental: A packed BGR MSDF where each channel is 10-bit,
    /// with a 2-bit alpha channel that is ignored (set to u2 max).
    ///
    /// Can prove useful in place of MSDFs as native `R8G8B8_X` (and equivalent)
    /// format support is scarce. Additionally, 3-channel images are often padded
    /// to have an alignment of 4 bytes per pixel on a lot of hardware,
    /// which results in the final byte getting wasted on such formats.
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
    coloring_rng_seed: u64 = 0,
    corner_angle_threshold: f64 = 3.0,
    orientation: OrientationType = .guess,
    validate_shape: bool = false,
    normalize_shape: bool = false,
    orient_contours: bool = false,
    /// Requires `orient_contours` to be disabled
    scanline_fill_rule: ?Scanline.FillRule = null,
    /// Only MSDFs (both their normal and their 10-bit versions) and MTSDFs can be error corrected
    error_correction_opts: ?ErrorCorrection.Options = .{},
    var_font_args: []const VarFontArgument = &.{},
    /// Whether to use async tasks over concurrent ones during atlas generation.
    /// Currently has no effect outside of atlas generation.
    disable_concurrency: bool = false,
};

const FreetypeContext = struct {
    allocator: std.mem.Allocator,
    scale: f64,
    shape: *Shape,
    pos: Vec2 = @splat(0.0),
    contour: ?*Contour = null,
};

const PsdfData = struct {
    min_dist: SignedDistance = .{},
    near_edge: ?*const EdgeSegment = null,
    near_param: f64 = 0,
};

library: ft.Library,
font_memory: []const u8,

/// `font_memory` is the raw font file data.
/// It should be valid and available during the entire Generator lifecycle,
/// as it's used to create new faces, since a shared one is not thread-safe.
pub fn create(font_memory: []const u8) !Generator {
    return .{
        .library = try .init(),
        .font_memory = font_memory,
    };
}

pub fn destroy(self: *Generator) void {
    self.library.deinit();
}

pub fn fontMetrics(self: *Generator) !FontMetrics {
    const face = try self.library.createFaceMemory(self.font_memory, 0);
    defer face.deinit();

    const scale = 1.0 / f64i(face.unitsPerEM());
    return .{
        .line_height = scale * f64i(face.height()),
        .ascender = scale * f64i(face.ascender()),
        .descender = scale * f64i(face.descender()),
        .underline_y = scale * f64i(face.underlinePosition()),
        .underline_thickness = scale * f64i(face.underlineThickness()),
    };
}

fn handleVarFont(
    self: *Generator,
    face: ft.Face,
    allocator: std.mem.Allocator,
    var_args: []const VarFontArgument,
    face_flags: ft.FaceFlags,
) !void {
    if (var_args.len == 0) return;

    if (face_flags.multiple_masters) {
        std.log.warn("Var font args supplied, but the face only has a single master", .{});
        return;
    }

    const vf = try face.createVarFontInfo();
    if (vf) |var_font| if (var_font.num_axis > 0) {
        var coords = try allocator.alloc(ft.c.FT_Fixed, var_font.num_axis);
        defer allocator.free(coords);
        try face.getVarDesignCoords(coords);
        for (var_args) |args|
            for (var_font.axis[0..var_font.num_axis], 0..) |axis, i|
                if (std.mem.eql(u8, std.mem.span(axis.name), args.name)) {
                    coords[i] = @intFromFloat(std.math.maxInt(u16) * args.value);
                };
        try face.setVarDesignCoords(coords);
    };
    try self.library.destroyVarFontInfo(vf);
}

/// The result is under the caller's ownership (call `deinit()` or deallocate fields manually)
pub fn generateSingle(
    self: *Generator,
    allocator: std.mem.Allocator,
    codepoint: u21,
    gen_opts: *const GenerationOptions,
) !SingleGlyphData {
    const face = try self.library.createFaceMemory(self.font_memory, 0);
    defer face.deinit();

    try self.handleVarFont(face, allocator, gen_opts.var_font_args, face.faceFlags());

    const scale = 1.0 / f64i(face.unitsPerEM());
    const glyph_index = face.getCharIndex(codepoint) orelse return error.InvalidCodepoint;
    try face.loadGlyph(glyph_index, .{ .no_scale = true, .no_bitmap = true });

    var shape: Shape = .{};
    defer shape.deinit(allocator);

    var context: FreetypeContext = .{
        .allocator = allocator,
        .scale = scale,
        .shape = &shape,
    };

    const outline = face.glyph().outline().?;
    try ft.intToError(ft.c.FT_Outline_Decompose(
        outline.handle,
        &.{
            .move_to = ftMoveTo,
            .line_to = ftLineTo,
            .conic_to = ftConicTo,
            .cubic_to = ftCubicTo,
            .shift = 0,
            .delta = 0,
        },
        &context,
    ));

    const metrics = face.glyph().metrics();
    if (shape.contours.items.len == 0)
        return .{
            .glyph_data = .{
                .advance = scale * f64i(face.glyph().advance().x),
                .bearing_x = scale * f64i(metrics.horiBearingX),
                .bearing_y = scale * f64i(metrics.horiBearingY),
                .width = 0,
                .height = 0,
            },
            .pixels = &.{},
        };

    var contour_it = std.mem.reverseIterator(shape.contours.items);
    var i: isize = @intCast(shape.contours.items.len - 1);
    while (contour_it.next()) |contour| : (i -= 1)
        if (contour.edges.items.len == 0) {
            _ = shape.contours.swapRemove(@intCast(i));
        };

    if (gen_opts.validate_shape and !shape.validate()) return error.InvalidShape;
    if (gen_opts.orient_contours) try shape.orientContours(allocator);
    if (gen_opts.normalize_shape) try shape.normalize(allocator);

    const px_size = f64i(gen_opts.px_size);
    const px_range = f64i(gen_opts.px_range) / px_size;

    var bounds = shape.getBounds(0, 0, 0);
    if (bounds.left >= bounds.right or bounds.bottom >= bounds.top)
        bounds = .{ .left = 0, .bottom = 0, .right = 1, .top = 1 };

    const bound_w = bounds.right - bounds.left;
    const bound_h = bounds.top - bounds.bottom;
    const w: u16 = @trunc((bound_w + px_range) * px_size);
    const h: u16 = @trunc((bound_h + px_range) * px_size);

    const oob_point: Vec2 = if (gen_opts.orientation == .guess)
        .{ bounds.left - bound_w - 1, bounds.bottom - bound_h - 1 }
    else
        undefined;

    return .{
        .glyph_data = .{
            .advance = scale * f64i(face.glyph().advance().x),
            .bearing_x = scale * f64i(metrics.horiBearingX),
            .bearing_y = scale * f64i(metrics.horiBearingY),
            .width = w,
            .height = h,
        },
        .pixels = try getSdfPixels(
            allocator,
            gen_opts,
            w,
            h,
            &shape,
            .{
                bounds.left - px_range / 2.0,
                bounds.bottom - px_range / 2.0,
            },
            oob_point,
        ),
    };
}

/// The result is under the caller's ownership (call `deinit()` or deallocate fields manually)
pub fn generateAtlas(
    self: *Generator,
    allocator: std.mem.Allocator,
    io: std.Io,
    codepoints: []const u21,
    atlas_w: u16,
    atlas_h: u16,
    glyph_padding: u8,
    use_kerning: bool,
    gen_opts: *const GenerationOptions,
) !AtlasData {
    const glyphs = try allocator.alloc(AtlasGlyphData, codepoints.len);
    errdefer allocator.free(glyphs);

    var kernings: std.ArrayList(KerningPair) = .empty;
    errdefer kernings.deinit(allocator);
    kerning: {
        if (!use_kerning)
            break :kerning;

        const face = try self.library.createFaceMemory(self.font_memory, 0);
        defer face.deinit();

        if (!face.faceFlags().kerning) {
            std.log.warn(
                \\Kerning requested, but none were found in the font file.
                \\Note: FreeType doesn't have full support for GPOS kerning, you might want to populate the kern table off of the GPOS one with a font editor if you were expecting kerning to be present.
            , .{});
            break :kerning;
        }

        const scale = 1.0 / f64i(face.unitsPerEM());
        for (codepoints) |codepoint_a| for (codepoints) |codepoint_b| {
            const idx_a = face.getCharIndex(codepoint_a) orelse return error.InvalidCodepoint;
            const idx_b = face.getCharIndex(codepoint_b) orelse return error.InvalidCodepoint;
            if (idx_a != idx_b) {
                const kern = try face.getKerning(idx_a, idx_b, .unscaled);
                if (kern.x != 0 or kern.y != 0)
                    try kernings.append(allocator, .{
                        .codepoint_1 = codepoint_a,
                        .codepoint_2 = codepoint_b,
                        .x = scale * f64i(kern.x),
                        .y = scale * f64i(kern.y),
                    });
            }
        };
    }

    const id_rects = try allocator.alloc(pack.IdRect, codepoints.len);
    defer allocator.free(id_rects);

    const rect_pixels = try allocator.alloc([]const u8, codepoints.len);
    defer {
        for (rect_pixels) |px| allocator.free(px);
        allocator.free(rect_pixels);
    }
    @memset(rect_pixels, &.{});

    var process_group: std.Io.Group = .init;
    for (
        codepoints,
        glyphs,
        id_rects,
        rect_pixels,
        0..,
    ) |codepoint, *glyph, *id_rect, *rect_px, i| {
        id_rect.id = @intCast(i);
        const args = .{
            self,
            allocator,
            gen_opts,
            codepoint,
            glyph,
            id_rect,
            rect_px,
            glyph_padding,
        };

        if (gen_opts.disable_concurrency)
            process_group.async(io, processAtlasCodepoint, args)
        else
            try process_group.concurrent(io, processAtlasCodepoint, args);
    }
    try process_group.await(io);

    var pack_ctx: pack.Context = try .create(allocator, atlas_w, atlas_h, .{});
    defer pack_ctx.deinit();
    try pack.pack(
        pack.IdRect,
        &pack_ctx,
        id_rects,
        .{ .sortLessThanFn = struct {
            fn lessThan(_: void, a: pack.IdRect, b: pack.IdRect) bool {
                return @max(a.rect.w, a.rect.h) > @max(b.rect.w, b.rect.h);
            }
        }.lessThan },
    );

    const mod_channels = if (gen_opts.sdf_type == .msdf10)
        4
    else
        gen_opts.sdf_type.numChannels();
    const pixels = try allocator.alloc(u8, @as(usize, atlas_w) * @as(usize, atlas_h) * @as(usize, mod_channels));
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    for (id_rects) |id_rect| {
        const index: usize = @intCast(id_rect.id);
        const rect = id_rect.rect;
        glyphs[index].tex_bounds = rect;
        if (rect.w <= 0 or rect.h <= 0)
            continue;

        const glyph_w: usize = @intCast(rect.w - glyph_padding * 2);
        const glyph_h: usize = @intCast(rect.h - glyph_padding * 2);
        const cur_atlas_x: usize = @intCast(rect.x + glyph_padding);
        const cur_atlas_y: usize = @intCast(rect.y + glyph_padding);

        for (0..glyph_h) |j| {
            const atlas_idx = ((cur_atlas_y + j) * atlas_w + cur_atlas_x) * mod_channels;
            const src_idx = (j * glyph_w) * mod_channels;
            @memcpy(
                pixels[atlas_idx .. atlas_idx + glyph_w * mod_channels],
                rect_pixels[index][src_idx .. src_idx + glyph_w * mod_channels],
            );
        }
    }

    return .{
        .glyphs = glyphs,
        .pixels = pixels,
        .kernings = if (use_kerning and kernings.items.len > 0)
            try kernings.toOwnedSlice(allocator)
        else
            &.{},
    };
}

fn processAtlasCodepoint(
    self: *Generator,
    allocator: std.mem.Allocator,
    gen_opts: *const GenerationOptions,
    codepoint: u21,
    glyph: *AtlasGlyphData,
    id_rect: *pack.IdRect,
    rect_px: *[]const u8,
    padding: u8,
) std.Io.Cancelable!void {
    self.processAtlasCodepointInner(
        allocator,
        gen_opts,
        glyph,
        id_rect,
        rect_px,
        padding,
        codepoint,
    ) catch {
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        return std.Io.Cancelable.Canceled;
    };
}

fn processAtlasCodepointInner(
    self: *Generator,
    allocator: std.mem.Allocator,
    gen_opts: *const GenerationOptions,
    glyph: *AtlasGlyphData,
    id_rect: *pack.IdRect,
    rect_px: *[]const u8,
    padding: u8,
    codepoint: u21,
) !void {
    const single_glyph = try self.generateSingle(allocator, codepoint, gen_opts);
    const glyph_w = single_glyph.glyph_data.width;
    const glyph_h = single_glyph.glyph_data.height;
    if (glyph_w == 0 or glyph_h == 0) {
        glyph.* = .{
            .glyph_data = .{
                .advance = single_glyph.glyph_data.advance,
                .bearing_x = single_glyph.glyph_data.bearing_x,
                .bearing_y = single_glyph.glyph_data.bearing_y,
                .width = 0.0,
                .height = 0.0,
            },
            .codepoint = codepoint,
            .tex_bounds = .{ .w = 0, .h = 0 },
        };
        id_rect.rect = .{ .w = 0, .h = 0 };
        return;
    }

    rect_px.* = single_glyph.pixels;
    id_rect.rect = .{
        .w = glyph_w + padding * 2,
        .h = glyph_h + padding * 2,
    };
    glyph.* = .{
        .glyph_data = .{
            .advance = single_glyph.glyph_data.advance,
            .bearing_x = single_glyph.glyph_data.bearing_x,
            .bearing_y = single_glyph.glyph_data.bearing_y,
            .width = @intCast(id_rect.rect.w),
            .height = @intCast(id_rect.rect.h),
        },
        .codepoint = codepoint,
        .tex_bounds = .{
            .x = std.math.minInt(i32),
            .y = std.math.minInt(i32),
            .w = std.math.minInt(i32),
            .h = std.math.minInt(i32),
        },
    };
}

fn getSdfPixels(
    allocator: std.mem.Allocator,
    opts: *const GenerationOptions,
    w: u16,
    h: u16,
    shape: *Shape,
    tfm: Vec2,
    oob_point: Vec2,
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
    const dist_pixels = try allocator.alloc(
        f64,
        @as(usize, w) * @as(usize, h) * @as(usize, if (opts.sdf_type == .msdf10) 4 else channels),
    );
    defer allocator.free(dist_pixels);

    const invert_pixels = opts.orientation == .reverse or
        (opts.orientation == .guess and findDistanceAt(.sdf, shape.*, oob_point, px_range) > 0);
    switch (opts.sdf_type) {
        inline else => |ty| {
            if (ty == .msdf or ty == .msdf10 or ty == .mtsdf)
                try coloring.colorShape(allocator, opts.coloring_rng_seed, shape, opts.corner_angle_threshold);
            generate(ty, dist_pixels, w, h, px_size, shape.*, px_range, tfm, invert_pixels);
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
        const idx = y * w * mod_channels + x * mod_channels;
        if (opts.sdf_type == .msdf10)
            pixels[y * w * 4 + x * 4 ..][0..4].* = std.mem.toBytes(Msdf10Pixel{
                .r = @trunc(std.math.maxInt(u10) * std.math.clamp(dist_pixels[idx], 0.0, 1.0)),
                .g = @trunc(std.math.maxInt(u10) * std.math.clamp(dist_pixels[idx + 1], 0.0, 1.0)),
                .b = @trunc(std.math.maxInt(u10) * std.math.clamp(dist_pixels[idx + 2], 0.0, 1.0)),
                .a = std.math.maxInt(u2),
            })
        else for (0..mod_channels) |i|
            pixels[idx + i] = @trunc(std.math.maxInt(u8) * std.math.clamp(dist_pixels[idx + i], 0.0, 1.0));
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
    var sdf_target: SignedDistance = .{};
    var psdf_target: [if (sdf_type == .psdf) 1 else 3]PsdfData = @splat(.{});
    for (shape.contours.items) |contour| for (contour.edges.items) |*edge| {
        const dist, const param = edge.signedDistance(p);

        switch (sdf_type) {
            .sdf, .mtsdf => {
                if (dist.lessThan(sdf_target)) sdf_target = dist;
            },
            .psdf => {
                if (dist.lessThan(psdf_target[0].min_dist)) psdf_target[0] = .{
                    .min_dist = dist,
                    .near_edge = edge,
                    .near_param = param,
                };
            },
            else => {},
        }

        if (sdf_type != .sdf and sdf_type != .psdf)
            for ([_]struct { channel: EdgeColor, target: *PsdfData }{
                .{ .channel = .red, .target = &psdf_target[0] },
                .{ .channel = .green, .target = &psdf_target[1] },
                .{ .channel = .blue, .target = &psdf_target[2] },
            }) |params|
                if (edge.color.hasChannel(params.channel) and dist.lessThan(params.target.min_dist)) {
                    params.target.* = .{
                        .min_dist = dist,
                        .near_edge = edge,
                        .near_param = param,
                    };
                };
    };

    if (sdf_type != .sdf) for (&psdf_target) |*psdf| {
        if (psdf.near_edge) |edge|
            edge.distanceToPerpendicularDistance(&psdf.min_dist, p, psdf.near_param);
    };

    return switch (sdf_type) {
        .sdf => pxRangeNorm(sdf_target.distance, px_range),
        .psdf => pxRangeNorm(psdf_target[0].min_dist.distance, px_range),
        .msdf, .msdf10 => .{
            pxRangeNorm(psdf_target[0].min_dist.distance, px_range),
            pxRangeNorm(psdf_target[1].min_dist.distance, px_range),
            pxRangeNorm(psdf_target[2].min_dist.distance, px_range),
        },
        .mtsdf => .{
            pxRangeNorm(psdf_target[0].min_dist.distance, px_range),
            pxRangeNorm(psdf_target[1].min_dist.distance, px_range),
            pxRangeNorm(psdf_target[2].min_dist.distance, px_range),
            pxRangeNorm(sdf_target.distance, px_range),
        },
    };
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
    invert_pixels: bool,
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
                    out_pixels[row * w + x] = if (invert_pixels) 1.0 - dist else dist;
                },
                .msdf, .msdf10, .mtsdf => {
                    const channels = sdf_type.numChannels();
                    for (
                        out_pixels[row * w * channels + x * channels ..][0..channels],
                        findDistanceAt(sdf_type, shape, p, px_range),
                    ) |*v, dist|
                        v.* = if (invert_pixels) 1.0 - dist else dist;
                },
            }
        }
    }
}

fn scaledFtVec(vec: [*c]const ft.Vector, scale: f64) Vec2 {
    return .{
        f64i(vec.*.x) * scale,
        f64i(vec.*.y) * scale,
    };
}

fn ftMoveTo(to: [*c]const ft.Vector, ud: ?*anyopaque) callconv(.c) i32 {
    var context: *FreetypeContext = @ptrCast(@alignCast(ud));
    if (context.contour == null or context.contour.?.edges.items.len != 0) {
        context.contour = context.shape.contours.addOne(context.allocator) catch return ft.c.FT_Err_Out_Of_Memory;
        context.contour.?.* = .{};
    }
    context.pos = scaledFtVec(to, context.scale);
    return 0;
}

fn ftLineTo(to: [*c]const ft.Vector, ud: ?*anyopaque) callconv(.c) i32 {
    var context: *FreetypeContext = @ptrCast(@alignCast(ud));
    const endpoint: Vec2 = scaledFtVec(to, context.scale);
    if (!std.meta.eql(endpoint, context.pos)) {
        context.contour.?.edges.append(
            context.allocator,
            .create(context.pos, endpoint, null, null, .white),
        ) catch return ft.c.FT_Err_Out_Of_Memory;
        context.pos = endpoint;
    }
    return 0;
}

fn ftConicTo(control: [*c]const ft.Vector, to: [*c]const ft.Vector, ud: ?*anyopaque) callconv(.c) i32 {
    var context: *FreetypeContext = @ptrCast(@alignCast(ud));
    const endpoint: Vec2 = scaledFtVec(to, context.scale);
    if (!std.meta.eql(endpoint, context.pos)) {
        context.contour.?.edges.append(context.allocator, .create(
            context.pos,
            scaledFtVec(control, context.scale),
            endpoint,
            null,
            .white,
        )) catch return ft.c.FT_Err_Out_Of_Memory;
        context.pos = endpoint;
    }
    return 0;
}

fn ftCubicTo(
    control_1: [*c]const ft.Vector,
    control_2: [*c]const ft.Vector,
    to: [*c]const ft.Vector,
    ud: ?*anyopaque,
) callconv(.c) i32 {
    var context: *FreetypeContext = @ptrCast(@alignCast(ud));
    const endpoint: Vec2 = scaledFtVec(to, context.scale);
    const scaled_c1: Vec2 = scaledFtVec(control_1, context.scale);
    const scaled_c2: Vec2 = scaledFtVec(control_2, context.scale);
    if (!std.meta.eql(endpoint, context.pos) or math.cross(scaled_c1 - endpoint, scaled_c2 - endpoint) != 0.0) {
        context.contour.?.edges.append(
            context.allocator,
            .create(context.pos, scaled_c1, scaled_c2, endpoint, .white),
        ) catch return ft.c.FT_Err_Out_Of_Memory;
        context.pos = endpoint;
    }
    return 0;
}

pub fn f64i(int: anytype) f64 {
    return @floatFromInt(int);
}
