const std = @import("std");
const builtin = @import("builtin");
const buildZon = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shouldStrip = b.option(bool, "strip", "Strip debug information");

    const constsMod = b.addModule("consts", .{
        .root_source_file = b.path("./src/consts.zig"),
        .optimize = optimize,
        .target = target,
        .strip = shouldStrip,
    });

    const compressMod = b.addModule("compress", .{
        .root_source_file = b.path("./src/compress.zig"),
        .optimize = optimize,
        .target = target,
        .strip = shouldStrip,
    });

    const minisignMod = b.addModule("minisign", .{
        .root_source_file = b.path("./src/minisign.zig"),
        .target = target,
        .optimize = optimize,
        .strip = shouldStrip,
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
                .{ .name = "minisign", .module = minisignMod },
                .{ .name = "compress", .module = compressMod },
                .{ .name = "build_options", .module = buildOptions.createModule() },
            },
            .strip = shouldStrip,
        }),
    };

    const exe = b.addExecutable(exeOptions);
    b.installArtifact(exe);

    const checkExe = b.addExecutable(exeOptions);
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

    const main_test_step = b.step("test-main", "Run tests");
    main_test_step.dependOn(&run_exe_tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const io = std.Io.Threaded.global_single_threaded.io();

    const dirpath = "src/config";
    var dir = std.Io.Dir.cwd().openDir(io, dirpath, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.iterate();
    while (try walker.next(io)) |item| {
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
        conf_tests.root_module.addImport("minisign", minisignMod);

        const run_conf_tests = b.addRunArtifact(conf_tests);

        test_step.dependOn(&run_conf_tests.step);

        const step = b.step(step_name, step_desc);
        step.dependOn(&run_conf_tests.step);
    }

    try addBumpStep(b, target, buildOptions.createModule());
}

fn addBumpStep(b: *std.Build, target: std.Build.ResolvedTarget, buildOptions: *std.Build.Module) !void {
    const bump = b.addExecutable(.{
        .name = "bump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bump.zig"),
            .target = target,
            .imports = &[_]std.Build.Module.Import{
                .{ .name = "build_options", .module = buildOptions },
            },
        }),
    });

    const runBump = b.addRunArtifact(bump);

    const commits = b.addSystemCommand(&.{
        "git",
        "log",
        "--pretty=format:%s",
        std.fmt.allocPrint(b.allocator, "v{s}..HEAD", .{buildZon.version}) catch unreachable,
    });
    runBump.step.dependOn(&commits.step);

    const generatedBuildZigZon = runBump.addOutputFileArg("build.zig.zon");
    runBump.addFileArg(commits.captureStdOut(.{}));
    runBump.addFileArg(b.path("build.zig.zon"));

    const wf = b.addUpdateSourceFiles();
    wf.step.dependOn(&runBump.step);
    wf.addCopyFileToSource(generatedBuildZigZon, "build.zig.zon");

    const gitAdd = b.addSystemCommand(&.{
        "git",
        "add",
        "build.zig.zon",
    });
    gitAdd.step.dependOn(&wf.step);

    const gitCommit = b.addSystemCommand(&.{
        "git",
        "commit",
        "-m chore: bump version",
    });
    gitCommit.step.dependOn(&gitAdd.step);

    const tag = b.addExecutable(.{
        .name = "tag",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/git-tag.zig"),
            .target = target,
        }),
    });
    const runTag = b.addRunArtifact(tag);
    runTag.step.dependOn(&gitCommit.step);
    runTag.addFileArg(runBump.captureStdErr(.{}));

    const bumpStep = b.step("bump", "bump package version and commit");
    bumpStep.dependOn(&wf.step);
    bumpStep.dependOn(&runTag.step);
}
