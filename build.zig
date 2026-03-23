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

	// Add ARM hardware CRC32 helper (only when target CPU has CRC extension;
	// baseline aarch64 cross-compilation targets don't, and -mcpu overrides -march)
	if (target.result.cpu.arch == .aarch64 and
		std.Target.aarch64.featureSetHas(target.result.cpu.features, .crc))
	{
		lib.root_module.addCSourceFile(.{
			.file = b.path("src/lib/crc32_arm.c"),
			.flags = &.{ "-march=armv8-a+crc", "-O3" },
		});
	}

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
	exe.root_module.link_libc = true;

	// Link progrez library for progress indication
	const progrez_dep = b.dependency("progrez", .{
		.target = target,
		.optimize = optimize,
	});
	exe.linkLibrary(progrez_dep.artifact("progrez"));
	exe.root_module.addIncludePath(progrez_dep.path("include"));

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
	// Add ARM CRC32 helper to test compilation too
	if (target.result.cpu.arch == .aarch64 and
		std.Target.aarch64.featureSetHas(target.result.cpu.features, .crc))
	{
		unit_tests.root_module.addCSourceFile(.{
			.file = b.path("src/lib/crc32_arm.c"),
			.flags = &.{ "-march=armv8-a+crc", "-O3" },
		});
	}
	const run_unit_tests = b.addRunArtifact(unit_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);

	// Microbenchmark executable
	const microbench = b.addExecutable(.{
		.name = "microbench",
		.root_module = b.createModule(.{
			.root_source_file = b.path("tests/microbench.zig"),
			.target = target,
			.optimize = .ReleaseFast,
			.imports = &.{
				.{ .name = "rarz", .module = lib.root_module },
			},
		}),
	});
	b.installArtifact(microbench);
	const run_microbench = b.addRunArtifact(microbench);
	run_microbench.step.dependOn(b.getInstallStep());
	const bench_step = b.step("bench", "Run microbenchmarks");
	bench_step.dependOn(&run_microbench.step);
}
