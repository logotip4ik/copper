const std = @import("std");
const builtin = @import("builtin");
const buildZon = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const constsMod = b.addModule("consts", .{
        .root_source_file = b.path("./src/consts.zig"),
    });

    const minisign_module = b.addModule("minisign", .{
        .root_source_file = b.path("./src/libs/minisign.zig"),
        .target = target,
        .optimize = optimize,
    });

    const buildOptions = b.addOptions();
    buildOptions.addOption(
        std.SemanticVersion,
        "version",
        std.SemanticVersion.parse(buildZon.version) catch unreachable,
    );

    const exeOptions: std.Build.ExecutableOptions = .{
        .name = "copper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &[_]std.Build.Module.Import{
                .{ .name = "consts", .module = constsMod },
                .{ .name = "minisign", .module = minisign_module },
            },
        }),
    };

    const checkExe = b.addExecutable(exeOptions);

    const exe = b.addExecutable(exeOptions);
    b.installArtifact(exe);

    checkExe.root_module.addOptions("build_options", buildOptions);
    exe.root_module.addOptions("build_options", buildOptions);

    if (optimize != .Debug) {
        exe.root_module.pic = true;
        exe.pie = true;
        exe.root_module.omit_frame_pointer = true;
        exe.root_module.strip = true;
        exe.want_lto = switch (builtin.os.tag) {
            .macos => false,
            else => true,
        };
    }

    const checkStep = b.step("check", "check if compiles");
    checkStep.dependOn(&checkExe.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.root_module.addImport("consts", constsMod);
    exe_tests.root_module.addOptions("build_options", buildOptions);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const dirpath = "src/config";
    var dir = std.fs.cwd().openDir(dirpath, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.iterate();
    while (try walker.next()) |item| {
        if (item.kind != .file or std.mem.eql(u8, "configs.zig", item.name) or std.mem.eql(u8, "common.zig", item.name)) {
            continue;
        }

        const ext = std.fs.path.extension(item.name);
        if (!std.mem.eql(u8, ".zig", ext)) {
            continue;
        }

        const mod_path = try std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ dirpath, item.name });
        const step_name = try std.fmt.allocPrint(b.allocator, "test-{s}-conf", .{std.fs.path.stem(item.name)});
        const step_desc = try std.fmt.allocPrint(b.allocator, "Run tests for {s}", .{mod_path});

        const conf_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(mod_path),
                .target = target,
                .optimize = optimize,
            }),
        });
        conf_tests.root_module.addOptions("build_options", buildOptions);
        conf_tests.root_module.addImport("consts", constsMod);
        conf_tests.root_module.addImport("minisign", minisign_module);

        const run_conf_tests = b.addRunArtifact(conf_tests);

        test_step.dependOn(&run_conf_tests.step);

        const step = b.step(step_name, step_desc);
        step.dependOn(&run_conf_tests.step);
    }
}
