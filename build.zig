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

fn setupClangdConfig(b: *Build, headers_paths: []LazyPath, openssl_include_path: []const u8) !void {
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

    for (headers_paths) | headers_path | {
        _ = try clangd_file.write(b.fmt("    - -I{s}\n", .{headers_path.getPath(b)}));
    }

    _ = try clangd_file.write(b.fmt("    - -I{s}\n    - -Iinclude\n", .{openssl_include_path}));
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
    const cpus = std.Thread.getCpuCount() catch 1;
    const source = objfw.path("");
    const autogen_path = objfw.path("autogen.sh").getPath(b);
    const configure_path = objfw.path("configure").getPath(b);
    const openssl_include_path = openssl.module("includes").root_source_file.?.getPath(b);
    const openssl_lib_path = openssl.module("libs").root_source_file.?.getPath(b);

    // ./autogen.sh
    const autogen_command = b.addSystemCommand(&.{
        autogen_path,
    });
    setupExternalRun(autogen_command, source);
    autogen_command.step.dependOn(openssl.builder.default_step);

    // ./configure
    const configure_command = b.addSystemCommand(&.{
        configure_path,
        b.fmt("--prefix={s}", .{prefix}),
        "--with-tls=openssl",
        "--enable-static",
        "--disable-shared",
    });
    setupExternalRun(configure_command, source);
    configure_command.setEnvironmentVariable(
        "OBJCFLAGS",
        b.fmt("-I{s}", .{openssl_include_path})
    );
    configure_command.setEnvironmentVariable(
        "LDFLAGS",
        b.fmt("-L{s}", .{openssl_lib_path})
    );
    configure_command.step.dependOn(&autogen_command.step);

    // make clean
    const make_clean_command = b.addSystemCommand(&.{
        "make",
        "clean",
    });
    setupExternalRun(make_clean_command, source);
    make_clean_command.step.dependOn(&configure_command.step);

    // make build exceptions
    const make_build_exceptions_command = b.addSystemCommand(&.{
        "make",
        "-C", "src/exceptions",
        b.fmt("-j{d}", .{cpus}),
    });
    setupExternalRun(make_build_exceptions_command, source);
    make_build_exceptions_command.step.dependOn(&make_clean_command.step);

    // make build encodings
    const make_build_encodings_command = b.addSystemCommand(&.{
        "make",
        "-C", "src/encodings",
        b.fmt("-j{d}", .{cpus}),
    });
    setupExternalRun(make_build_encodings_command, source);
    make_build_encodings_command.step.dependOn(&make_clean_command.step);

    // make build forwarding
    const make_build_forwarding_command = b.addSystemCommand(&.{
        "make",
        "-C", "src/forwarding",
        b.fmt("-j{d}", .{cpus}),
    });
    setupExternalRun(make_build_forwarding_command, source);
    make_build_forwarding_command.step.dependOn(&make_clean_command.step);

    // make build libobjfw.a
    const make_build_libobjfw_command = b.addSystemCommand(&.{
        "make",
        "-C", "src",
        b.fmt("-j{d}", .{cpus}),
        "libobjfw.a",
    });
    setupExternalRun(make_build_libobjfw_command, source);
    make_build_libobjfw_command.step.dependOn(&make_build_exceptions_command.step);
    make_build_libobjfw_command.step.dependOn(&make_build_encodings_command.step);
    make_build_libobjfw_command.step.dependOn(&make_build_forwarding_command.step);

    // make build libobjfwtls.a
    const make_build_libobjfwtls_command = b.addSystemCommand(&.{
        "make",
        "-C", "src/tls",
        b.fmt("-j{d}", .{cpus}),
        "libobjfwtls.a",
    });
    setupExternalRun(make_build_libobjfwtls_command, source);
    make_build_libobjfwtls_command.step.dependOn(&make_build_libobjfw_command.step);

    const copy_defs_header = b.addWriteFiles();
    const copy_defs_header_dir = copy_defs_header.addCopyFile(objfw.path("src/objfw-defs.h"), "objfw-defs.h").dirname();

    copy_defs_header.step.dependOn(&make_build_libobjfwtls_command.step);
    dependant.installHeadersDirectory(copy_defs_header_dir, "ObjFW", .{});
    dependant.step.dependOn(&copy_defs_header.step);
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
    const objfw_lib_main = objfw.path("src/libobjfw.a");
    const objfw_lib_tls = objfw.path("src/tls/libobjfwtls.a");
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

    var headers_paths = [_]LazyPath{
        objfw.path("src/exceptions"),
        objfw.path("src/bridge"),
        objfw.path("src/platform"),
        objfw.path("src/runtime"),
        objfw.path("src"),
    };

    for (headers_paths) | header_path | {
        lib.installHeadersDirectory(header_path, "ObjFW", .{});
    }

    b.installArtifact(lib);

    setupClangdConfig(b, &headers_paths, openssl_include_path) catch @panic(".clangd config generate error");
    setupVscodeConfig(b) catch @panic("vscode config generate error");
}
