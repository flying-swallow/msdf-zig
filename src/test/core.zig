const std = @import("std");
const core = @import("../core.zig");

fn rectangle(allocator: std.mem.Allocator) !core.Shape {
    var shape: core.Shape = .{};
    errdefer shape.deinit(allocator);

    const contour = try shape.contours.addOne(allocator);
    contour.* = .{};
    try contour.edges.appendSlice(allocator, &.{
        .create(.{ 0, 0 }, .{ 1, 0 }, null, null, .all),
        .create(.{ 1, 0 }, .{ 1, 1 }, null, null, .all),
        .create(.{ 1, 1 }, .{ 0, 1 }, null, null, .all),
        .create(.{ 0, 1 }, .{ 0, 0 }, null, null, .all),
    });
    return shape;
}

fn curvedShape(allocator: std.mem.Allocator) !core.Shape {
    var shape: core.Shape = .{};
    errdefer shape.deinit(allocator);

    const contour = try shape.contours.addOne(allocator);
    contour.* = .{};
    try contour.edges.appendSlice(allocator, &.{
        .create(.{ 0, 0 }, .{ 0.5, 1 }, .{ 1, 0 }, null, .all),
        .create(.{ 1, 0 }, .{ 0.75, -0.5 }, .{ 0.25, -0.5 }, .{ 0, 0 }, .all),
    });
    return shape;
}

test "core rasterizes a manually constructed shape" {
    const allocator = std.testing.allocator;
    var shape = try rectangle(allocator);
    defer shape.deinit(allocator);

    const opts: core.Options = .{
        .sdf_type = .msdf,
        .px_size = 16,
        .px_range = 4,
        .validate_shape = true,
        .normalize_shape = true,
    };
    const data = try core.generateFromShape(allocator, &shape, &opts);
    defer data.deinit(allocator);

    try std.testing.expect(data.width > 0);
    try std.testing.expect(data.height > 0);
    try std.testing.expectEqual(@as(usize, data.width) * data.height * 3, data.pixels.len);
}

test "core accepts quadratic and cubic contours" {
    const allocator = std.testing.allocator;
    var shape = try curvedShape(allocator);
    defer shape.deinit(allocator);

    const opts: core.Options = .{
        .sdf_type = .sdf,
        .px_size = 16,
        .px_range = 4,
        .validate_shape = true,
    };
    const data = try core.generateFromShape(allocator, &shape, &opts);
    defer data.deinit(allocator);

    try std.testing.expect(data.pixels.len > 0);
}

test "msdf10 uses initialized four-byte packed pixels" {
    const allocator = std.testing.allocator;
    var shape = try rectangle(allocator);
    defer shape.deinit(allocator);

    const opts: core.Options = .{
        .sdf_type = .msdf10,
        .px_size = 16,
        .px_range = 4,
    };
    const data = try core.generateFromShape(allocator, &shape, &opts);
    defer data.deinit(allocator);

    try std.testing.expectEqual(@as(usize, data.width) * data.height * 4, data.pixels.len);
    var i: usize = 3;
    while (i < data.pixels.len) : (i += 4)
        try std.testing.expectEqual(@as(u8, 0xc0), data.pixels[i] & 0xc0);
}

test "msdf10 channels match normal MSDF within quantization tolerance" {
    const allocator = std.testing.allocator;
    var msdf_shape = try rectangle(allocator);
    defer msdf_shape.deinit(allocator);
    var packed_shape = try rectangle(allocator);
    defer packed_shape.deinit(allocator);

    const common = .{ .px_size = 16, .px_range = 4 };
    const msdf_opts: core.Options = .{
        .sdf_type = .msdf,
        .px_size = common.px_size,
        .px_range = common.px_range,
    };
    const packed_opts: core.Options = .{
        .sdf_type = .msdf10,
        .px_size = common.px_size,
        .px_range = common.px_range,
    };
    const msdf = try core.generateFromShape(allocator, &msdf_shape, &msdf_opts);
    defer msdf.deinit(allocator);
    const packed_data = try core.generateFromShape(allocator, &packed_shape, &packed_opts);
    defer packed_data.deinit(allocator);

    try std.testing.expectEqual(msdf.width, packed_data.width);
    try std.testing.expectEqual(msdf.height, packed_data.height);

    const tolerance = 1.0 / 255.0 + 1.0 / 1023.0;
    for (0..@as(usize, msdf.width) * msdf.height) |i| {
        const offset = i * 4;
        const value = @as(u32, packed_data.pixels[offset]) |
            @as(u32, packed_data.pixels[offset + 1]) << 8 |
            @as(u32, packed_data.pixels[offset + 2]) << 16 |
            @as(u32, packed_data.pixels[offset + 3]) << 24;
        const packed_channels = [3]u10{
            @truncate(value),
            @truncate(value >> 10),
            @truncate(value >> 20),
        };
        for (packed_channels, 0..) |channel, ch| {
            const normal = @as(f64, @floatFromInt(msdf.pixels[i * 3 + ch])) / 255.0;
            const packed_normal = @as(f64, @floatFromInt(channel)) / 1023.0;
            try std.testing.expectApproxEqAbs(normal, packed_normal, tolerance);
        }
    }
}
