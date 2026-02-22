const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("htmlparser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "htmlparser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "htmlparser", .module = mod },
            },
        }),
    });

    const bench_exe = b.addExecutable(.{
        .name = "htmlparser-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "htmlparser", .module = mod },
            },
        }),
    });

    const tools_exe = b.addExecutable(.{
        .name = "htmlparser-tools",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/scripts.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);
    b.installArtifact(bench_exe);
    b.installArtifact(tools_exe);

    const run_step = b.step("run", "Run the demo app");
    const bench_step = b.step("bench", "Run parser/query benchmarks");
    const tools_step = b.step("tools", "Run htmlparser-tools utility");
    const bench_compare_step = b.step("bench-compare", "Benchmark against external parser implementations");
    const conformance_step = b.step("conformance", "Run external parser/selector conformance suites (strict+turbo)");
    const docs_check_step = b.step("docs-check", "Validate markdown links and documented commands");
    const examples_check_step = b.step("examples-check", "Compile and run all examples in test mode");

    const run_cmd = b.addRunArtifact(exe);
    const bench_cmd = b.addRunArtifact(bench_exe);
    const tools_cmd = b.addRunArtifact(tools_exe);

    const setup_parsers_cmd = b.addRunArtifact(tools_exe);
    setup_parsers_cmd.addArg("setup-parsers");

    const setup_fixtures_cmd = b.addRunArtifact(tools_exe);
    setup_fixtures_cmd.addArg("setup-fixtures");
    setup_fixtures_cmd.step.dependOn(&setup_parsers_cmd.step);

    const compare_cmd = b.addRunArtifact(tools_exe);
    compare_cmd.addArg("run-benchmarks");
    compare_cmd.step.dependOn(&setup_fixtures_cmd.step);

    const conformance_cmd = b.addRunArtifact(tools_exe);
    conformance_cmd.addArg("run-external-suites");
    conformance_cmd.addArg("--mode");
    conformance_cmd.addArg("both");

    const docs_check_cmd = b.addRunArtifact(tools_exe);
    docs_check_cmd.addArg("docs-check");

    const examples_check_cmd = b.addRunArtifact(tools_exe);
    examples_check_cmd.addArg("examples-check");

    run_step.dependOn(&run_cmd.step);
    bench_step.dependOn(&bench_cmd.step);
    tools_step.dependOn(&tools_cmd.step);
    bench_compare_step.dependOn(&compare_cmd.step);
    conformance_step.dependOn(&conformance_cmd.step);
    docs_check_step.dependOn(&docs_check_cmd.step);
    examples_check_step.dependOn(&examples_check_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    bench_cmd.step.dependOn(b.getInstallStep());
    tools_cmd.step.dependOn(b.getInstallStep());
    setup_parsers_cmd.step.dependOn(b.getInstallStep());
    setup_fixtures_cmd.step.dependOn(b.getInstallStep());
    compare_cmd.step.dependOn(b.getInstallStep());
    conformance_cmd.step.dependOn(b.getInstallStep());
    docs_check_cmd.step.dependOn(b.getInstallStep());
    examples_check_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
        bench_cmd.addArgs(args);
        tools_cmd.addArgs(args);
        compare_cmd.addArgs(args);
        conformance_cmd.addArgs(args);
        docs_check_cmd.addArgs(args);
        examples_check_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const ship_check_step = b.step("ship-check", "Run release-readiness checks (test + docs + examples)");
    ship_check_step.dependOn(test_step);
    ship_check_step.dependOn(docs_check_step);
    ship_check_step.dependOn(examples_check_step);
}
