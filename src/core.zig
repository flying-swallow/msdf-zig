//! FreeType-free entry point to msdf-zig's SDF core.
//!
//! `Generator.zig` (the `msdf-zig` module) is a font atlas generator: it takes TTF/CFF bytes and
//! routes through FreeType. This module exposes the geometry-driven half instead — build a `Shape`
//! by hand from lines and quadratic/cubic Béziers, then rasterize it to an SDF/MSDF/MTSDF bitmap
//! via `generateFromShape`. Nothing here imports FreeType, so a consumer that only needs
//! shape → distance-field never links it.

const sdf = @import("sdf.zig");

// Geometry model — build shapes by hand.
pub const Shape = @import("Shape.zig");
pub const Contour = Shape.Contour;
pub const EdgeSegment = @import("EdgeSegment.zig");
pub const EdgeColor = @import("coloring.zig").EdgeColor;

// Generation.
pub const generateFromShape = sdf.generateFromShape;
pub const ShapeData = sdf.ShapeData;
pub const Options = sdf.Options;
pub const SdfType = sdf.SdfType;
pub const ColoringMethod = sdf.ColoringMethod;
pub const Winding = sdf.Winding;
pub const Msdf10Pixel = sdf.Msdf10Pixel;

// Referenced by Options (scanline_fill_rule / error_correction_opts), re-exported so a
// consumer can name those option types.
pub const Scanline = @import("Scanline.zig");
pub const ErrorCorrection = @import("ErrorCorrection.zig");
