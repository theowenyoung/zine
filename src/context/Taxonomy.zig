const TaxonomyCtx = @This();

const std = @import("std");
const scripty = @import("scripty");
const context = @import("../context.zig");
const Value = context.Value;
const root = @import("../root.zig");
const TaxonomyConfigCtx = @import("TaxonomyConfig.zig");
const TaxonomyTermCtx = @import("TaxonomyTerm.zig");

name: []const u8,
path: []const u8,
permalink: []const u8,
terms: []const TaxonomyTermCtx,
config: TaxonomyConfigCtx,

pub const dot = scripty.defaultDot(TaxonomyCtx, Value, false);
pub const PassByRef = true;
pub const docs_description =
    \\A rendered taxonomy with associated metadata and terms.
;
pub const Fields = struct {
    pub const name = "Taxonomy name.";
    pub const path = "Relative path to the taxonomy list page.";
    pub const permalink = "Absolute permalink to the taxonomy list page.";
    pub const terms = "Terms that belong to this taxonomy.";
    pub const config = "Configuration for this taxonomy.";
};
pub const Builtins = struct {};
