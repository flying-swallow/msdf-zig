# msdf-zig
A Zig implementation of [Viktor Chlumský's signed distance field generator](https://github.com/Chlumsky/msdfgen).

## Usage
```zig
const Generator = @import("msdf-zig");
const font_data = @embedFile("OpenSans-Bold.ttf");

var gen: Generator = try .create(font_data);
defer gen.destroy();

var seed: u64 = undefined;
io.random(std.mem.asBytes(&seed));

const gen_opts: Generator.GenerationOptions = .{
    .sdf_type = .mtsdf,
    .px_size = 64,
    .px_range = 8,
    .coloring_rng_seed = seed,
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
    @memcpy(image.data, data.pixels.normal);

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{u}_sdf.png", .{codepoint});
    try image.writeToFile(path, .png);
}
```

A more in-depth example can be found in `example/generate.zig`.

## Disclaimer
This library might provide an option for it later, but you currently need to preprocess your fonts manually to resolve overlapping contours (if the font has them).
