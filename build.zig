const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("accord", .{
        .root_source_file = b.path("accord.zig"),
    });

    const tests = b.addTest(.{
        .root_source_file = b.path("accord.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests for accord");
    test_step.dependOn(&run_tests.step);
}
