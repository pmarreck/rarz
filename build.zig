const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(
		std.builtin.OptimizeMode,
		"optimize",
		"Optimization mode (default: ReleaseFast)",
	) orelse .ReleaseFast;

	// Single source of truth for the version: the package manifest. Copying it
	// into a second literal here would let the two drift silently, and `--about`
	// exists precisely so a user can tell us which build they are running.
	const version = @import("build.zig.zon").version;

	// Static library from Zig source (the core)
	const lib = b.addLibrary(.{
		.name = "rarz",
		.linkage = .static,
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/lib/root.zig"),
			.target = target,
			.optimize = optimize,
			// REQUIRED for the C-hosted architecture, not a convenience.
			// `main()` is C, so Zig's `std.start` never runs. Without libc,
			// `std.Thread.spawn` selects the raw-`clone` Linux implementation,
			// which reads `linux.tls.area_desc` — a descriptor that only
			// `std.start` initializes. In a C-hosted process it stays zeroed,
			// so spawn hits `assert(isValidAlignGeneric(...))` with alignment
			// 0. In ReleaseSafe that panics; in ReleaseFast the assert is
			// compiled out and it becomes UB, leaving every parallel
			// compression result null and silently emitting archives with
			// packed_size == 0. Linking libc selects the pthread-backed
			// implementation, which needs no Zig-side TLS bootstrap.
			// (Latent on macOS, which is always pthread-backed.)
			.link_libc = true,
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
	exe.root_module.linkLibrary(lib);
	exe.root_module.link_libc = true;

	// Build identity, handed to the C CLI so `--about` can report it and so the
	// DEBUG BUILD banner can be gated on the REAL optimize mode.
	//
	// The banner used to be guarded by `#ifndef NDEBUG`. Zig defines NDEBUG for
	// ReleaseFast and ReleaseSmall only — NOT for ReleaseSafe, which is this
	// project's floor and what ./test builds. So every ReleaseSafe run announced
	// itself as a debug build. `RARZ_DEBUG_BUILD` is derived from `optimize`
	// itself, which is the only thing that actually answers the question.
	exe.root_module.addCMacro("RARZ_VERSION", b.fmt("\"{s}\"", .{version}));
	exe.root_module.addCMacro("RARZ_TARGET", b.fmt("\"{s}-{s}\"", .{
		@tagName(target.result.cpu.arch),
		@tagName(target.result.os.tag),
	}));
	exe.root_module.addCMacro("RARZ_OPTIMIZE", b.fmt("\"{s}\"", .{@tagName(optimize)}));
	exe.root_module.addCMacro("RARZ_DEBUG_BUILD", if (optimize == .Debug) "1" else "0");

	// Link progrez library for progress indication
	const progrez_dep = b.dependency("progrez", .{
		.target = target,
		.optimize = optimize,
	});
	exe.root_module.linkLibrary(progrez_dep.artifact("progrez"));
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
			.optimize = .ReleaseSafe, // tests MUST be safety-checked — ReleaseFast masks UB (fleet finding 2026-07-01)
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
	// Embed official-rar multi-volume fixtures for the spanning-payload CRC
	// regression test (paths outside src/lib/ cannot be @embedFile-d directly).
	unit_tests.root_module.addAnonymousImport("rar5_vol_m3_part01", .{ .root_source_file = b.path("tests/fixtures/rar5_vol_m3.part01.rar") });
	unit_tests.root_module.addAnonymousImport("rar5_vol_m3_part02", .{ .root_source_file = b.path("tests/fixtures/rar5_vol_m3.part02.rar") });
	// RAR4 corpus, produced by the official rar 6.21 (see
	// tests/generate_rar4_fixtures.sh). An independent producer is the whole
	// point: fixtures built from our own understanding of the RAR4 layout would
	// have encoded the same field-offset bug they exist to catch.
	unit_tests.root_module.addAnonymousImport("rar4_store", .{ .root_source_file = b.path("tests/fixtures/rar4_store.rar") });
	unit_tests.root_module.addAnonymousImport("rar4_m3", .{ .root_source_file = b.path("tests/fixtures/rar4_m3.rar") });
	// Encryption CLASSIFIER corpus (tests/generate_encryption_fixtures.sh). The
	// question "is this archive mixed-encryption?" is a classifier over
	// archives, so it is tested over the whole set — none/mixed/all in both
	// families — not against one lucky example that a stuck answer would pass.
	unit_tests.root_module.addAnonymousImport("rar5_encrypted_mixed", .{ .root_source_file = b.path("tests/fixtures/rar5_encrypted_mixed.rar") });
	unit_tests.root_module.addAnonymousImport("rar4_encrypted_none", .{ .root_source_file = b.path("tests/fixtures/rar4_encrypted_none.rar") });
	unit_tests.root_module.addAnonymousImport("rar4_encrypted_mixed", .{ .root_source_file = b.path("tests/fixtures/rar4_encrypted_mixed.rar") });
	unit_tests.root_module.addAnonymousImport("rar4_encrypted_all", .{ .root_source_file = b.path("tests/fixtures/rar4_encrypted_all.rar") });
	unit_tests.root_module.addAnonymousImport("rar5_encrypted_none", .{ .root_source_file = b.path("tests/fixtures/rar5_encrypted_none.rar") });
	unit_tests.root_module.addAnonymousImport("rar5_encrypted_all", .{ .root_source_file = b.path("tests/fixtures/rar5_encrypted_all.rar") });
	// Two false-positive classes found by differential sweep against unrar
	// (tests/generate_filter_fixtures.sh): the x86 E8/E8E9 filter, and RAR4
	// files larger than the 4 MB dictionary. unrar tests all four clean.
	unit_tests.root_module.addAnonymousImport("rar5_x86_filter", .{ .root_source_file = b.path("tests/fixtures/rar5_x86_filter.rar") });
	unit_tests.root_module.addAnonymousImport("rar4_x86_filter", .{ .root_source_file = b.path("tests/fixtures/rar4_x86_filter.rar") });
	unit_tests.root_module.addAnonymousImport("rar4_large_window", .{ .root_source_file = b.path("tests/fixtures/rar4_large_window.rar") });
	unit_tests.root_module.addAnonymousImport("rar5_large_window", .{ .root_source_file = b.path("tests/fixtures/rar5_large_window.rar") });
	// RAR 2.90-produced entries LARGER than the sliding window. v20 windows are
	// 64 KB-1 MB, so ordinary files exceed them — unlike RAR4's 4 MB.
	unit_tests.root_module.addAnonymousImport("rar2_v20_md64_large", .{ .root_source_file = b.path("tests/fixtures/rar2_v20_md64_large.rar") });
	unit_tests.root_module.addAnonymousImport("rar2_v20_md1024_large", .{ .root_source_file = b.path("tests/fixtures/rar2_v20_md1024_large.rar") });
	// RAR5 entries ~28x/16x their 128 KB dictionary (generate_streaming_fixtures.sh).
	// unpack50 emitted once at entry end, so these were FALSE POSITIVES and the
	// blocker behind validate's 1 GiB deep-validation cap.
	unit_tests.root_module.addAnonymousImport("rar5_stream_text", .{ .root_source_file = b.path("tests/fixtures/rar5_stream_text.rar") });
	unit_tests.root_module.addAnonymousImport("rar5_stream_filter", .{ .root_source_file = b.path("tests/fixtures/rar5_stream_filter.rar") });
	// RAR3 PPMd streams (generate_ppm_fixtures.sh). The corpus contained none,
	// which is how a non-functional stand-in PPMd survived every gate.
	unit_tests.root_module.addAnonymousImport("rar4_ppm_xml", .{ .root_source_file = b.path("tests/fixtures/rar4_ppm_xml.rar") });
	unit_tests.root_module.addAnonymousImport("rar4_ppm_prose", .{ .root_source_file = b.path("tests/fixtures/rar4_ppm_prose.rar") });
	// Solid RAR5 whose x86-filter region straddles the circular-window wrap
	// while the entry FITS the window (GH #15; generate_wrap_filter_fixture.sh).
	unit_tests.root_module.addAnonymousImport("rar5_solid_wrap_filter", .{ .root_source_file = b.path("tests/fixtures/rar5_solid_wrap_filter.rar") });
	// RAR 2.0 AUDIO blocks (generate_rar2_audio_fixtures.sh; GH #6) — the mm
	// fixture is text and never reached audio mode, so these are the first.
	unit_tests.root_module.addAnonymousImport("rar2_v20_audio_mono", .{ .root_source_file = b.path("tests/fixtures/rar2_v20_audio_mono.rar") });
	unit_tests.root_module.addAnonymousImport("rar2_v20_audio_stereo", .{ .root_source_file = b.path("tests/fixtures/rar2_v20_audio_stereo.rar") });
	unit_tests.root_module.addAnonymousImport("rar5_store", .{ .root_source_file = b.path("tests/fixtures/rar5_store.rar") });
	// Minimal v29-compressed archives — 87 and 162 bytes. Small enough to trace
	// bit-by-bit against the reference decoder when unpack29 misbehaves.
	unit_tests.root_module.addAnonymousImport("rar4_v29_min", .{ .root_source_file = b.path("tests/fixtures/rar4_v29_min.rar") });
	unit_tests.root_module.addAnonymousImport("rar4_v29_lines", .{ .root_source_file = b.path("tests/fixtures/rar4_v29_lines.rar") });
	// RAR 2.90-produced v20 archives. RAR 2.x does NOT always write an
	// end-of-archive block, which our truncation rule wrongly required.
	unit_tests.root_module.addAnonymousImport("rar2_v20_store", .{ .root_source_file = b.path("tests/fixtures/rar2_v20_store.rar") });
	// Minimal v20 COMPRESSED archive: 61 bytes of text -> 20 packed. Small
	// enough to trace bit-by-bit against unpack20.cpp.
	unit_tests.root_module.addAnonymousImport("rar2_v20_min", .{ .root_source_file = b.path("tests/fixtures/rar2_v20_min.rar") });
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

	// Diagnostic harness for CRC investigation. Run via `zig build diagnose`;
	// its *compilation* is also gated on `zig build test` (see below) so CI
	// keeps it building — it silently rotted once under a Zig API bump.
	const diag = b.addExecutable(.{
		.name = "diagnose_crc",
		.root_module = b.createModule(.{
			.root_source_file = b.path("tests/diagnose_crc.zig"),
			.target = target,
			.optimize = optimize,
			.imports = &.{
				.{ .name = "rarz", .module = lib.root_module },
			},
		}),
	});
	diag.root_module.link_libc = true;
	const diag_install = b.addInstallArtifact(diag, .{});
	const diag_step = b.step("diagnose", "Build diagnose_crc helper");
	diag_step.dependOn(&diag_install.step);
	// Compile (not install) the diagnostic as part of `zig build test` so CI
	// enforces its Zig 0.16 compatibility and it can't silently rot again.
	test_step.dependOn(&diag.step);
}
