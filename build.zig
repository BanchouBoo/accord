const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("accord", .{
        .source_file = std.Build.FileSource.relative("accord.zig"),
        .dependencies = &[_]std.Build.ModuleDependency{},
    });

    const main_tests = b.addTest(.{
        .root_source_file = std.Build.FileSource.relative("accord.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });

    const test_step = b.step("test", "Run tests for accord");
    test_step.dependOn(&main_tests.step);
}
