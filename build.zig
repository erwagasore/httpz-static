const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const module = b.addModule("httpz-static", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "httpz", .module = httpz.module("httpz") },
        },
    });

    const tests = b.addTest(.{
        .name = "httpz-static-test",
        .root_module = module,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const checks = b.addTest(.{
        .name = "httpz-static-check",
        .root_module = module,
    });
    const check_step = b.step("check", "Compile without emitting binaries");
    check_step.dependOn(&checks.step);

    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "build.zig.zon", "src" },
        .check = true,
    });
    const fmt_step = b.step("fmt", "Check formatting");
    fmt_step.dependOn(&fmt.step);

    const ci_step = b.step("ci", "Run formatting, compile checks, and tests");
    ci_step.dependOn(fmt_step);
    ci_step.dependOn(check_step);
    ci_step.dependOn(test_step);
}
