const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const folders = b.dependency( "known_folders", .{} ).module( "known-folders" );
    const exe = b.addExecutable(.{
        .name = "dmenu_runner",
        .root_module = exe_mod,
    });

    exe.root_module.addImport( "known_folders", folders );

    const check_exe = b.addExecutable(.{
      .name = "dmenu_runner",
      .root_source_file = b.path( "src/main.zig" ),
      .target = target,
      .optimize = optimize,
    });

    for( exe.root_module.import_table.keys() ) |key|
      check_exe.root_module.addImport( key, exe.root_module.import_table.get( key ) orelse unreachable );

    const check = b.step( "check", "check compile result" );
    check.dependOn( &check_exe.step );

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
