//! Differential tests against msdfgen, the C++ original.
//!
//! The fixtures in `fixtures/` are raw f32 bitmaps produced by the reference
//! implementation via `tools/oracle/`. They are committed so this suite stays
//! hermetic -- CI needs no C++ toolchain. See tools/oracle/regenerate.sh for how
//! to rebuild them (only when bumping the msdfgen reference version).
//!
//! The config matrix below mirrors the one in tools/oracle/oracle.cpp. Keep the
//! two in step: a name generated here that has no fixture on disk fails as a
//! missing file rather than silently passing.

const std = @import("std");

const Generator = @import("../Generator.zig");
const pixel_conversion = @import("../pixel_conversion.zig");
const Scanline = @import("../Scanline.zig");

const fixture_dir = "src/test/fixtures";

/// Two faces on purpose, mirroring tools/oracle/oracle.cpp. DM Serif Display is
/// TrueType, so its outlines are entirely quadratic and never reach the cubic
/// code paths; TeX Gyre Termes is CFF, i.e. all-cubic, and is the only thing
/// here that exercises cubic signed distance and cubic bounds.
const fonts = [_]Font{
    .{ .label = "tt", .path = "example/assets/DMSerifDisplay-Regular.ttf" },
    .{ .label = "cff", .path = "example/assets/texgyretermes-regular.otf" },
};

const Font = struct {
    label: []const u8,
    path: []const u8,
};

/// Must match tools/oracle/oracle.cpp.
const px_size = 32;
const px_range = 4;

/// Comparison budget. The oracle stores f32 while msdf-zig computes in f64, so a
/// texel sitting on a quantization boundary can legitimately land a LSB apart --
/// but only a handful should, and none by more than one.
const max_delta = 1;
const max_differing_fraction = 0.02;

