const Variant = @This();

const std = @import("std");
const log = std.log.scoped(.variant);
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const builtin = @import("builtin");
const ziggy = @import("ziggy");
const FrontParser = ziggy.frontmatter.Parser(Page);
const tracy = @import("tracy");
const fatal = @import("fatal.zig");
const worker = @import("worker.zig");
const context = @import("context.zig");
const Page = context.Page;
const Build = @import("Build.zig");
const StringTable = @import("StringTable.zig");
const String = StringTable.String;
const PathTable = @import("PathTable.zig");
const Path = PathTable.Path;
const PathName = PathTable.PathName;
const Taxonomy = @import("Taxonomy.zig");
const root = @import("root.zig");

output_path_prefix: []const u8,
/// Open for the full duration of the program.
content_dir: std.fs.Dir,
content_dir_path: []const u8,
/// Stores path components
string_table: StringTable,
/// Stores paths as slices of components (stored in string_table)
path_table: PathTable,
/// Section 0 is invalid, always start iterating from [1..].
sections: std.ArrayListUnmanaged(Section),
root_index: ?u32, // index into pages
pages: std.ArrayListUnmanaged(Page),
/// Output urls for pages, and assets.
/// - Scan phase: adds pages and assets
/// - Main thread after parse phase: adds aliases and alternatives
urls: std.AutoHashMapUnmanaged(PathName, LocationHint),
/// Overflowing LocationHints end up in here, populated alongside 'urls'.
collisions: std.ArrayListUnmanaged(Collision),
taxonomies: Taxonomy.Store = .{},

i18n: context.Map.ZiggyMap,
i18n_src: [:0]const u8,
i18n_diag: ziggy.Diagnostic,
i18n_arena: std.heap.ArenaAllocator.State,

const Collision = struct {
    url: PathName,
    loc: LocationHint,
    previous: LocationHint,
};

/// Tells you where to look when figuring out what an output URL maps to.
pub const ResourceKind = enum {
    page_main,
    page_alias,
    page_alternative,
    page_asset,
    taxonomy_list,
    taxonomy_term,
};
pub const LocationHint = struct {
    id: u32, // index into pages
    kind: union(ResourceKind) {
        page_main,
        page_alias,
        page_alternative: []const u8,
        // for page assets, 'id' is the page that owns the asset
        page_asset: std.atomic.Value(u32), // reference counting
        taxonomy_list,
        taxonomy_term: struct {
            taxonomy: u32,
            term: u32,
        },
    },
    pub fn fmt(
        lh: LocationHint,
        st: *const StringTable,
        pt: *const PathTable,
        pages: []const Page,
    ) LocationHint.Formatter {
        return .{ .lh = lh, .st = st, .pt = pt, .pages = pages };
    }

    pub const Formatter = struct {
        lh: LocationHint,
        st: *const StringTable,
        pt: *const PathTable,
        pages: []const Page,

        pub fn format(f: LocationHint.Formatter, w: *Writer) !void {
            switch (f.lh.kind) {
                .page_main => {
                    const page = f.pages[f.lh.id];
                    try w.print("{f}", .{page._scan.file.fmt(f.st, f.pt, null, "")});
                    try w.writeAll(" (main output)");
                },
                .page_alias => {
                    const page = f.pages[f.lh.id];
                    try w.print("{f}", .{page._scan.file.fmt(f.st, f.pt, null, "")});
                    try w.writeAll(" (page alias)");
                },
                .page_alternative => |alt| {
                    const page = f.pages[f.lh.id];
                    try w.print("{f}", .{page._scan.file.fmt(f.st, f.pt, null, "")});
                    try w.print(" (page alternative '{s}')", .{alt});
                },
                .page_asset => {
                    const page = f.pages[f.lh.id];
                    try w.print("{f}", .{page._scan.file.fmt(f.st, f.pt, null, "")});
                    try w.writeAll(" (page asset)");
                },
                .taxonomy_list => {
                    try w.writeAll("<taxonomy list>");
                },
                .taxonomy_term => |info| {
                    try w.print("<taxonomy term {}:{}>", .{
                        f.lh.id,
                        info.term,
                    });
                },
            }
        }
    };
};

