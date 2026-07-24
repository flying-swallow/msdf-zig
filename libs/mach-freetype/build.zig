const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const use_system_zlib = b.option(bool, "use_system_zlib", "Use system zlib") orelse false;

    const freetype_dep = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .use_system_zlib = use_system_zlib,
    });
    const freetype_lib = freetype_dep.artifact("freetype");

    // `@cImport` was removed as a builtin, so the FreeType headers (listed in src/c.h) are
    // translated by the build system and exposed to freetype.zig as the "c" module. The
    // include path comes from the FreeType artifact's installed headers.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(freetype_lib.getEmittedIncludeTree());
    const c_module = translate_c.createModule();

    const freetype_module = b.addModule("mach-freetype", .{
        .root_source_file = b.path("src/freetype.zig"),
    });
    freetype_module.addImport("c", c_module);

    const freetype_tests = b.addTest(.{
        .name = "freetype-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/freetype.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    freetype_tests.root_module.addImport("freetype", freetype_module);

    freetype_tests.root_module.linkLibrary(freetype_lib);
    freetype_module.linkLibrary(freetype_lib);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(freetype_tests).step);
}
