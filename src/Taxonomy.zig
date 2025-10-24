const std = @import("std");
const root = @import("root.zig");
const StringTable = @import("StringTable.zig");
const PathTable = @import("PathTable.zig");

pub const Store = struct {
    entries: std.ArrayListUnmanaged(Instance) = .{},

    pub fn deinit(store: *Store, gpa: std.mem.Allocator) void {
        for (store.entries.items) |*inst| inst.deinit(gpa);
        store.entries.deinit(gpa);
    }
};

pub const Instance = struct {
    id: u32,
    name: []const u8,
    config: *const root.TaxonomyConfig,
    list_path: PathTable.PathName,
    terms: std.ArrayListUnmanaged(Term) = .{},
    rendered_list: []const u8 = "",

    pub fn deinit(inst: *Instance, gpa: std.mem.Allocator) void {
        if (inst.rendered_list.len > 0) gpa.free(inst.rendered_list);
        for (inst.terms.items) |*term| term.deinit(gpa);
        inst.terms.deinit(gpa);
    }
};

pub const Term = struct {
    name: []const u8,
    slug: StringTable.String,
    path: PathTable.PathName,
    pages: std.ArrayListUnmanaged(u32) = .{},
    rendered: []const u8 = "",

    pub fn deinit(term: *Term, gpa: std.mem.Allocator) void {
        if (term.rendered.len > 0) gpa.free(term.rendered);
        term.pages.deinit(gpa);
    }
};

pub fn slugify(
    gpa: std.mem.Allocator,
    st: *StringTable,
    value: []const u8,
) !StringTable.String {
    var buffer = try std.ArrayList(u8).initCapacity(gpa, 0);
    defer buffer.deinit(gpa);

    var last_dash = false;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try buffer.append(gpa, std.ascii.toLower(c));
            last_dash = false;
            continue;
        }

        if (c == ' ' or c == '_' or c == '-' or c == '.') {
            if (!last_dash and buffer.items.len > 0) {
                try buffer.append(gpa, '-');
                last_dash = true;
            }
            continue;
        }
    }

    while (buffer.items.len > 0 and buffer.items[buffer.items.len - 1] == '-') {
        _ = buffer.pop();
    }

    if (buffer.items.len == 0) return error.InvalidSlug;

    return try st.intern(gpa, buffer.items);
}