pub const Section = struct {
    active: bool = true,
    content_sub_path: Path,
    parent_section: u32, // index into sections, 0 = no parent section
    index: u32, // index into pages
    pages: std.ArrayListUnmanaged(u32) = .empty, // indices into pages

    pub fn deinit(s: *const Section, gpa: Allocator) void {
        {
            var p = s.pages;
            p.deinit(gpa);
        }
    }

    pub fn activate(
        s: *Section,
        gpa: Allocator,
        variant: *const Variant,
        index: *Page,
        drafts: bool,
    ) void {
        const zone = tracy.trace(@src());
        defer zone.end();

        index.parse(gpa, worker.cmark, null, variant, drafts);
        s.active = index._parse.active;
    }

    pub fn sortPages(
        s: *Section,
        v: *Variant,
        pages: []Page,
    ) void {
        const Ctx = struct {
            v: *Variant,
            pages: []Page,
            pub fn lessThan(ctx: @This(), lhs: u32, rhs: u32) bool {
                if (ctx.pages[rhs].date.eql(ctx.pages[lhs].date)) {
                    var bl: [std.fs.max_path_bytes]u8 = undefined;
                    var br: [std.fs.max_path_bytes]u8 = undefined;
                    return std.mem.order(
                        u8,
                        std.fmt.bufPrint(&bl, "{f}", .{
                            ctx.pages[rhs]._scan.url.fmt(
                                &ctx.v.string_table,
                                &ctx.v.path_table,
                                null,
                                false,
                            ),
                        }) catch unreachable,
                        std.fmt.bufPrint(&br, "{f}", .{
                            ctx.pages[lhs]._scan.url.fmt(
                                &ctx.v.string_table,
                                &ctx.v.path_table,
                                null,
                                false,
                            ),
                        }) catch unreachable,
                    ) == .lt;
                }

                return ctx.pages[rhs].date.lessThan(ctx.pages[lhs].date);
            }
        };

        const ctx: Ctx = .{ .pages = pages, .v = v };
        std.sort.insertion(u32, s.pages.items, ctx, Ctx.lessThan);
    }
};

pub fn deinit(v: *const Variant, gpa: Allocator) void {
    {
        var dir = v.content_dir;
        dir.close();
    }
    // content_dir_path is in cfg_arena
    // gpa.free(v.content_dir_path);
    v.string_table.deinit(gpa);
    v.path_table.deinit(gpa);
    for (v.sections.items[1..]) |s| s.deinit(gpa);
    {
        var s = v.sections;
        s.deinit(gpa);
    }
    for (v.pages.items) |p| p.deinit(gpa);
    {
        var p = v.pages;
        p.deinit(gpa);
    }
    {
        var u = v.urls;
        u.deinit(gpa);
    }
    {
        var c = v.collisions;
        c.deinit(gpa);
    }
    {
        var tx = v.taxonomies;
        tx.deinit(gpa);
    }
    v.i18n_arena.promote(gpa).deinit();
}

