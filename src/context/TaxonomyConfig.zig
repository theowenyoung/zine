const TaxonomyConfigCtx = @This();

const std = @import("std");
const scripty = @import("scripty");
const context = @import("../context.zig");
const Value = context.Value;
const root = @import("../root.zig");

name: []const u8,
paginate_by: ?usize,
paginate_path: []const u8,
feed: bool,
render: bool,
lang: ?[]const u8,
_cfg: *const root.TaxonomyConfig,

pub fn init(cfg: *const root.TaxonomyConfig) TaxonomyConfigCtx {
    return .{
        .name = cfg.name,
        .paginate_by = cfg.paginate_by,
        .paginate_path = cfg.paginate_path,
        .feed = cfg.feed,
        .render = cfg.render,
        .lang = cfg.lang,
        ._cfg = cfg,
    };
}

pub const dot = scripty.defaultDot(TaxonomyConfigCtx, Value, false);
pub const PassByRef = true;
pub const docs_description =
    \\Configuration for a taxonomy as declared in `zine.ziggy`.
;
pub const Fields = struct {
    pub const name = "Taxonomy name.";
    pub const paginate_by = "Pagination size for term pages.";
    pub const paginate_path = "Path component used for pagination.";
    pub const feed = "Whether feeds should be generated.";
    pub const render = "Whether this taxonomy should render list and term pages.";
    pub const lang = "Optional language code associated with this taxonomy.";
};
pub const Builtins = struct {};
