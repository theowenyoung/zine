const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable = b.option(
        bool,
        "enable",
        "Enable Tracy profiling",
    ) orelse false;
    const options = b.addOptions();
    options.addOption(bool, "enable_tracy", enable);
    options.addOption(bool, "enable_tracy_allocation", false);
    options.addOption(bool, "enable_tracy_callstack", true);
    options.addOption(usize, "tracy_callstack_depth", 10);

    const tracy = b.addModule("tracy", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    tracy.addOptions("options", options);

    if (enable) {
        if (target.result.os.tag == .windows) {
            tracy.linkSystemLibrary("dbghelp", .{});
            tracy.linkSystemLibrary("ws2_32", .{});
        }

        // superhtml.addObjectFile(b.path("libTracyClient.a"));
        //
        tracy.linkSystemLibrary("TracyClient", .{});
        tracy.addLibraryPath(.{
            .cwd_relative = "/opt/homebrew/opt/tracy/lib",
        });
        tracy.link_libc = true;
        tracy.link_libcpp = true;
    }

    const unit_tests = b.addTest(.{
        .root_module = tracy,
    });

    const test_step = b.step("test", "Run unit tests");
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}