pub const MultilingualScanParams = struct {
    i18n_dir: std.fs.Dir,
    i18n_dir_path: []const u8,
    locale_code: []const u8,
};
pub fn scanContentDir(
    variant: *Variant,
    gpa: Allocator,
    arena: Allocator,
    base_dir: std.fs.Dir,
    content_dir_path: []const u8,
    variant_id: u32,
    multilingual: ?MultilingualScanParams,
    output_path_prefix: []const u8,
) void {
    const zone = tracy.trace(@src());
    defer zone.end();

    errdefer |err| switch (err) {
        error.OutOfMemory => fatal.oom(),
    };

    var path_table: PathTable = .empty;
    _ = try path_table.intern(gpa, &.{}); // empty path
    const empty_path = try path_table.intern(gpa, &.{});
    var string_table: StringTable = .empty;
    _ = try string_table.intern(gpa, ""); // invalid path component string
    const index_smd = try string_table.intern(gpa, "index.smd");
    const index_html = try string_table.intern(gpa, "index.html");
    _ = try string_table.intern(gpa, "index.html");

    var pages: std.ArrayListUnmanaged(Page) = .empty;
    var sections: std.ArrayListUnmanaged(Section) = .empty;
    try sections.append(gpa, undefined); // section zero is invalid

    var urls: std.AutoHashMapUnmanaged(PathName, LocationHint) = .empty;
    var collisions: std.ArrayListUnmanaged(Collision) = .empty;

    var dir_stack: std.ArrayListUnmanaged(struct {
        path: []const u8,
        parent_section: u32, // index into sections
        page_assets_owner: u32, // index into pages
    }) = .empty;
    try dir_stack.append(arena, .{
        .path = "",
        .parent_section = 0,
        .page_assets_owner = 0,
    });

    var root_index: ?u32 = null;
    var page_names: std.ArrayListUnmanaged(String) = .empty;
    var asset_names: std.ArrayListUnmanaged(String) = .empty;
    var dir_names: std.ArrayListUnmanaged(String) = .empty;
    const content_dir = base_dir.openDir(content_dir_path, .{
        .iterate = true,
    }) catch |err| fatal.dir(content_dir_path, err);

    while (dir_stack.pop()) |dir_entry| {
        var dir = switch (dir_entry.path.len) {
            0 => content_dir,
            else => content_dir.openDir(dir_entry.path, .{ .iterate = true }) catch |err| {
                fatal.dir(dir_entry.path, err);
            },
        };
        defer if (dir_entry.path.len > 0) dir.close();

        var found_index_smd = false;
        var it = dir.iterateAssumeFirstIteration();
        while (it.next() catch |err| fatal.dir(dir_entry.path, err)) |entry| {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            switch (entry.kind) {
                else => continue,
                .file, .sym_link => {
                    const str = try string_table.intern(gpa, entry.name);
                    if (str == index_html) {
                        @panic("TODO: error reporting for index.html in content section");
                    }
                    if (std.mem.endsWith(u8, entry.name, ".smd")) {
                        if (str == index_smd) {
                            found_index_smd = true;
                            continue;
                        }
                        try page_names.append(arena, str);
                    } else {
                        try asset_names.append(arena, str);
                    }
                },
                .directory => {
                    const str = try string_table.intern(gpa, entry.name);
                    try dir_names.append(arena, str);
                },
            }
        }

        try urls.ensureUnusedCapacity(gpa, @intCast(@intFromBool(found_index_smd) +
            page_names.items.len + asset_names.items.len));

        // TODO: this should be a internPathExtend
        const content_sub_path = switch (dir_entry.path.len) {
            0 => empty_path,
            else => try path_table.internPath(
                gpa,
                &string_table,
                dir_entry.path,
            ),
        };

        // Would be nice to be able to use destructuring...
        var current_section = dir_entry.parent_section;
        const assets_owner_id = if (found_index_smd) blk: {
            const page_id: u32 = @intCast(pages.items.len);
            const is_root_index = dir_entry.path.len == 0;
            if (is_root_index) {
                // root index case
                root_index = page_id;
            } else {
                // Found index.smd: add it to the current section
                // and create a new section to be used for all
                // other files.
                try sections.items[dir_entry.parent_section].pages.append(
                    gpa,
                    page_id,
                );
            }

            current_section = @intCast(sections.items.len);
            try sections.append(gpa, .{
                .content_sub_path = content_sub_path,
                .parent_section = dir_entry.parent_section,
                .index = page_id,
            });

            const index_page = try pages.addOne(gpa);
            index_page._parse.active = false;
            index_page._scan = .{
                .file = .{
                    .path = content_sub_path,
                    .name = index_smd,
                },
                .url = content_sub_path,
                .page_id = page_id,
                .subsection_id = current_section,
                .parent_section_id = dir_entry.parent_section,
                .variant_id = variant_id,
            };
            if (builtin.mode == .Debug) {
                index_page._debug = .{ .stage = .init(.scanned) };
            }

            const pn: PathName = .{ .path = content_sub_path, .name = index_html };
            const lh: LocationHint = .{ .id = page_id, .kind = .page_main };

            const gop = urls.getOrPutAssumeCapacity(pn);
            if (gop.found_existing) {
                try collisions.append(gpa, .{
                    .url = pn,
                    .loc = lh,
                    .previous = gop.value_ptr.*,
                });
            } else {
                gop.value_ptr.* = lh;
            }

            break :blk page_id;
        } else dir_entry.page_assets_owner;

        const section = &sections.items[current_section];
        const section_pages_old_len = section.pages.items.len;
        try section.pages.resize(gpa, section_pages_old_len + page_names.items.len);
        const pages_old_len = pages.items.len;
        try pages.resize(gpa, pages_old_len + page_names.items.len);

        if (builtin.mode == .Debug) {
            const Ctx = struct {
                st: *StringTable,
                pub fn lessThan(ctx: @This(), lhs: String, rhs: String) bool {
                    return std.mem.order(u8, lhs.slice(ctx.st), rhs.slice(ctx.st)) == .lt;
                }
            };

            const ctx: Ctx = .{ .st = &string_table };
            std.mem.sort(String, page_names.items, ctx, Ctx.lessThan);
        }

        for (
            section.pages.items[section_pages_old_len..],
            pages.items[pages_old_len..],
            page_names.items,
            pages_old_len..,
        ) |*sp, *p, f, idx| {
            // If we don't do this here, later on the call to f.slice might
            // return a pointer that gets invalidated when the string table
            // is expanded.
            try string_table.string_bytes.ensureUnusedCapacity(
                gpa,
                f.slice(&string_table).len + 1,
            );
            const page_url = try path_table.internExtend(
                gpa,
                content_sub_path,
                try string_table.intern(
                    gpa,
                    std.fs.path.stem(f.slice(&string_table)), // TODO: extensionless page names?
                ),
            );

            sp.* = @intCast(idx);
            p._parse.active = false;
            p._scan = .{
                .file = .{
                    .path = content_sub_path,
                    .name = f,
                },
                .url = page_url,
                .page_id = @intCast(idx),
                .subsection_id = 0,
                .parent_section_id = current_section,
                .variant_id = variant_id,
            };
            if (builtin.mode == .Debug) {
                p._debug = .{ .stage = .init(.scanned) };
            }

            log.debug("'{s}/{s}' -> [{d}] -> [{d}]", .{
                dir_entry.path,
                f.slice(&string_table),
                page_url,
                page_url.slice(&path_table),
            });

            const pn: PathName = .{ .path = page_url, .name = index_html };
            const lh: LocationHint = .{ .id = @intCast(idx), .kind = .page_main };
            const gop = urls.getOrPutAssumeCapacity(pn);

            if (gop.found_existing) {
                try collisions.append(gpa, .{
                    .url = pn,
                    .loc = lh,
                    .previous = gop.value_ptr.*,
                });
            } else {
                gop.value_ptr.* = lh;
            }
        }

        // assets
        {
            if (dir_entry.path.len == 0 and !found_index_smd) {
                @panic("TODO: top level assets require an index.smd page");
            }

            const lh: LocationHint = .{
                .id = assets_owner_id,
                .kind = .{ .page_asset = .init(0) },
            };

            for (asset_names.items) |a| {
                const pn: PathName = .{ .path = content_sub_path, .name = a };
                const gop = urls.getOrPutAssumeCapacity(pn);
                if (gop.found_existing) {
                    try collisions.append(gpa, .{
                        .url = pn,
                        .loc = lh,
                        .previous = gop.value_ptr.*,
                    });
                } else {
                    gop.value_ptr.* = lh;
                }
            }
        }

        const dir_stack_old_len = dir_stack.items.len;
        try dir_stack.resize(arena, dir_stack_old_len + dir_names.items.len);
        for (dir_stack.items[dir_stack_old_len..], dir_names.items) |*d, f| {
            const dir_path_bytes = try std.fs.path.join(arena, &.{
                dir_entry.path,
                f.slice(&string_table),
            });
            const dir_path = try path_table.internPath(gpa, &string_table, dir_path_bytes);
            const pn: PathName = .{ .path = dir_path, .name = index_html };
            d.* = .{
                .path = dir_path_bytes,
                .parent_section = current_section,
                .page_assets_owner = if (urls.get(pn)) |hint| hint.id else assets_owner_id,
            };
        }

        page_names.clearRetainingCapacity();
        asset_names.clearRetainingCapacity();
        dir_names.clearRetainingCapacity();
    }

    var i18n: context.Map.ZiggyMap = .{};
    var i18n_src: [:0]const u8 = "";
    var i18n_diag: ziggy.Diagnostic = .{ .path = null };
    var i18n_arena = std.heap.ArenaAllocator.init(gpa);
    // Present when in a multilingual site
    if (multilingual) |ml| {
        const name = try std.fmt.allocPrint(
            i18n_arena.allocator(),
            "{s}.ziggy",
            .{ml.locale_code},
        );
        i18n_src = ml.i18n_dir.readFileAllocOptions(
            i18n_arena.allocator(),
            name,
            ziggy.max_size,
            0,
            .@"1",
            0,
        ) catch |err| fatal.file(name, err);

        i18n_diag.path = name;
        i18n = ziggy.parseLeaky(
            context.Map.ZiggyMap,
            i18n_arena.allocator(),
            i18n_src,
            .{ .diagnostic = &i18n_diag },
        ) catch |err| switch (err) {
            error.OpenFrontmatter, error.MissingFrontmatter => unreachable,
            error.Overflow, error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => .{
                // We will detect later that an error happened by looking
                // at the diagnostic struct.
            },
        };
    }

    variant.* = .{
        .output_path_prefix = output_path_prefix,
        .content_dir = content_dir,
        .content_dir_path = content_dir_path,
        .string_table = string_table,
        .path_table = path_table,
        .sections = sections,
        .root_index = root_index,
        .pages = pages,
        .urls = urls,
        .collisions = collisions,
        .taxonomies = .{},
        .i18n = i18n,
        .i18n_src = i18n_src,
        .i18n_diag = i18n_diag,
        .i18n_arena = i18n_arena.state,
    };
}

