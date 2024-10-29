const std = @import("std");
const fs = std.fs;
const Build = std.Build;
const LazyPath = Build.LazyPath;

pub const OBJFW_FLAGS = &.{
  "-fexceptions",
  "-fobjc-exceptions",
  "-funwind-tables",
  "-fconstant-string-class=OFConstantString",
  "-Xclang",
  "-fno-constant-cfstrings",
  "-Xclang",
  "-fblocks",
  "-Wall",
  "-fobjc-arc",
  "-fobjc-arc-exceptions"
};

fn setupExternalRun(run: *Build.Step.Run, cwd: LazyPath) void {
    run.setCwd(cwd);
    run.setEnvironmentVariable("CC", "zig cc");
    run.setEnvironmentVariable("CXX", "zig c++");
}

fn setupClangdConfig(b: *Build, objfw_include_path: []const u8, openssl_include_path: []const u8) !void {
    const clangd_file_name = ".clangd";
    const cwd = fs.cwd();
    const clangd_exists = if (cwd.statFile(clangd_file_name)) |_| true else |_| false;

    if (clangd_exists) {
        return;
    }

    const clangd_file = try cwd.createFile(clangd_file_name, .{.mode = 0o644});
    defer clangd_file.close();

    _ = try clangd_file.write("CompileFlags:\n  Add:\n");

    inline for (OBJFW_FLAGS) | flag | {
        _ = try clangd_file.write(b.fmt("    - {s}\n", .{flag}));
    }

    const line = try std.mem.concat(b.allocator, u8, &.{
        "    - -I", objfw_include_path, "\n",
        "    - -I", openssl_include_path, "\n",
        "    - -Iinclude\n",
    });

    _ = try clangd_file.write(line);
}

const VscodeConfig = struct {
    @"files.associations": struct {
        @"*.h": []const u8 = "",
    } = .{.@"*.h" = ""},
    @"debug.allowBreakpointsEverywhere": bool = false,
};

fn setupVscodeConfig(b: *Build) !void {
    const config_file_path = ".vscode/settings.json";
    const cwd = fs.cwd();

    cwd.makeDir(".vscode") catch {};

    const config_file = cwd.openFile(config_file_path, .{.mode = .read_write}) catch try cwd.createFile(config_file_path, .{.mode = 0o644});
    defer config_file.close();

    var config_file_contents = config_file.readToEndAlloc(b.allocator, 1024) catch "{}";

    if (config_file_contents.len < 2) {
        config_file_contents = "{}";
    }

    var json = try std.json.parseFromSlice(VscodeConfig, b.allocator, config_file_contents, .{});
    defer json.deinit();

    json.value.@"files.associations".@"*.h" = "objective-cpp";
    json.value.@"debug.allowBreakpointsEverywhere" = true;

    const json_contents = try std.json.stringifyAlloc(b.allocator, json.value, .{});

    try config_file.seekTo(0);
    try config_file.writeAll(json_contents);
}

fn buildObjFW(b: *Build, objfw: *Build.Dependency, openssl: *Build.Dependency, prefix: []const u8, dependant: *Build.Step.Compile) void {
    const objfw_source = objfw.path("");
    const objfw_autogen_path = objfw.path("autogen.sh").getPath(b);
    const objfw_configure_path = objfw.path("configure").getPath(b);
    const openssl_include_path = openssl.module("includes").root_source_file.?.getPath(b);
    const openssl_lib_path = openssl.module("libs").root_source_file.?.getPath(b);

    const objfw_autogen_command = b.addSystemCommand(&.{
        objfw_autogen_path,
    });
    setupExternalRun(objfw_autogen_command, objfw_source);
    objfw_autogen_command.step.dependOn(openssl.builder.default_step);

    const objfw_configure_command = b.addSystemCommand(&.{
        objfw_configure_path,
        b.fmt("--prefix={s}", .{prefix}),
        "--with-tls=openssl",
        "--enable-static",
        "--disable-shared",
    });
    setupExternalRun(objfw_configure_command, objfw_source);
    objfw_configure_command.setEnvironmentVariable(
        "OBJCFLAGS",
        b.fmt("-I{s}", .{openssl_include_path})
    );
    objfw_configure_command.setEnvironmentVariable(
        "LDFLAGS",
        b.fmt("-L{s}", .{openssl_lib_path})
    );
    objfw_configure_command.step.dependOn(&objfw_autogen_command.step);

    const cpus = std.Thread.getCpuCount() catch 1;
    const objfw_make_build_command = b.addSystemCommand(&.{
        "make",
        b.fmt("-j{d}", .{cpus}),
    });
    setupExternalRun(objfw_make_build_command, objfw_source);
    objfw_make_build_command.step.dependOn(&objfw_configure_command.step);

    const objfw_make_install_command = b.addSystemCommand(&.{
        "make",
        "install",
    });
    setupExternalRun(objfw_make_install_command, objfw_source);
    objfw_make_install_command.step.dependOn(&objfw_make_build_command.step);

    dependant.step.dependOn(&objfw_make_install_command.step);
}

pub fn build(b: *Build) void {
    const default_link_options: Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .static
    };
    const cwd = fs.cwd();
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "objfw-full",
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });

    const openssl = b.dependency("openssl", .{
        .target = target,
        .optimize = optimize,
    });
    const openssl_lib_ssl = openssl.module("lib_ssl").root_source_file.?;
    const openssl_lib_crypto = openssl.module("lib_crypto").root_source_file.?;
    const openssl_include_path = openssl.module("includes").root_source_file.?.getPath(b);

    const objfw = b.dependency("objfw", .{
        .target = target,
        .optimize = optimize,
    });

    const objfw_prefix = b.path(".zig-cache/objfw");
    const objfw_include = objfw_prefix.path(b, "include");
    const objfw_lib = objfw_prefix.path(b, "lib");
    const objfw_lib_main = objfw_lib.path(b, "libobjfw.a");
    const objfw_lib_tls = objfw_lib.path(b, "libobjfwtls.a");
    const objfw_lib_main_exists = if (cwd.statFile(objfw_lib_main.getPath(b))) |_| true else |_| false;
    const objfw_lib_tls_exists = if (cwd.statFile(objfw_lib_tls.getPath(b))) |_| true else |_| false;

    if (!objfw_lib_main_exists or !objfw_lib_tls_exists) {
        buildObjFW(b, objfw, openssl, objfw_prefix.getPath(b), lib);
    }

    lib.force_load_objc = true;

    lib.linkLibCpp();

    lib.addObjectFile(openssl_lib_ssl);
    lib.addObjectFile(openssl_lib_crypto);
    lib.addObjectFile(objfw_lib_main);
    lib.addObjectFile(objfw_lib_tls);

    lib.linkSystemLibrary2("m", default_link_options);
    lib.linkSystemLibrary2("dl", default_link_options);
    lib.linkSystemLibrary2("objc", default_link_options);
    lib.linkSystemLibrary2("pthread", default_link_options);

    lib.installHeadersDirectory(objfw_include, ".", .{});

    b.installArtifact(lib);

    setupClangdConfig(b, objfw_include.getPath(b), openssl_include_path) catch @panic(".clangd config generate error");
    setupVscodeConfig(b) catch @panic("vscode config generate error");
}
