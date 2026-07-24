//! Test root. `zig build test` compiles this; add new test files here.
//!
//! Lives in src/ rather than src/test/ so that the module root is src/ and the
//! test files can reach the implementation they exercise.

test {
    _ = @import("test/rasterize.zig");
    _ = @import("convergent_curve_ordering.zig");
    _ = @import("edge_color.zig");
    _ = @import("pixel_conversion.zig");
    _ = @import("math.zig");
}
