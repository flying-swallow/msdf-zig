const std = @import("std");
const stbi = @import("stbi");

pub fn dumpComparison(allocator: std.mem.Allocator, name: []const u8, ts: u32, w: usize, h: usize, ft_img: []const f64, sdf_img: []const f64) !void {
    var out_img = try allocator.alloc(u8, w * h * 3);
    defer allocator.free(out_img);
    
    for (0..h) |y| {
        for (0..w) |x| {
            const idx = y * w + x;
            const ft = @as(u8, @intFromFloat(ft_img[idx] * 255.0));
            const sdf = @as(u8, @intFromFloat(sdf_img[idx] * 255.0));
            
            out_img[idx * 3 + 0] = ft;
            out_img[idx * 3 + 1] = sdf;
            out_img[idx * 3 + 2] = 0;
        }
    }
    
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}_{}.png", .{name, ts});
    
    var image: stbi.Image = try .createEmpty(@as(u32, @intCast(w)), @as(u32, @intCast(h)), 3, .{});
    defer image.deinit();
    @memcpy(image.data, out_img);
    try image.writeToFile(path, .png);
}
