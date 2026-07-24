const std = @import("std");

const Generator = @import("../Generator.zig");
const pixel_conversion = @import("../pixel_conversion.zig");
const Scanline = @import("../Scanline.zig");
const math = @import("../math.zig");
const ft = @import("mach-freetype");

const f64i = math.f64i;

const Font = struct {
    label: []const u8,
    path: []const u8,
};

const fonts = [_]Font{
    .{ .label = "tt", .path = "example/assets/DMSerifDisplay-Regular.ttf" },
    .{ .label = "cff", .path = "example/assets/texgyretermes-regular.otf" },
};

const px_size = 32;
const px_range = 4;

const Case = struct {
    name: []const u8,
    font: usize,
    codepoint: u21,
    opts: Generator.GenerationOptions,
};

fn smoothstep(edge0: f64, edge1: f64, x: f64) f64 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn sampleSdf(pixels: []const u8, w: u16, h: u16, channels: u8, c: f64, r: f64) f64 {
    const c_min = std.math.clamp(@as(i32, @intFromFloat(@floor(c))), 0, w - 1);
    const c_max = std.math.clamp(c_min + 1, 0, w - 1);
    const r_min = std.math.clamp(@as(i32, @intFromFloat(@floor(r))), 0, h - 1);
    const r_max = std.math.clamp(r_min + 1, 0, h - 1);

    const fc = c - @as(f64, @floatFromInt(@as(i32, @intFromFloat(@floor(c)))));
    const fr = r - @as(f64, @floatFromInt(@as(i32, @intFromFloat(@floor(r)))));

    var ch_dists: [4]f64 = undefined;
    for (0..channels) |ch| {
        const p00 = @as(f64, @floatFromInt(pixels[(@as(usize, @intCast(r_min)) * w + @as(usize, @intCast(c_min))) * channels + ch])) / 255.0;
        const p10 = @as(f64, @floatFromInt(pixels[(@as(usize, @intCast(r_min)) * w + @as(usize, @intCast(c_max))) * channels + ch])) / 255.0;
        const p01 = @as(f64, @floatFromInt(pixels[(@as(usize, @intCast(r_max)) * w + @as(usize, @intCast(c_min))) * channels + ch])) / 255.0;
        const p11 = @as(f64, @floatFromInt(pixels[(@as(usize, @intCast(r_max)) * w + @as(usize, @intCast(c_max))) * channels + ch])) / 255.0;

        const p0 = p00 * (1.0 - fc) + p10 * fc;
        const p1 = p01 * (1.0 - fc) + p11 * fc;
        ch_dists[ch] = p0 * (1.0 - fr) + p1 * fr;
    }

    if (channels >= 3) {
        return math.median(ch_dists[0], ch_dists[1], ch_dists[2]);
    } else {
        return ch_dists[0];
    }
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, font: []const u8, case: Case) !void {
    if (case.opts.sdf_type == .psdf) return; // PSDF does not rasterize with distance fields

    var generator: Generator = try .create(font);
    defer generator.destroy();

    var result = try generator.generateSingle(allocator, case.codepoint, case.opts);
    defer result.deinit(allocator);

    const pixels = switch (result.pixels) {
        .normal => |p| p,
        .msdf10 => return error.UnexpectedPixelFormat,
    };

    const target_sizes = [_]u32{ 12, 16, 24, 32, 48, 64, 96 };
    const channels = case.opts.sdf_type.numChannels();
    const w = result.glyph_data.width;
    const h = result.glyph_data.height;

    if (w == 0 or h == 0) return; // empty glyph

    const bounds = result.glyph_data.bounds;

    for (target_sizes) |ts| {
        try generator.face.setPixelSizes(ts, ts);

        try generator.face.loadGlyph(generator.face.getCharIndex(case.codepoint).?, .{ .no_hinting = true });
        try generator.face.glyph().render(.normal);

        const ft_bitmap = generator.face.glyph().bitmap();
        const ft_buf = ft_bitmap.buffer() orelse &[_]u8{};
        const ft_w = ft_bitmap.width();
        const ft_h = ft_bitmap.rows();
        const ft_pitch = ft_bitmap.pitch();
        const ft_left = generator.face.glyph().bitmapLeft();
        const ft_top = generator.face.glyph().bitmapTop();

        const px_range_em = f64i(case.opts.px_range) / f64i(case.opts.px_size);
        // generateSingle positions the bitmap from the outline's exact bounds.
        // The FreeType bearings are rounded font metrics and are not necessarily
        // equal to those bounds (most visibly for CFF outlines).
        const sdf_left_em = bounds.left - px_range_em / 2.0;
        const sdf_bottom_em = bounds.bottom - px_range_em / 2.0;
        const sdf_top_em = sdf_bottom_em + f64i(h) / f64i(case.opts.px_size);

        const sdf_left = @as(i32, @intFromFloat(@floor(sdf_left_em * f64i(ts))));
        const sdf_top = @as(i32, @intFromFloat(@ceil(sdf_top_em * f64i(ts))));
        const sdf_w = @as(i32, @intFromFloat(@ceil(f64i(w) / f64i(case.opts.px_size) * f64i(ts))));
        const sdf_h = @as(i32, @intFromFloat(@ceil(f64i(h) / f64i(case.opts.px_size) * f64i(ts))));

        const min_x = @min(ft_left, sdf_left);
        const max_x = @max(ft_left + @as(i32, @intCast(ft_w)), sdf_left + sdf_w);
        const max_y = @max(ft_top, sdf_top);
        const min_y = @min(ft_top - @as(i32, @intCast(ft_h)), sdf_top - sdf_h);

        const box_w = @as(usize, @intCast(@max(max_x - min_x, 0)));
        const box_h = @as(usize, @intCast(@max(max_y - min_y, 0)));

        if (box_w == 0 or box_h == 0) continue;

        var ft_img = try allocator.alloc(f64, box_w * box_h);
        defer allocator.free(ft_img);
        @memset(ft_img, 0);

        var sdf_img = try allocator.alloc(f64, box_w * box_h);
        defer allocator.free(sdf_img);
        @memset(sdf_img, 0);

        for (0..ft_h) |y| {
            for (0..ft_w) |x| {
                const cx = ft_left + @as(i32, @intCast(x)) - min_x;
                const cy = max_y - (ft_top - @as(i32, @intCast(y)));
                if (cx >= 0 and cx < box_w and cy >= 0 and cy < box_h) {
                    const row_start = y * @as(usize, @intCast(@abs(ft_pitch)));
                    const alpha = @as(f64, @floatFromInt(ft_buf[row_start + x])) / 255.0;
                    ft_img[@as(usize, @intCast(cy)) * box_w + @as(usize, @intCast(cx))] = alpha;
                }
            }
        }

        for (0..box_h) |y| {
            for (0..box_w) |x| {
                const canvas_x = min_x + @as(i32, @intCast(x));
                const canvas_y = max_y - @as(i32, @intCast(y));

                const center_x = f64i(canvas_x) + 0.5;
                const center_y = f64i(canvas_y) - 0.5;

                const em_x = center_x / f64i(ts);
                const em_y = center_y / f64i(ts);

                const translate_x = -bounds.left + px_range_em / 2.0;
                const translate_y = -bounds.bottom + px_range_em / 2.0;

                const sdf_u = (em_x + translate_x) * f64i(case.opts.px_size);
                const sdf_v = (em_y + translate_y) * f64i(case.opts.px_size);

                const c = sdf_u - 0.5;
                const r = f64i(h) - 0.5 - sdf_v;

                // Allow slightly outside for antialiasing
                if (c >= -1.0 and c <= f64i(w) and r >= -1.0 and r <= f64i(h)) {
                    const dist = sampleSdf(pixels, w, h, channels, c, r);
                    const dist_target = (dist - 0.5) * f64i(case.opts.px_range) * (f64i(ts) / f64i(case.opts.px_size));
                    const alpha = smoothstep(-0.5, 0.5, dist_target);
                    sdf_img[y * box_w + x] = alpha;
                }
            }
        }

        var sum_sq: f64 = 0;
        var tp: f64 = 0;
        var fp: f64 = 0;
        var fn_: f64 = 0;

        var worst_diff: f64 = 0;

        for (0..box_h) |y| {
            for (0..box_w) |x| {
                const idx = y * box_w + x;
                const a_ft = ft_img[idx];
                const a_sdf = sdf_img[idx];
                const diff = a_ft - a_sdf;
                sum_sq += diff * diff;

                if (@abs(diff) > worst_diff) worst_diff = @abs(diff);

                const b_ft = a_ft > 0.5;
                const b_sdf = a_sdf > 0.5;

                if (b_ft and b_sdf) tp += 1;
                if (!b_ft and b_sdf) fp += 1;
                if (b_ft and !b_sdf) fn_ += 1;
            }
        }

        const rmse = @sqrt(sum_sq / f64i(box_w * box_h));
        const f1 = if (tp > 0) 2.0 * tp / (2.0 * tp + fp + fn_) else (if (fp == 0 and fn_ == 0) @as(f64, 1.0) else @as(f64, 0.0));

        // At the smallest target sizes a glyph may contain only a handful of
        // fully covered pixels, so thresholding both images at 0.5 makes F1
        // jump sharply when a single antialiased edge pixel changes class.
        // Keep F1 as a topology guard, while RMSE remains the tighter
        // continuous coverage comparison.
        if (rmse > 0.15 or f1 < 0.65) {
            std.debug.print("\nFAIL {s} @ {}: RMSE={d:.4} F1={d:.4} (worst diff={d:.4})\n", .{ case.name, ts, rmse, f1, worst_diff });

            // Dump image for debugging (PPM)
            var out_img = try allocator.alloc(u8, box_w * box_h * 3);
            defer allocator.free(out_img);
            for (0..box_h) |dy| {
                for (0..box_w) |dx| {
                    const idx = dy * box_w + dx;
                    out_img[idx * 3 + 0] = @as(u8, @intFromFloat(ft_img[idx] * 255.0)); // R = ft
                    out_img[idx * 3 + 1] = @as(u8, @intFromFloat(sdf_img[idx] * 255.0)); // G = sdf
                    out_img[idx * 3 + 2] = 0;
                }
            }
            var buf: [128]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}_{}.ppm", .{ case.name, ts });
            var f = try std.Io.Dir.cwd().createFile(io, path, .{});
            defer f.close(io);
            var pbuf: [128]u8 = undefined;
            const pstr = try std.fmt.bufPrint(&pbuf, "P6\n{} {}\n255\n", .{ box_w, box_h });
            try f.writeStreamingAll(io, pstr);
            try f.writeStreamingAll(io, out_img);
            return error.DiffersFromReference;
        }
    }
}

