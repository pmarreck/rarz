const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(
		std.builtin.OptimizeMode,
		"optimize",
		"Optimization mode (default: ReleaseFast)",
	) orelse .ReleaseFast;

	// Static library from Zig source (the core)
	const lib = b.addLibrary(.{
		.name = "rarz",
		.linkage = .static,
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/lib/root.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	b.installArtifact(lib);

	// C executable that links the static library through the C FFI
	const exe = b.addExecutable(.{
		.name = "rarz",
		.root_module = b.createModule(.{
			.target = target,
			.optimize = optimize,
		}),
	});
	exe.root_module.addCSourceFile(.{ .file = b.path("src/cli/main.c") });
	exe.root_module.addIncludePath(b.path("include"));
	exe.linkLibrary(lib);
	b.installArtifact(exe);

	// Run step
	const run_cmd = b.addRunArtifact(exe);
	run_cmd.step.dependOn(b.getInstallStep());
	if (b.args) |args| {
		run_cmd.addArgs(args);
	}
	const run_step = b.step("run", "Run the rarz CLI");
	run_step.dependOn(&run_cmd.step);

	// Test step
	const unit_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/lib/root.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	const run_unit_tests = b.addRunArtifact(unit_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);
}
