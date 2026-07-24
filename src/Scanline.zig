const std = @import("std");

const math = @import("math.zig");

const Scanline = @This();

pub const Intersection = struct {
    x: f64,
    dir: i32,

    pub fn lessThan(_: void, a: Intersection, b: Intersection) bool {
        return a.x < b.x;
    }
};

pub const FillRule = enum {
    non_zero,
    odd,
    positive,
    negative,
};

intersections: std.ArrayList(Intersection) = .empty,
last_index: u32 = 0,

pub fn interpretFillRule(intersections: i32, fill_rule: FillRule) bool {
    return switch (fill_rule) {
        .non_zero => intersections != 0,
        .odd => @mod(intersections, 2) == 1,
        .positive => intersections > 0,
        .negative => intersections < 0,
    };
}

/// Length of the sub-interval of [x_from, x_to] on which `a` and `b` agree.
/// Both must have been preprocessed, so `dir` already holds the running total.
pub fn overlap(a: Scanline, b: Scanline, x_from: f64, x_to: f64, fill_rule: FillRule) f64 {
    const a_items = a.intersections.items;
    const b_items = b.intersections.items;

    var total: f64 = 0.0;
    var a_inside = false;
    var b_inside = false;
    var ai: usize = 0;
    var bi: usize = 0;
    var ax = if (a_items.len != 0) a_items[ai].x else x_to;
    var bx = if (b_items.len != 0) b_items[bi].x else x_to;

    // Wind both cursors forward to x_from, tracking inside-ness but not area.
    while (ax < x_from or bx < x_from) {
        const x_next = @min(ax, bx);
        if (ax == x_next and ai < a_items.len) {
            a_inside = interpretFillRule(a_items[ai].dir, fill_rule);
            ai += 1;
            ax = if (ai < a_items.len) a_items[ai].x else x_to;
        }
        if (bx == x_next and bi < b_items.len) {
            b_inside = interpretFillRule(b_items[bi].dir, fill_rule);
            bi += 1;
            bx = if (bi < b_items.len) b_items[bi].x else x_to;
        }
    }

    var x = x_from;
    while (ax < x_to or bx < x_to) {
        const x_next = @min(ax, bx);
        if (a_inside == b_inside) total += x_next - x;
        if (ax == x_next and ai < a_items.len) {
            a_inside = interpretFillRule(a_items[ai].dir, fill_rule);
            ai += 1;
            ax = if (ai < a_items.len) a_items[ai].x else x_to;
        }
        if (bx == x_next and bi < b_items.len) {
            b_inside = interpretFillRule(b_items[bi].dir, fill_rule);
            bi += 1;
            bx = if (bi < b_items.len) b_items[bi].x else x_to;
        }
        x = x_next;
    }
    if (a_inside == b_inside) total += x_to - x;
    return total;
}

pub fn sumIntersections(self: *Scanline, x: f64) i32 {
    const index = self.moveTo(x);
    if (index) |i| return self.intersections.items[i].dir;
    return 0;
}

pub fn filled(self: *Scanline, x: f64, fill_rule: FillRule) bool {
    return interpretFillRule(self.sumIntersections(x), fill_rule);
}

pub fn preprocess(self: *Scanline) void {
    self.last_index = 0;
    if (self.intersections.items.len == 0) return;
    std.sort.pdq(Intersection, self.intersections.items, {}, Intersection.lessThan);
    var total_direction: i32 = 0;
    for (self.intersections.items) |*intersection| {
        total_direction += intersection.dir;
        intersection.dir = total_direction;
    }
}

pub fn moveTo(self: *Scanline, x: f64) ?u32 {
    if (self.intersections.items.len == 0) return null;

    var index = self.last_index;
    if (x < self.intersections.items[index].x) {
        if (index == 0) {
            self.last_index = 0;
            return null;
        }
        index -= 1;

        while (x < self.intersections.items[index].x) {
            if (index == 0) {
                self.last_index = 0;
                return null;
            }
            index -= 1;
        }
    } else while (index < self.intersections.items.len - 1 and x >= self.intersections.items[index + 1].x)
        index += 1;

    self.last_index = index;
    return index;
}

/// Builds a preprocessed scanline from raw (x, direction) crossings, where +1
/// enters the shape and -1 leaves it.
fn testScanline(allocator: std.mem.Allocator, crossings: []const Intersection) !Scanline {
    var line: Scanline = .{};
    try line.intersections.appendSlice(allocator, crossings);
    line.preprocess();
    return line;
}

test "preprocess sorts and accumulates directions" {
    const allocator = std.testing.allocator;
    var line = try testScanline(allocator, &.{
        .{ .x = 3, .dir = -1 },
        .{ .x = 1, .dir = 1 },
    });
    defer line.intersections.deinit(allocator);

    // Sorted by x, and dir becomes the running total: inside after x=1, out at x=3.
    try std.testing.expectEqual(@as(f64, 1), line.intersections.items[0].x);
    try std.testing.expectEqual(@as(i32, 1), line.intersections.items[0].dir);
    try std.testing.expectEqual(@as(f64, 3), line.intersections.items[1].x);
    try std.testing.expectEqual(@as(i32, 0), line.intersections.items[1].dir);
}

test "filled reports inside-ness between crossings" {
    const allocator = std.testing.allocator;
    var line = try testScanline(allocator, &.{
        .{ .x = 1, .dir = 1 },
        .{ .x = 3, .dir = -1 },
    });
    defer line.intersections.deinit(allocator);

    try std.testing.expect(!line.filled(0.5, .non_zero));
    try std.testing.expect(line.filled(2.0, .non_zero));
    try std.testing.expect(!line.filled(4.0, .non_zero));
}

test "overlap measures where two scanlines agree" {
    const allocator = std.testing.allocator;
    // a is inside over [1,3], b over [2,4]. They agree on [0,1] and [3,4]
    // (both outside / both... ) -- concretely: both outside on [0,1], disagree
    // on [1,2], both inside on [2,3], disagree on [3,4], both outside on [4,5].
    var a = try testScanline(allocator, &.{ .{ .x = 1, .dir = 1 }, .{ .x = 3, .dir = -1 } });
    defer a.intersections.deinit(allocator);
    var b = try testScanline(allocator, &.{ .{ .x = 2, .dir = 1 }, .{ .x = 4, .dir = -1 } });
    defer b.intersections.deinit(allocator);

    // Agreeing length over [0,5] is 1 + 1 + 1 = 3.
    try std.testing.expectApproxEqAbs(
        @as(f64, 3.0),
        overlap(a, b, 0, 5, .non_zero),
        1e-9,
    );
}

test "overlap of a scanline with itself is the whole interval" {
    const allocator = std.testing.allocator;
    var a = try testScanline(allocator, &.{ .{ .x = 1, .dir = 1 }, .{ .x = 3, .dir = -1 } });
    defer a.intersections.deinit(allocator);

    try std.testing.expectApproxEqAbs(
        @as(f64, 5.0),
        overlap(a, a, 0, 5, .non_zero),
        1e-9,
    );
}

test "overlap of empty scanlines spans the interval" {
    const empty: Scanline = .{};
    try std.testing.expectApproxEqAbs(
        @as(f64, 4.0),
        overlap(empty, empty, 0, 4, .non_zero),
        1e-9,
    );
}
