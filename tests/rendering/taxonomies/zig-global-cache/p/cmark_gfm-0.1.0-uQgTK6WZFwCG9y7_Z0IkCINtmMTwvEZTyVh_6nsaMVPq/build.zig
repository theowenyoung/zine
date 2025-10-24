const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const config = b.addConfigHeader(
        .{ .style = .{ .cmake = b.path("src/config.h.in") } },
        .{
            .HAVE_STDBOOL_H = true,
        },
    );
    const version = b.addConfigHeader(.{
        .style = .{
            .cmake = b.path("src/cmark-gfm_version.h.in"),
        },
    }, .{
        .PROJECT_VERSION_MAJOR = "0",
        .PROJECT_VERSION_MINOR = "29",
        .PROJECT_VERSION_PATCH = "0",
        .PROJECT_VERSION_GFM = "13",
    });

    const cmark_lib = b.addLibrary(.{
        .name = "cmark-gfm",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = b.option(
                bool,
                "tsan",
                "enable thread sanitizer",
            ) orelse false,
        }),
    });
    cmark_lib.addConfigHeader(config);
    cmark_lib.addConfigHeader(version);
    cmark_lib.installConfigHeader(version);

    cmark_lib.installHeader(b.path("src/cmark-gfm.h"), "cmark-gfm.h");
    cmark_lib.installHeader(b.path("src/cmark-gfm_export.h"), "cmark-gfm_export.h");
    cmark_lib.installHeader(b.path("src/cmark-gfm-extension_api.h"), "cmark-gfm-extension_api.h");
    cmark_lib.installHeadersDirectory(b.path("extensions"), "extensions", .{});

    cmark_lib.addCSourceFiles(.{
        .files = lib_src,
        .flags = &.{"-std=c99"},
    });
    b.installArtifact(cmark_lib);

    const cmark_extensions_lib = b.addLibrary(.{
        .name = "cmark-gfm-extensions",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    cmark_extensions_lib.installLibraryHeaders(cmark_lib);
    cmark_extensions_lib.addConfigHeader(config);
    cmark_extensions_lib.addIncludePath(b.path("src"));
    cmark_extensions_lib.installHeader(
        b.path("extensions/cmark-gfm-core-extensions.h"),
        "cmark-gfm-core-extensions.h",
    );
    cmark_extensions_lib.installHeader(
        b.path("extensions/ext_scanners.h"),
        "ext_scanners.h",
    );
    cmark_extensions_lib.addCSourceFiles(.{
        .files = extensions_src,
        .flags = &.{"-std=c99"},
    });
    cmark_extensions_lib.linkLibrary(cmark_lib);

    b.installArtifact(cmark_extensions_lib);

    const cmark_exe = b.addExecutable(.{
        .name = "cmark-gfm-exe",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    cmark_exe.addConfigHeader(config);
    cmark_exe.addConfigHeader(version);
    cmark_exe.addCSourceFile(.{
        .file = b.path("src/main.c"),
        .flags = &.{"-std=c99"},
    });
    cmark_exe.linkLibrary(cmark_extensions_lib);
    b.installArtifact(cmark_exe);
}

const extensions_src: []const []const u8 = &.{
    "extensions/core-extensions.c",
    "extensions/table.c",
    "extensions/strikethrough.c",
    "extensions/autolink.c",
    "extensions/tagfilter.c",
    "extensions/ext_scanners.c",
    "extensions/ext_scanners_re.c",
    "extensions/tasklist.c",
};

const lib_src: []const []const u8 = &.{
    "src/xml.c",
    "src/cmark.c",
    "src/man.c",
    "src/buffer.c",
    "src/blocks.c",
    "src/cmark_ctype.c",
    "src/inlines.c",
    "src/latex.c",
    "src/houdini_href_e.c",
    "src/syntax_extension.c",
    "src/houdini_html_e.c",
    "src/plaintext.c",
    "src/utf8.c",
    "src/references.c",
    "src/render.c",
    "src/iterator.c",
    "src/arena.c",
    "src/linked_list.c",
    "src/commonmark.c",
    "src/map.c",
    "src/html.c",
    "src/plugin.c",
    "src/scanners.c",
    "src/footnotes.c",
    "src/houdini_html_u.c",
    "src/registry.c",
    "src/node.c",
};
