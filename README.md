# msdf-zig
A Zig implementation of [Viktor Chlumský's signed distance field generator](https://github.com/Chlumsky/msdfgen).

## Usage
```zig
const Generator = @import("msdf-zig");
const font_data = @embedFile("OpenSans-Bold.ttf");

var gen: Generator = try .create(font_data);
defer gen.destroy();

inline for (.{ 'A', 'B', 'C' }) |codepoint| {
    const data = try gen.generateSingle(allocator, codepoint, .{ .sdf_type = .mtsdf, .px_size = 64, .px_range = 8 });
    defer data.deinit(allocator);
    
    var image: zstbi.Image = try .createEmpty(data.glyph_data.width, data.glyph_data.height, Generator.SdfType.numChannels(.mtsdf), .{});
    defer image.deinit();
    @memcpy(image.data, data.pixels.normal);

    const path = std.fmt.comptimePrint("{u}_sdf.png", .{codepoint});
    try image.writeToFile(path, .png);
}
```

A more in-depth example can be found in `example/generate.zig`.

## Testing

`zig build test` compares generated SDFs against reference bitmaps produced by
msdfgen 1.13 itself, across both a TrueType (quadratic) and a CFF (cubic) face,
all four SDF types, and every error-correction / geometry-preprocessing /
scanline combination. The fixtures live in `src/test/fixtures` and are committed,
so the suite needs no C++ toolchain. See `tools/oracle/` to regenerate them
against a different msdfgen version.

## Disclaimer
This library might provide an option for it later, but you currently need to preprocess your fonts manually to resolve overlapping contours (if the font has them).

## Changes

### Edge coloring is now deterministic and msdfgen-compatible

`GenerationOptions.coloring_rng_seed` is now `coloring_seed`. Coloring previously
used a module-global PRNG, which both diverged from msdfgen's colorings for every
seed and made `generateSingle`/`generateAtlas` non-reentrant. It now uses
msdfgen's own seed-driven scheme, so a given seed reproduces msdfgen's coloring
exactly and generation is thread-safe.

The default seed of `0` still produces a valid coloring, but not the same one as
before — regenerate any cached atlases.