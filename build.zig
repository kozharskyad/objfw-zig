const std = @import("std");
const constants = @import("constants.zig");
const InstallClangdConfig = @import("install_clangd_config.zig");
const fs = std.fs;
const Build = std.Build;
const Step = Build.Step;
const LazyPath = Build.LazyPath;

pub const OBJFW_FLAGS = constants.OBJFW_FLAGS;

fn setupExternalRun(run: *Step.Run, cwd: LazyPath) void {
    run.setCwd(cwd);
    run.setEnvironmentVariable("CC", "zig cc");
    run.setEnvironmentVariable("CXX", "zig c++");
}

fn buildObjFW(b: *Build, objfw: *Build.Dependency, openssl_ssl_lib: *Step.Compile, openssl_crypto_lib: *Step.Compile) LazyPath {
    const cwd = fs.cwd();
    const prefix_cache_path = b.cache_root.join(b.allocator, &.{"objfw"}) catch @panic("OOM");
    const prefix_cache = LazyPath{
        .cwd_relative = prefix_cache_path,
    };
    const include_path = prefix_cache.path(b, "include").getPath(b);
    const libs = prefix_cache.path(b, "lib");
    const lib_main_path = libs.path(b, "libobjfw.a").getPath(b);
    const lib_tls_path = libs.path(b, "libobjfwtls.a").getPath(b);

    const include_exists = if (cwd.access(include_path, .{})) |_| true else |_| false;
    const lib_main_exists = if (cwd.access(lib_main_path, .{})) |_| true else |_| false;
    const lib_tls_exists = if (cwd.access(lib_tls_path, .{})) |_| true else |_| false;

    const is_cached = include_exists and lib_main_exists and lib_tls_exists;

    if (is_cached) {
        return prefix_cache;
    }

    const cpus = std.Thread.getCpuCount() catch 1;
    const source = objfw.path("");
    const autogen_path = objfw.path("autogen.sh").getPath(b);
    const configure_path = objfw.path("configure").getPath(b);
    const configure_wrap = objfw.path("configure_wrap");

    const autogen_command = b.addSystemCommand(&.{
        autogen_path,
    });
    setupExternalRun(autogen_command, source);

    const configure_wrap_script = b.addWriteFile(configure_wrap.getPath(b),
        \\OPENSSL_SSL_LIB_DIR="$(dirname """$1""")"
        \\OPENSSL_CRYPTO_LIB_DIR="$(dirname """$2""")"
        \\OPENSSL_SSL_INC_DIR="$3"
        \\OPENSSL_CRYPTO_INC_DIR="$4"
        \\CONFIGURE_REAL_SCRIPT_PATH="$5"
        \\PREFIX_PATH="$6"
        \\CC="zig cc" \
        \\CXX="zig c++" \
        \\LDFLAGS="-L$OPENSSL_SSL_LIB_DIR -L$OPENSSL_CRYPTO_LIB_DIR" \
        \\OBJCFLAGS="-I$OPENSSL_SSL_INC_DIR -I$OPENSSL_CRYPTO_INC_DIR" \
        \\exec $CONFIGURE_REAL_SCRIPT_PATH \
        \\  --prefix="$PREFIX_PATH" \
        \\  --with-tls=openssl \
        \\  --enable-static \
        \\  --disable-shared
        \\
    );
    configure_wrap.addStepDependencies(configure_wrap_script);

    const configure_wrap_command = b.addSystemCommand(&.{
        "bash",
        configure_wrap,
    });
    setupExternalRun(configure_wrap_command, source);
    configure_wrap_command.addFileArg(configure_wrap);
    configure_wrap_command.addArtifactArg(openssl_ssl_lib);
    configure_wrap_command.addArtifactArg(openssl_crypto_lib);
    configure_wrap_command.addDirectoryArg(openssl_ssl_lib.getEmittedIncludeTree());
    configure_wrap_command.addDirectoryArg(openssl_crypto_lib.getEmittedIncludeTree());
    configure_wrap_command.addArg(configure_path);
    configure_wrap_command.addArg(prefix_cache_path);
    configure_wrap_command.step.dependOn(&autogen_command.step);
    configure_wrap_command.step.dependOn(&configure_wrap_script.step);

    const make_clean_command = b.addSystemCommand(&.{
        "make",
        "clean",
    });
    setupExternalRun(make_clean_command, source);
    make_clean_command.step.dependOn(&configure_wrap_command.step);

    const make_build_command = b.addSystemCommand(&.{
        "make",
        b.fmt("-j{d}", .{cpus}),
    });
    setupExternalRun(make_build_command, source);
    make_build_command.step.dependOn(&make_clean_command.step);

    const make_install_command = b.addSystemCommand(&.{
        "make",
        "install",
    });
    setupExternalRun(make_install_command, source);
    make_install_command.step.dependOn(&make_build_command.step);

    const prefix_generated = b.allocator.create(Build.GeneratedFile) catch @panic("OOM");

    prefix_generated.* = .{
        .step = &make_install_command.step,
        .path = prefix_cache.getPath(b),
    };

    return .{ .generated = .{
        .file = prefix_generated,
    } };
}

pub fn build(b: *Build) void {
    const default_link_options = Build.Module.LinkSystemLibraryOptions{ .preferred_link_mode = .static };
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

    const openssl_lib_ssl = openssl.artifact("ssl");
    const openssl_lib_crypto = openssl.artifact("crypto");

    const objfw = b.dependency("objfw", .{
        .target = target,
        .optimize = optimize,
    });

    const prefix = buildObjFW(b, objfw, openssl_lib_ssl, openssl_lib_crypto);
    const libs = prefix.path(b, "lib");
    const includes = prefix.path(b, "include");
    const lib_main = libs.path(b, "libobjfw.a");
    const lib_tls = libs.path(b, "libobjfwtls.a");
    const clangd_config_install = InstallClangdConfig.create(b, lib);

    lib.force_load_objc = true;

    lib.linkLibrary(openssl_lib_ssl);
    lib.linkLibrary(openssl_lib_crypto);

    lib.linkLibCpp();

    lib.addObjectFile(lib_main);
    lib.addObjectFile(lib_tls);

    lib.linkSystemLibrary2("m", default_link_options);
    lib.linkSystemLibrary2("dl", default_link_options);
    lib.linkSystemLibrary2("objc", default_link_options);
    lib.linkSystemLibrary2("pthread", default_link_options);

    lib.installHeadersDirectory(includes, ".", .{});

    b.installArtifact(lib);
    lib.step.dependOn(&clangd_config_install.step);
}
