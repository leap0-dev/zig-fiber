const std = @import("std");

pub fn build(b: *std.Build) void {
    const supported_target = std.Target.Query{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    };
    const target = b.standardTargetOptions(.{
        .whitelist = &.{supported_target},
    });
    const optimize: std.builtin.OptimizeMode = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse switch (b.release_mode) {
        .off => .Debug,
        .any, .safe => .ReleaseSafe,
        .fast => .ReleaseFast,
        .small => .ReleaseSmall,
    };

    const test_step = b.step("test", "Build tests and run them when possible");

    if (target.result.cpu.arch != .x86_64 or target.result.os.tag != .linux) {
        const fail = b.addFail(
            "zig-fiber only supports x86_64-linux because it depends on Linux signal-stack handling and x86_64 context-switch assembly. Use -Dtarget=x86_64-linux to cross-compile from other hosts.",
        );
        b.default_step.dependOn(&fail.step);
        test_step.dependOn(&fail.step);
        return;
    }

    const mod = b.addModule("zig-fiber", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
        .unwind_tables = .async,
        .red_zone = false,
        .omit_frame_pointer = false,
        .error_tracing = true,
    });
    mod.addAssemblyFile(b.path("src/coro/context_switch.s"));

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    if (target.result.cpu.arch == b.graph.host.result.cpu.arch and
        target.result.os.tag == b.graph.host.result.os.tag and
        target.result.abi == b.graph.host.result.abi)
    {
        const run_mod_tests = b.addRunArtifact(mod_tests);
        test_step.dependOn(&run_mod_tests.step);
    } else {
        test_step.dependOn(&mod_tests.step);
    }
}