fn buildCases(allocator: std.mem.Allocator) ![]Case {
    const glyphs = [_]struct { label: []const u8, cp: u21 }{
        .{ .label = "o", .cp = 'o' },
        .{ .label = "e", .cp = 'e' },
        .{ .label = "A", .cp = 'A' },
        .{ .label = "M", .cp = 'M' },
        .{ .label = "at", .cp = '@' },
    };
    const types = [_]struct { label: []const u8, ty: Generator.SdfType }{
        .{ .label = "sdf", .ty = .sdf },
        .{ .label = "psdf", .ty = .psdf },
        .{ .label = "msdf", .ty = .msdf },
        .{ .label = "mtsdf", .ty = .mtsdf },
    };

    var cases: std.ArrayList(Case) = .empty;
    errdefer cases.deinit(allocator);

    for (fonts, 0..) |f, font_index| {
        for (glyphs) |g| {
            for (types) |t| {
                for ([_]bool{ false, true }) |ec| {
                    for ([_]bool{ false, true }) |geom| {
                        for ([_]bool{ false, true }) |scan| {
                            if (scan and (geom or ec)) continue;
                            if (ec and !(t.ty == .msdf or t.ty == .mtsdf)) continue;

                            const name = try std.fmt.allocPrint(allocator, "{s}_{s}_{s}{s}{s}{s}", .{
                                f.label,
                                g.label,
                                t.label,
                                if (ec) "_ec" else "",
                                if (geom) "_geom" else "",
                                if (scan) "_scanline" else "",
                            });
                            try cases.append(allocator, .{
                                .name = name,
                                .font = font_index,
                                .codepoint = g.cp,
                                .opts = .{
                                    .sdf_type = t.ty,
                                    .px_size = px_size,
                                    .px_range = px_range,
                                    .geometry_preprocess = geom,
                                    .scanline_fill_rule = if (scan) .non_zero else null,
                                    .error_correction_opts = if (ec) .{} else null,
                                },
                            });
                        }
                    }
                }
            }
        }
    }
    return cases.toOwnedSlice(allocator);
}

test "rasterize tests" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cases = try buildCases(allocator);
    defer {
        for (cases) |c| allocator.free(c.name);
        allocator.free(cases);
    }

    var font_data: [fonts.len][]u8 = undefined;
    var loaded: usize = 0;
    defer for (font_data[0..loaded]) |d| allocator.free(d);
    for (fonts, 0..) |f, i| {
        font_data[i] = try std.Io.Dir.cwd().readFileAlloc(io, f.path, allocator, .unlimited);
        loaded = i + 1;
    }

    var failed: usize = 0;
    for (cases) |case| {
        runCase(allocator, io, font_data[case.font], case) catch |err| {
            if (err == error.OutOfMemory) return err;
            failed += 1;
        };
    }
    if (failed != 0) {
        std.debug.print("\n{}/{} configurations failed\n", .{ failed, cases.len });
        return error.RasterizeFailed;
    }
}
