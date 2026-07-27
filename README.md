# msdf-zig
A Zig implementation of [Viktor Chlumský's multi-channel signed distance field generator](https://github.com/Chlumsky/msdfgen).

Requires Zig `0.17.0-dev.1465+8b2d0ce21` or newer.

## Usage
```zig
const Generator = @import("msdf-zig");
const font_data = @embedFile("OpenSans-Bold.ttf");

var gen: Generator = try .create(font_data);
defer gen.destroy();

var seed: u64 = undefined;
io.random(std.mem.asBytes(&seed));

const gen_opts: Generator.Options = .{
    .sdf_type = .mtsdf,
    .px_size = 64,
    .px_range = 8,
    .coloring_rng_seed = seed,
    .validate_shape = true,
    .normalize_shape = true,
    .orient_contours = true,
};

for ([_]u21{ 'A', 'B', 'C' }) |codepoint| {
    const data = try gen.generateSingle(allocator, codepoint, &gen_opts);
    defer data.deinit(allocator);
    
    var image: stbi.Image = try .createEmpty(
        data.glyph_data.width,
        data.glyph_data.height,
        gen_opts.sdf_type.numChannels(),
        .{},
    );
    defer image.deinit();
    @memcpy(image.data, data.pixels);

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{u}_sdf.png", .{codepoint});
    try image.writeToFile(path, .png);
}
```

A more in-depth example can be found in `example/generate.zig`.

### FreeType-free shape generation

Consumers that already have vector geometry can import `msdf-core` without
fetching or linking FreeType and turbopack. Build a `Shape` from
`Shape.Contour` and `EdgeSegment` values, then call:

```zig
const msdf = @import("msdf-core");

const opts: msdf.Options = .{
    .sdf_type = .msdf,
    .px_size = 64,
    .px_range = 8,
};
const data = try msdf.generateFromShape(allocator, &shape, &opts);
defer data.deinit(allocator);
```

Pass `-Dfont=false` when building only the core module. Shape preprocessing and
coloring use the same implementation as the font generator. Core options contain
only geometry and raster controls; variable-font and atlas concurrency settings
remain on `Generator.Options`.

Output channels use msdfgen-compatible UNORM rounding. The experimental
`msdf10` format stores three 10-bit distance channels in four bytes per pixel.

## Disclaimer
This library might provide an option for it later, but you currently need to preprocess your fonts manually to resolve overlapping contours (if the font has them).
