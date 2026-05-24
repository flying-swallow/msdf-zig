const std = @import("std");

const Generator = @import("msdf-zig");
const stbi = @import("stbi");

fn printableAscii() []const u21 {
    var ret: []const u21 = &.{};
    for (32..127) |i| ret = ret ++ [_]u21{i};
    return ret;
}

pub fn main(init: std.process.Init) !void {
    const clock_res = try std.Io.Clock.resolution(.real, init.io);
    if (clock_res.nanoseconds == 0)
        return error.UnsupportedClock;

    stbi.init(init.gpa, init.io);
    defer stbi.deinit();

    var file = try std.Io.Dir.cwd().openFile(init.io, "assets/DMSerifDisplay-Regular.ttf", .{});
    defer file.close(init.io);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(init.io, &read_buf);

    const font_memory = try reader.interface.allocRemaining(init.gpa, .unlimited);
    defer init.gpa.free(font_memory);

    var gen: Generator = try .create(font_memory);
    defer gen.destroy();

    const metrics = try gen.fontMetrics();
    std.log.info(
        \\Font Metrics:
        \\Ascender: {d:.2}
        \\Descender: {d:.2}
        \\Underline Y: {d:.2}
        \\Underline Thickness: {d:.2}
        \\Line Height: {d:.2}
    , .{
        metrics.ascender,
        metrics.descender,
        metrics.underline_y,
        metrics.underline_thickness,
        metrics.line_height,
    });

    const gen_opts: Generator.GenerationOptions = .{ .sdf_type = .mtsdf, .px_size = 64, .px_range = 8 };
    inline for (.{ 'A', 'B', 'C' }) |codepoint| {
        const time: std.Io.Timestamp = .now(init.io, .real);
        const data = try gen.generateSingle(init.gpa, codepoint, gen_opts);
        defer data.deinit(init.gpa);
        std.log.info("SDF for codepoint {u} generated in: {}us", .{
            codepoint,
            @divFloor(time.durationTo(.now(init.io, .real)).nanoseconds, std.time.ns_per_us),
        });

        var image: stbi.Image = try .createEmpty(data.glyph_data.width, data.glyph_data.height, gen_opts.sdf_type.numChannels(), .{});
        defer image.deinit();
        @memcpy(image.data, data.pixels.normal);

        const path = std.fmt.comptimePrint("{u}_sdf.png", .{codepoint});
        try image.writeToFile(path, .png);
    }

    const atlas_w = 512;
    const atlas_h = 512;
    const time: std.Io.Timestamp = .now(init.io, .real);
    const data = try gen.generateAtlas(
        init.gpa,
        comptime printableAscii(),
        atlas_w,
        atlas_h,
        2,
        true,
        gen_opts,
    );
    defer data.deinit(init.gpa);
    std.log.info("SDF for atlas generated in: {}us", .{
        @divFloor(time.durationTo(.now(init.io, .real)).nanoseconds, std.time.ns_per_us),
    });

    var image: stbi.Image = try .createEmpty(atlas_w, atlas_h, gen_opts.sdf_type.numChannels(), .{});
    defer image.deinit();
    @memcpy(image.data, data.pixels.normal);

    try image.writeToFile("atlas_sdf.png", .png);
}
