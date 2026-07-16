const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const freetype = b.dependency("mach_freetype", .{
        .optimize = optimize,
        .target = target,
    }).module("mach-freetype");
    const turbopack = b.dependency("turbopack", .{
        .optimize = optimize,
        .target = target,
    }).module("turbopack");

    _ = b.addModule("msdf-zig", .{
        .root_source_file = b.path("src/Generator.zig"),
        .imports = &.{
            .{ .name = "mach-freetype", .module = freetype },
            .{ .name = "turbopack", .module = turbopack },
        },
    });

    // The differential tests read the committed fixtures and the example font by
    // repo-relative path, so the run step needs the build root as its cwd.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mach-freetype", .module = freetype },
            .{ .name = "turbopack", .module = turbopack },
        },
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));

    const test_step = b.step("test", "Compare generated SDFs against the msdfgen reference fixtures");
    test_step.dependOn(&run_tests.step);
}
