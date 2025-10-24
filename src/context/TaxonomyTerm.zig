const TaxonomyTermCtx = @This();

const std = @import("std");
const scripty = @import("scripty");
const context = @import("../context.zig");
const Value = context.Value;

name: []const u8,
slug: []const u8,
path: []const u8,
permalink: []const u8,
pages: []const Value,

pub const dot = scripty.defaultDot(TaxonomyTermCtx, Value, false);
pub const PassByRef = true;
pub const docs_description =
    \\A taxonomy term with precomputed links and associated pages.
;
pub const Fields = struct {
    pub const name = "Term display name.";
    pub const slug = "Slugified version of the term.";
    pub const path = "Relative path to this term page.";
    pub const permalink = "Absolute permalink to this term page.";
    pub const pages = "Pages associated with this term.";
};
pub const Builtins = struct {};
