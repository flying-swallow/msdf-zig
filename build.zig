const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // The FreeType-free SDF core: build a Shape by hand, rasterize it with `generateFromShape`.
    // No external dependencies, so a consumer that only wants shape -> distance field never links
    // FreeType or turbopack.
    _ = b.addModule("msdf-core", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_step = b.step("test", "Run core and raster-quality tests");
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core_test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // The FreeType font-atlas frontend. Optional: a core-only consumer passes `.font = false` to
    // skip it, so `mach_freetype`/`turbopack` (both lazy in build.zig.zon) are never fetched. It
    // defaults on, so `zig build`, `zig build test`, and existing consumers are unaffected.
    const enable_font = b.option(bool, "font", "Build the FreeType font-atlas frontend module (msdf-zig)") orelse true;
    if (!enable_font) return;

    const freetype = b.lazyDependency("mach_freetype", .{
        .optimize = optimize,
        .target = target,
    }) orelse return;
    const turbopack = b.lazyDependency("turbopack", .{
        .optimize = optimize,
        .target = target,
    }) orelse return;

    _ = b.addModule("msdf-zig", .{
        .root_source_file = b.path("src/Generator.zig"),
        .imports = &.{
            .{ .name = "mach-freetype", .module = freetype.module("mach-freetype") },
            .{ .name = "turbopack", .module = turbopack.module("turbopack") },
        },
    });

    // The raster tests load the example fonts by repo-relative path.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mach-freetype", .module = freetype.module("mach-freetype") },
            .{ .name = "turbopack", .module = turbopack.module("turbopack") },
        },
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));

    test_step.dependOn(&run_tests.step);
}