pub fn collectTaxonomies(
    v: *Variant,
    gpa: Allocator,
    configs: []const *const root.TaxonomyConfig,
) !void {
    v.taxonomies.deinit(gpa);
    v.taxonomies = .{};
    if (configs.len == 0) return;

    const index_html = v.string_table.get("index.html") orelse @panic("missing index.html string");
    const empty_path: Path = @enumFromInt(0);

    try v.taxonomies.entries.ensureTotalCapacity(gpa, configs.len);
    for (configs, 0..) |cfg_ptr, idx| {
        const path_component = try v.string_table.intern(gpa, cfg_ptr.name);
        const taxonomy_dir = try v.path_table.internExtend(gpa, empty_path, path_component);
        const list_path: PathName = .{ .path = taxonomy_dir, .name = index_html };

        const inst = try v.taxonomies.entries.addOne(gpa);
        inst.* = .{
            .id = @intCast(idx),
            .name = cfg_ptr.name,
            .config = cfg_ptr,
            .list_path = list_path,
        };

        const hint: LocationHint = .{
            .id = inst.id,
            .kind = .taxonomy_list,
        };

        const gop = try v.urls.getOrPut(gpa, list_path);
        if (!gop.found_existing) {
            gop.value_ptr.* = hint;
        } else {
            try v.collisions.append(gpa, .{
                .url = list_path,
                .loc = hint,
                .previous = gop.value_ptr.*,
            });
        }
    }

    var name_to_index = std.StringHashMapUnmanaged(u32){};
    defer name_to_index.deinit(gpa);
    try name_to_index.ensureTotalCapacity(
        gpa,
        @intCast(v.taxonomies.entries.items.len),
    );
    for (v.taxonomies.entries.items) |inst| {
        name_to_index.putAssumeCapacityNoClobber(inst.name, inst.id);
    }

    const has_tags_taxonomy = name_to_index.get("tags") != null;

    const PageOrder = struct {
        pages: []const Page,
        variant: *Variant,
        pub fn lessThan(ctx: @This(), lhs: u32, rhs: u32) bool {
            const left = ctx.pages[lhs];
            const right = ctx.pages[rhs];

            if (right.date.eql(left.date)) {
                var bl: [std.fs.max_path_bytes]u8 = undefined;
                var br: [std.fs.max_path_bytes]u8 = undefined;
                const lhs_str = std.fmt.bufPrint(&bl, "{f}", .{
                    left._scan.url.fmt(
                        &ctx.variant.string_table,
                        &ctx.variant.path_table,
                        null,
                        false,
                    ),
                }) catch unreachable;
                const rhs_str = std.fmt.bufPrint(&br, "{f}", .{
                    right._scan.url.fmt(
                        &ctx.variant.string_table,
                        &ctx.variant.path_table,
                        null,
                        false,
                    ),
                }) catch unreachable;
                return std.mem.order(u8, lhs_str, rhs_str) == .lt;
            }

            return right.date.lessThan(left.date);
        }
    };

    const TermOrder = struct {
        st: *const StringTable,
        pub fn lessThan(ctx: @This(), lhs: Taxonomy.Term, rhs: Taxonomy.Term) bool {
            const left = lhs;
            const right = rhs;
            if (left.pages.items.len != right.pages.items.len) {
                return left.pages.items.len > right.pages.items.len;
            }
            return std.mem.order(
                u8,
                left.slug.slice(ctx.st),
                right.slug.slice(ctx.st),
            ) == .lt;
        }
    };

    const AddTerms = struct {
        fn add(
            variant: *Variant,
            allocator: Allocator,
            name_map: *std.StringHashMapUnmanaged(u32),
            taxonomy_store: *Taxonomy.Store,
            name: []const u8,
            terms: []const []const u8,
            page_index: u32,
            index_name: String,
        ) !void {
            const entry_index = name_map.get(name) orelse return;
            const inst = &taxonomy_store.entries.items[entry_index];

            for (terms) |term_name| {
                const slug = Taxonomy.slugify(allocator, &variant.string_table, term_name) catch |err| switch (err) {
                    error.InvalidSlug => continue,
                    else => |e| return e,
                };

                const term_idx = blk: {
                    for (inst.terms.items, 0..) |*existing, idx| {
                        if (existing.slug == slug) break :blk idx;
                    }

                    const term_dir = try variant.path_table.internExtend(allocator, inst.list_path.path, slug);
                    const term_path: PathName = .{ .path = term_dir, .name = index_name };

                    const new_term = try inst.terms.addOne(allocator);
                    new_term.* = .{
                        .name = term_name,
                        .slug = slug,
                        .path = term_path,
                    };

                    const hint: LocationHint = .{
                        .id = inst.id,
                        .kind = .{ .taxonomy_term = .{
                            .taxonomy = inst.id,
                            .term = @intCast(inst.terms.items.len - 1),
                        } },
                    };

                    const gop = try variant.urls.getOrPut(allocator, term_path);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = hint;
                    } else {
                        try variant.collisions.append(allocator, .{
                            .url = term_path,
                            .loc = hint,
                            .previous = gop.value_ptr.*,
                        });
                    }

                    break :blk inst.terms.items.len - 1;
                };

                const term_entry = &inst.terms.items[term_idx];
                if (std.mem.indexOfScalar(u32, term_entry.pages.items, page_index) == null) {
                    try term_entry.pages.append(allocator, page_index);
                }
            }
        }
    };

    for (v.pages.items, 0..) |page, page_idx_usize| {
        const page_index: u32 = @intCast(page_idx_usize);
        if (!page._parse.active) continue;
        if (page._parse.status != .parsed) continue;

        if (has_tags_taxonomy) {
            if (page.tags.len > 0) try AddTerms.add(
                v,
                gpa,
                &name_to_index,
                &v.taxonomies,
                "tags",
                page.tags,
                page_index,
                index_html,
            );
        }

        for (page.taxonomy_assignments) |assignment| {
            try AddTerms.add(
                v,
                gpa,
                &name_to_index,
                &v.taxonomies,
                assignment.name,
                assignment.terms,
                page_index,
                index_html,
            );
        }
    }

    const page_ctx = PageOrder{
        .pages = v.pages.items,
        .variant = v,
    };

    for (v.taxonomies.entries.items) |*inst| {
        const term_ctx = TermOrder{
            .st = &v.string_table,
        };

        for (inst.terms.items) |*term| {
            std.sort.insertion(
                u32,
                term.pages.items,
                page_ctx,
                PageOrder.lessThan,
            );
        }

        std.sort.insertion(
            Taxonomy.Term,
            inst.terms.items,
            term_ctx,
            TermOrder.lessThan,
        );

        for (inst.terms.items, 0..) |term, term_idx| {
            if (v.urls.getPtr(term.path)) |hint_ptr| {
                hint_ptr.* = .{
                    .id = inst.id,
                    .kind = .{ .taxonomy_term = .{
                        .taxonomy = inst.id,
                        .term = @intCast(term_idx),
                    } },
                };
            }
        }
    }
}

pub fn installAssets(
    v: *const Variant,
    progress: std.Progress.Node,
    install_dir: std.fs.Dir,
) void {
    const zone = tracy.trace(@src());
    defer zone.end();

    // errdefer |err| switch (err) {
    //     error.OutOfMemory => fatal.oom(),
    // };

    var it = v.urls.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const hint = entry.value_ptr.*;
        if (hint.kind != .page_asset) continue;
        if (hint.kind.page_asset.raw == 0) continue;

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const install_path = std.fmt.bufPrint(&buf, "{s}{s}{f}", .{
            v.output_path_prefix,
            if (v.output_path_prefix.len > 0) "/" else "",
            key.fmt(
                &v.string_table,
                &v.path_table,
                null,
                "",
            ),
        }) catch unreachable;

        const source_path = if (v.output_path_prefix.len == 0)
            install_path
        else
            install_path[v.output_path_prefix.len + 1 ..];

        _ = v.content_dir.updateFile(
            source_path,
            install_dir,
            std.mem.trimLeft(u8, install_path, "/"),
            .{},
        ) catch |err| fatal.file(install_path, err);

        progress.completeOne();
    }
}
