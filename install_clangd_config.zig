const std = @import("std");
const constants = @import("constants.zig");

const fs = std.fs;
const Build = std.Build;

const Step = Build.Step;
const LazyPath = Build.LazyPath;

const Id = Step.Id;
const Compile = Step.Compile;

const File = fs.File;

const Self = @This();

pub const base_id: Id = .install_file;
const clangd_config_name = ".clangd";

step: Step,
include_tree: LazyPath,

pub fn create(b: *Build, artifact: *Compile) *Self {
    const self = b.allocator.create(Self) catch @panic("OOM");

    self.* = .{
        .step = Step.init(.{
            .id = base_id,
            .name = b.dupe("clangd config generate"),
            .owner = b,
            .makeFn = make,
        }),
        .include_tree = artifact.getEmittedIncludeTree(),
    };

    self.step.result_cached = if (fs.cwd().access(clangd_config_name, .{})) |_| true else |_| false;

    self.include_tree.addStepDependencies(&self.step);

    return self;
}

pub fn make(step: *Step, prog_node: std.Progress.Node) anyerror!void {
    if (step.cast(Self)) |self| {
        const b = step.owner;
        const cwd = fs.cwd();
        const includes_path = self.include_tree.getPath(b);

        const clangd_file: File = cwd.createFile(clangd_config_name, .{.mode = 0o644}) catch cwd.openFile(clangd_config_name, .{ .mode = .write_only }) catch @panic("cannot open clangd config file");
        defer clangd_file.close();

        _ = try clangd_file.write("CompileFlags:\n  Add:\n");

        inline for (constants.OBJFW_FLAGS) |flag| {
            _ = try clangd_file.write(b.fmt("    - {s}\n", .{flag}));
        }

        _ = try clangd_file.write(b.fmt("    - -I{s}\n    - -Iinclude\n", .{includes_path}));
    } else {
        @panic("cannot cast from Step to Self");
    }

    prog_node.completeOne();
}