const Fixture = struct {
    width: u16,
    height: u16,
    channels: u8,
    /// Reference values, msdf-zig row order (row 0 = shape top).
    pixels: []f32,

    fn deinit(self: Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

fn loadFixture(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !Fixture {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.bin", .{ fixture_dir, name });
    defer allocator.free(path);

    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| {
        std.debug.print(
            "\nfixture '{s}' is missing or unreadable ({s}).\n" ++
                "The matrix here and in tools/oracle/oracle.cpp have drifted, or the\n" ++
                "fixtures were never generated -- see tools/oracle/regenerate.sh.\n",
            .{ path, @errorName(err) },
        );
        return err;
    };
    defer allocator.free(raw);

    const header_len = 8 + 3 * @sizeOf(i32);
    if (raw.len < header_len) return error.FixtureTruncated;
    if (!std.mem.eql(u8, raw[0..8], "MSDFZIG1")) return error.FixtureBadMagic;

    const width = std.mem.readInt(i32, raw[8..12], .little);
    const height = std.mem.readInt(i32, raw[12..16], .little);
    const channels = std.mem.readInt(i32, raw[16..20], .little);
    if (width <= 0 or height <= 0 or channels <= 0) return error.FixtureBadDimensions;

    const count: usize = @intCast(width * height * channels);
    const body = raw[header_len..];
    if (body.len != count * @sizeOf(f32)) return error.FixtureTruncated;

    const pixels = try allocator.alloc(f32, count);
    errdefer allocator.free(pixels);
    // The fixture is little-endian f32; copy rather than @ptrCast so this stays
    // correct on a big-endian host and on an unaligned buffer.
    for (pixels, 0..) |*p, i| {
        const bytes = body[i * 4 ..][0..4];
        p.* = @bitCast(std.mem.readInt(u32, bytes, .little));
    }

    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .channels = @intCast(channels),
        .pixels = pixels,
    };
}

const Comparison = struct {
    differing: usize,
    total: usize,
    worst_delta: u16,
    worst_index: usize,

    fn fraction(self: Comparison) f64 {
        if (self.total == 0) return 0;
        return @as(f64, @floatFromInt(self.differing)) / @as(f64, @floatFromInt(self.total));
    }
};

fn compare(expected: []const f32, actual: []const u8) Comparison {
    var result: Comparison = .{
        .differing = 0,
        .total = actual.len,
        .worst_delta = 0,
        .worst_index = 0,
    };
    for (actual, 0..) |got, i| {
        // Quantize the reference through msdf-zig's own conversion so this
        // compares distance fields, not rounding policy. floatToUnorm has its
        // own unit tests in src/pixel_conversion.zig.
        const want = pixel_conversion.floatToUnorm(u8, expected[i]);
        const delta = @abs(@as(i16, got) - @as(i16, want));
        if (delta != 0) {
            result.differing += 1;
            if (delta > result.worst_delta) {
                result.worst_delta = @intCast(delta);
                result.worst_index = i;
            }
        }
    }
    return result;
}

const Case = struct {
    name: []const u8,
    font: usize,
    codepoint: u21,
    opts: Generator.GenerationOptions,
};

fn runCase(allocator: std.mem.Allocator, io: std.Io, font: []const u8, case: Case) !void {
    const fixture = try loadFixture(allocator, io, case.name);
    defer fixture.deinit(allocator);

    var generator: Generator = try .create(font);
    defer generator.destroy();

    var result = try generator.generateSingle(allocator, case.codepoint, case.opts);
    defer result.deinit(allocator);

    const pixels = switch (result.pixels) {
        .normal => |p| p,
        .msdf10 => return error.UnexpectedPixelFormat,
    };

    // A size mismatch means the geometry setup diverged (bounds, translate, or
    // the w/h formula), which would make a per-texel diff meaningless.
    if (result.glyph_data.width != fixture.width or result.glyph_data.height != fixture.height) {
        std.debug.print(
            "\n{s}: bitmap size {}x{} but msdfgen produced {}x{}\n",
            .{ case.name, result.glyph_data.width, result.glyph_data.height, fixture.width, fixture.height },
        );
        return error.BitmapSizeMismatch;
    }
    try std.testing.expectEqual(fixture.pixels.len, pixels.len);

    const cmp = compare(fixture.pixels, pixels);
    if (cmp.worst_delta > max_delta or cmp.fraction() > max_differing_fraction) {
        const i = cmp.worst_index;
        const texel = i / fixture.channels;
        std.debug.print(
            \\
            \\{s}: differs from msdfgen
            \\  differing texels : {}/{} ({d:.2}%, budget {d:.2}%)
            \\  worst delta      : {} LSB (budget {})
            \\  worst at         : x={} y={} channel={} (msdfgen {d:.4} -> {}, msdf-zig {})
            \\
        , .{
            case.name,
            cmp.differing,
            cmp.total,
            cmp.fraction() * 100,
            max_differing_fraction * 100,
            cmp.worst_delta,
            max_delta,
            texel % fixture.width,
            texel / fixture.width,
            i % fixture.channels,
            fixture.pixels[i],
            pixel_conversion.floatToUnorm(u8, fixture.pixels[i]),
            pixels[i],
        });
        return error.DiffersFromReference;
    }
}

/// Mirrors the nested loops in tools/oracle/oracle.cpp main().
fn buildCases(allocator: std.mem.Allocator) ![]Case {
    const glyphs = [_]struct { label: []const u8, cp: u21 }{
        .{ .label = "o", .cp = 'o' }, // 1-corner "teardrop" contours
        .{ .label = "e", .cp = 'e' },
        .{ .label = "A", .cp = 'A' }, // multi-corner
        .{ .label = "M", .cp = 'M' },
        .{ .label = "at", .cp = '@' }, // nested contours
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
                            // The fill rule is ignored when geometry preprocessing
                            // is on (Generator.zig:572), so that pair is redundant.
                            if (scan and geom) continue;
                            // Error correction only applies to MSDF/MTSDF.
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

test "matches msdfgen" {
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
        std.debug.print("\n{}/{} configurations differ from msdfgen\n", .{ failed, cases.len });
        return error.DiffersFromReference;
    }
}
