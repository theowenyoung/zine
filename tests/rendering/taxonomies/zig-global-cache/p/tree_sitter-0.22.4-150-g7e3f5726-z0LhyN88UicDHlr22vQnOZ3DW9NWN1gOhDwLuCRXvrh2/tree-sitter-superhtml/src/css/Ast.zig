const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");
const root = @import("../root.zig");
const Span = root.Span;

const Ast = @This();

const at_rules = &.{
    .{ .name = "media", .func = parseMediaRule },
};

pub const Rule = struct {
    type: union(enum) {
        style: Style,
        media: Media,
    },
    next: ?u32,

    pub const Style = struct {
        selectors: Span,
        declarations: Span,
        multiline_decl: bool,

        pub const Selector = union(enum) {
            simple: Simple,

            pub const Simple = struct {
                element_name: ?ElementName,
                specifiers: Span,

                pub const ElementName = union(enum) {
                    name: Span,
                    all,
                };

                pub const Specifier = union(enum) {
                    hash: Span,
                    class: Span,
                    attrib, // TODO
                    pseudo_class: Span,
                    pseudo_element: Span,
                };

                pub fn render(self: Simple, ast: Ast, src: []const u8, out_stream: anytype) !void {
                    if (self.element_name) |element_name| {
                        switch (element_name) {
                            .name => |name| _ = try out_stream.write(name.slice(src)),
                            .all => _ = try out_stream.write("*"),
                        }
                    }

                    for (ast.specifiers[self.specifiers.start..self.specifiers.end]) |specifier| {
                        switch (specifier) {
                            .hash => |hash| try out_stream.print("#{s}", .{hash.slice(src)}),
                            .class => |class| try out_stream.print(".{s}", .{class.slice(src)}),
                            .attrib => @panic("TODO"),
                            .pseudo_class => |pseudo_class| try out_stream.print(":{s}", .{pseudo_class.slice(src)}),
                            .pseudo_element => |pseudo_element| try out_stream.print("::{s}", .{pseudo_element.slice(src)}),
                        }
                    }
                }
            };

            pub fn render(self: Selector, ast: Ast, src: []const u8, out_stream: anytype) !void {
                switch (self) {
                    inline else => |sel| try sel.render(ast, src, out_stream),
                }
            }
        };

        pub const Declaration = struct {
            property: Span,
            value: Span,

            pub fn render(self: Declaration, src: []const u8, out_stream: anytype) !void {
                _ = try out_stream.write(self.property.slice(src));
                _ = try out_stream.write(": ");
                try renderValue(self.value.slice(src), out_stream);
            }
        };

        pub fn render(self: Style, ast: Ast, src: []const u8, out_stream: anytype, depth: usize) !void {
            for (0..depth) |_| _ = try out_stream.write("    ");
            for (ast.selectors[self.selectors.start..self.selectors.end], 0..) |selector, i| {
                if (i != 0) {
                    _ = try out_stream.write(", ");
                }

                try selector.render(ast, src, out_stream);
            }

            _ = try out_stream.write(" {");

            if (self.multiline_decl) {
                _ = try out_stream.write("\n");

                for (ast.declarations[self.declarations.start..self.declarations.end]) |declaration| {
                    for (0..depth + 1) |_| _ = try out_stream.write("    ");
                    try declaration.render(src, out_stream);
                    _ = try out_stream.write(";\n");
                }

                for (0..depth) |_| _ = try out_stream.write("    ");
            } else {
                _ = try out_stream.write(" ");
                for (ast.declarations[self.declarations.start..self.declarations.end], 0..) |declaration, i| {
                    if (i != 0) _ = try out_stream.write("; ");
                    try declaration.render(src, out_stream);
                }
                _ = try out_stream.write(" ");
            }

            _ = try out_stream.write("}");
        }
    };

    pub const Media = struct {
        queries: Span,
        first_rule: ?u32,

        fn renderMediaQuery(query: []const u8, out_stream: anytype) !void {
            var query_tokenizer: Tokenizer = .{};

            while (query_tokenizer.next(query)) |token| {
                switch (token) {
                    .ident => |ident| _ = try out_stream.write(ident.slice(query)),
                    .open_paren => {
                        _ = try out_stream.write("(");
                        _ = try out_stream.write(query_tokenizer.next(query).?.ident.slice(query));
                        switch (query_tokenizer.next(query).?) {
                            .colon => {
                                _ = try out_stream.write(": ");

                                var span: ?Span = null;
                                while (true) {
                                    const t = query_tokenizer.next(query).?;
                                    if (t == .close_paren) break;

                                    if (span == null) {
                                        span = t.span();
                                    } else {
                                        span.?.end = t.span().end;
                                    }
                                }

                                std.debug.assert(span != null);

                                try renderValue(span.?.slice(query), out_stream);
                            },
                            .close_paren => {},
                            else => unreachable,
                        }
                        _ = try out_stream.write(")");
                    },
                    else => unreachable,
                }
            }
        }

        pub fn render(self: Media, ast: Ast, src: []const u8, out_stream: anytype, depth: usize) !void {
            for (0..depth) |_| _ = try out_stream.write("    ");

            _ = try out_stream.write("@media ");

            for (ast.media_queries[self.queries.start..self.queries.end], 0..) |query, i| {
                if (i != 0) {
                    _ = try out_stream.write(", ");
                }

                try renderMediaQuery(query.slice(src), out_stream);
            }

            _ = try out_stream.write(" {");

            if (self.first_rule) |first_rule| {
                _ = try out_stream.write("\n");

                var first = true;
                var rule = ast.rules[first_rule];
                while (true) {
                    if (!first) {
                        _ = try out_stream.write("\n\n");
                    }
                    first = false;

                    try rule.render(ast, src, out_stream, depth + 1);

                    rule = ast.rules[rule.next orelse break];
                }
                _ = try out_stream.write("\n");
            }

            for (0..depth) |_| _ = try out_stream.write("    ");
            _ = try out_stream.write("}");
        }
    };

    pub fn render(self: Rule, ast: Ast, src: []const u8, out_stream: anytype, depth: usize) anyerror!void {
        switch (self.type) {
            .style => |style| try style.render(ast, src, out_stream, depth),
            .media => |media| try media.render(ast, src, out_stream, depth),
        }
    }
};

pub const Error = struct {
    tag: Tag,
    loc: Span,

    pub const Tag = enum {
        invalid_at_rule,
        expected_open_curly,
        expected_close_curly,
        expected_media_query,
    };
};

errors: []const Error,
first_rule: ?u32,
rules: []const Rule,
selectors: []const Rule.Style.Selector,
declarations: []const Rule.Style.Declaration,
specifiers: []const Rule.Style.Selector.Simple.Specifier,
media_queries: []const Span,

const State = struct {
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    src: []const u8,
    reconsumed: ?Tokenizer.Token,
    errors: std.ArrayListUnmanaged(Error),
    rules: std.ArrayListUnmanaged(Rule),
    selectors: std.ArrayListUnmanaged(Rule.Style.Selector),
    declarations: std.ArrayListUnmanaged(Rule.Style.Declaration),
    specifiers: std.ArrayListUnmanaged(Rule.Style.Selector.Simple.Specifier),
    media_queries: std.ArrayListUnmanaged(Span),

    fn consume(self: *State) ?Tokenizer.Token {
        if (self.reconsumed) |tok| {
            self.reconsumed = null;
            return tok;
        }

        return self.tokenizer.next(self.src);
    }

    fn reconsume(self: *State, token: Tokenizer.Token) void {
        std.debug.assert(self.reconsumed == null);

        self.reconsumed = token;
    }

    fn peek(self: *State) ?Tokenizer.Token {
        const token = self.consume();
        if (token) |tok| self.reconsume(tok);

        return token;
    }
};

const Formatter = struct {
    ast: Ast,
    src: []const u8,

    pub fn format(
        f: Formatter,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try f.ast.render(f.src, out_stream);
    }
};

pub fn formatter(self: Ast, src: []const u8) Formatter {
    return .{
        .ast = self,
        .src = src,
    };
}

pub fn render(self: Ast, src: []const u8, out_stream: anytype) !void {
    var first = true;
    var rule = self.rules[self.first_rule orelse return];
    while (true) {
        if (!first) {
            _ = try out_stream.write("\n\n");
        }
        first = false;

        try rule.render(self, src, out_stream, 0);

        rule = self.rules[rule.next orelse break];
    }
}

fn renderValue(value: []const u8, out_stream: anytype) !void {
    var value_tokenizer: Tokenizer = .{};

    var last_token: ?Tokenizer.Token = null;
    while (value_tokenizer.next(value)) |token| : (last_token = token) {
        if (switch (token) {
            .comma, .close_paren => false,
            else => true,
        } and if (last_token) |last| switch (last) {
            .function => false,
            else => true,
        } else false) {
            _ = try out_stream.write(" ");
        }
        _ = try out_stream.write(token.span().slice(value));
    }
}

pub fn init(allocator: std.mem.Allocator, src: []const u8) error{OutOfMemory}!Ast {
    if (src.len > std.math.maxInt(u32)) @panic("too long");

    var state: State = .{
        .allocator = allocator,
        .tokenizer = .{},
        .src = src,
        .reconsumed = null,
        .errors = .{},
        .rules = .{},
        .selectors = .{},
        .declarations = .{},
        .specifiers = .{},
        .media_queries = .{},
    };

    const first_rule = try parseRules(&state);

    if (state.consume()) |_| {
        @panic("TODO");
    }

    return .{
        .errors = try state.errors.toOwnedSlice(allocator),
        .first_rule = first_rule,
        .rules = try state.rules.toOwnedSlice(allocator),
        .selectors = try state.selectors.toOwnedSlice(allocator),
        .declarations = try state.declarations.toOwnedSlice(allocator),
        .specifiers = try state.specifiers.toOwnedSlice(allocator),
        .media_queries = try state.media_queries.toOwnedSlice(allocator),
    };
}

fn parseRules(s: *State) error{OutOfMemory}!?u32 {
    var last_rule: ?u32 = null;
    var first_rule: ?u32 = null;

    while (true) {
        if (s.consume()) |token| {
            switch (token) {
                .close_curly => {
                    s.reconsume(token);
                    break;
                },
                .cdo => @panic("TODO"),
                .cdc => @panic("TODO"),
                .at_keyword => |at_keyword| {
                    const name = at_keyword.slice(s.src)[1..];

                    match: {
                        inline for (at_rules) |at_rule| {
                            if (std.ascii.eqlIgnoreCase(name, at_rule.name)) {
                                s.reconsume(token);

                                const rule = .{
                                    .type = @unionInit(
                                        @TypeOf(@as(Rule, undefined).type),
                                        at_rule.name,
                                        try at_rule.func(s),
                                    ),
                                    .next = null,
                                };

                                try s.rules.append(s.allocator, rule);

                                if (first_rule == null) first_rule = @intCast(s.rules.items.len - 1);

                                if (last_rule) |idx| {
                                    s.rules.items[idx].next = @intCast(s.rules.items.len - 1);
                                }

                                last_rule = @intCast(s.rules.items.len - 1);

                                break :match;
                            }
                        }

                        try s.errors.append(s.allocator, .{
                            .tag = .invalid_at_rule,
                            .loc = at_keyword,
                        });

                        // Do our best to skip the invalid rule
                        var curly_depth: usize = 0;
                        var past_block = false;
                        while (true) {
                            if (curly_depth == 0 and past_block) break;

                            if (s.consume()) |t| {
                                switch (t) {
                                    .semicolon => {
                                        if (curly_depth == 0) {
                                            break;
                                        }
                                    },
                                    .open_curly => {
                                        curly_depth += 1;
                                        past_block = true;
                                    },
                                    .close_curly => {
                                        if (curly_depth > 0) {
                                            curly_depth -= 1;
                                        }
                                    },
                                    else => {},
                                }
                            } else break;
                        }
                    }
                },
                else => {
                    s.reconsume(token);

                    const rule = .{
                        .type = .{
                            .style = try parseStyleRule(s),
                        },
                        .next = null,
                    };

                    try s.rules.append(s.allocator, rule);

                    if (first_rule == null) first_rule = @intCast(s.rules.items.len - 1);

                    if (last_rule) |idx| {
                        s.rules.items[idx].next = @intCast(s.rules.items.len - 1);
                    }

                    last_rule = @intCast(s.rules.items.len - 1);
                },
            }
        } else break;
    }

    return first_rule;
}

fn parseMediaRule(s: *State) !Rule.Media {
    const keyword = s.consume();
    std.debug.assert(keyword != null);
    std.debug.assert(keyword.? == .at_keyword);
    std.debug.assert(std.ascii.eqlIgnoreCase(keyword.?.at_keyword.slice(s.src), "@media"));

    var first_query: ?u32 = null;
    var current_query: ?Span = null;
    var paren_depth: usize = 0;
    while (true) {
        if (s.consume()) |token| {
            if ((token == .comma or token == .open_curly) and paren_depth == 0) {
                if (current_query) |q| {
                    try s.media_queries.append(s.allocator, q);

                    if (first_query == null) {
                        first_query = @intCast(s.media_queries.items.len - 1);
                    }
                } else {
                    try s.errors.append(s.allocator, .{
                        .tag = .expected_media_query,
                        .loc = token.span(),
                    });
                }

                switch (token) {
                    .comma => current_query = null,
                    .open_curly => break,
                    else => unreachable,
                }
            } else {
                if (token == .open_paren or token == .function) paren_depth += 1;
                if (token == .close_paren and paren_depth > 0) paren_depth -= 1;

                if (current_query == null) {
                    current_query = token.span();
                } else {
                    current_query.?.end = token.span().end;
                }
            }
        } else {
            @panic("TODO");
        }
    }

    const first_rule = try parseRules(s);

    if (s.consume()) |token| {
        switch (token) {
            .close_curly => {},
            else => {
                try s.errors.append(s.allocator, .{
                    .tag = .expected_close_curly,
                    .loc = token.span(),
                });
            },
        }
    } else {
        @panic("TODO");
    }

    return .{
        .queries = .{
            .start = first_query orelse @panic("TODO"),
            .end = @intCast(s.media_queries.items.len),
        },
        .first_rule = first_rule,
    };
}

fn parseStyleRule(s: *State) !Rule.Style {
    try s.selectors.append(s.allocator, try parseSelector(s));
    const sel_start = s.selectors.items.len - 1;

    while (true) {
        if (s.consume()) |token| {
            if (token == .comma) {
                if (s.peek() != null and s.peek().? == .open_curly) break;

                try s.selectors.append(s.allocator, try parseSelector(s));
            } else {
                s.reconsume(token);
                break;
            }
        } else {
            break;
        }
    }

    if (s.consume()) |token| {
        switch (token) {
            .open_curly => {},
            else => {
                try s.errors.append(s.allocator, .{
                    .tag = .expected_open_curly,
                    .loc = token.span(),
                });
            },
        }
    } else {
        @panic("TODO");
    }

    try s.declarations.append(s.allocator, parseDeclaration(s));
    const decl_start = s.declarations.items.len - 1;

    var multiline_decl = false;

    while (true) {
        if (s.consume()) |token| {
            if (token == .semicolon) {
                if (s.peek() != null and s.peek().? == .close_curly) {
                    multiline_decl = true;
                    break;
                }

                try s.declarations.append(s.allocator, parseDeclaration(s));
            } else {
                s.reconsume(token);
                break;
            }
        } else {
            break;
        }
    }

    if (s.consume()) |token| {
        switch (token) {
            .close_curly => {},
            else => {
                try s.errors.append(s.allocator, .{
                    .tag = .expected_close_curly,
                    .loc = token.span(),
                });
            },
        }
    } else {
        @panic("TODO");
    }

    return .{
        .selectors = .{ .start = @intCast(sel_start), .end = @intCast(s.selectors.items.len) },
        .declarations = .{ .start = @intCast(decl_start), .end = @intCast(s.declarations.items.len) },
        .multiline_decl = multiline_decl,
    };
}

fn parseSelector(s: *State) !Rule.Style.Selector {
    // TODO: Support other selectors

    return .{
        .simple = try parseSimpleSelector(s),
    };
}

fn parseDeclaration(s: *State) Rule.Style.Declaration {
    const property = if (s.consume()) |token| switch (token) {
        .ident => |ident| ident,
        else => @panic("TODO"),
    } else @panic("TODO");

    if (s.consume()) |token| {
        switch (token) {
            .colon => {},
            else => @panic("TODO"),
        }
    } else {
        @panic("TODO");
    }

    return .{
        .property = property,
        .value = parseDeclarationValue(s),
    };
}

fn parseSimpleSelector(s: *State) !Rule.Style.Selector.Simple {
    var element_name: ?Rule.Style.Selector.Simple.ElementName = null;

    const spec_start = s.specifiers.items.len;

    if (s.consume()) |token| {
        switch (token) {
            .ident => |ident| element_name = .{ .name = ident },
            .delim => |delim| switch (s.src[delim]) {
                '*' => element_name = .all,
                else => s.reconsume(token),
            },
            else => s.reconsume(token),
        }
    }

    while (true) {
        if (s.consume()) |token| {
            switch (token) {
                .hash => |hash| {
                    var span = hash;
                    span.start += 1;
                    try s.specifiers.append(s.allocator, .{ .hash = span });
                },
                .delim => |delim| switch (s.src[delim]) {
                    '.' => {
                        const name_token = s.consume() orelse @panic("TODO");
                        if (name_token != .ident) @panic("TODO");
                        const name = name_token.ident;

                        try s.specifiers.append(s.allocator, .{ .class = name });
                    },
                    else => @panic("TODO"),
                },
                .open_square => @panic("TODO"),
                .colon => {
                    if (s.consume()) |t| {
                        switch (t) {
                            .ident => |ident| {
                                try s.specifiers.append(s.allocator, .{ .pseudo_class = ident });
                            },
                            .function => @panic("TODO"),
                            .colon => {
                                if (s.consume()) |name_tok| {
                                    switch (name_tok) {
                                        .ident => |ident| {
                                            try s.specifiers.append(s.allocator, .{ .pseudo_element = ident });
                                        },
                                        else => @panic("TODO"),
                                    }
                                } else {
                                    @panic("TODO");
                                }
                            },
                            else => @panic("TODO"),
                        }
                    } else {
                        @panic("TODO");
                    }
                },
                else => {
                    s.reconsume(token);
                    break;
                },
            }
        } else {
            break;
        }
    }

    const spec_end = s.specifiers.items.len;

    if (element_name == null and spec_start == spec_end) {
        @panic("TODO");
    }

    return .{
        .element_name = element_name,
        .specifiers = .{ .start = @intCast(spec_start), .end = @intCast(spec_end) },
    };
}

fn parseDeclarationValue(s: *State) Span {
    var start: ?u32 = null;
    var end: u32 = undefined;

    while (s.peek()) |token| {
        switch (token) {
            .semicolon, .close_curly => break,
            else => {
                std.debug.assert(s.consume() != null);
                if (start == null) {
                    start = token.span().start;
                }
                end = token.span().end;
            },
        }
    }

    if (start == null) {
        @panic("TODO");
    } else {
        return .{ .start = start.?, .end = end };
    }
}

pub fn deinit(self: Ast, allocator: std.mem.Allocator) void {
    allocator.free(self.errors);
    allocator.free(self.rules);
    allocator.free(self.selectors);
    allocator.free(self.declarations);
    allocator.free(self.specifiers);
    allocator.free(self.media_queries);
}

test "simple stylesheet" {
    const src =
        \\   p {
        \\color
        \\ : red
        \\   ;}
    ;

    const expected =
        \\p {
        \\    color: red;
        \\}
    ;

    const ast = try Ast.init(std.testing.allocator, src);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expect(ast.errors.len == 0);
    try std.testing.expectFmt(expected, "{s}", .{ast.formatter(src)});
}

test "empty" {
    const ast = try Ast.init(std.testing.allocator, "");
    defer ast.deinit(std.testing.allocator);

    try std.testing.expect(ast.errors.len == 0);
    try std.testing.expectFmt("", "{s}", .{ast.formatter("")});
}

test "full example" {
    const src =
        \\div.foo, #bar {
        \\    display: block;
        \\    padding: 4px 2px;
        \\}
        \\
        \\* { color: #fff }
        \\
        \\@media foo, bar, baz {
        \\    p {
        \\        display: none;
        \\    }
        \\}
    ;

    const ast = try Ast.init(std.testing.allocator, src);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expect(ast.errors.len == 0);
    try std.testing.expectFmt(src, "{s}", .{ast.formatter(src)});
}

test "example.org" {
    const src =
        \\body {
        \\    background-color: #f0f0f2;
        \\    margin: 0;
        \\    padding: 0;
        \\    font-family: -apple-system, system-ui, BlinkMacSystemFont, "Segoe UI", "Open Sans", "Helvetica Neue", Helvetica, Arial, sans-serif;
        \\}
        \\
        \\div {
        \\    width: 600px;
        \\    margin: 5em auto;
        \\    padding: 2em;
        \\    background-color: #fdfdff;
        \\    border-radius: 0.5em;
        \\    box-shadow: 2px 3px 7px 2px rgba(0, 0, 0, 0.02);
        \\}
        \\
        \\a:link, a:visited {
        \\    color: #38488f;
        \\    text-decoration: none;
        \\}
        \\
        \\@media (max-width: 700px) {
        \\    div {
        \\        margin: 0 auto;
        \\        width: auto;
        \\    }
        \\}
    ;

    const ast = try Ast.init(std.testing.allocator, src);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expect(ast.errors.len == 0);
    try std.testing.expectFmt(src, "{s}", .{ast.formatter(src)});
}

test "minimized example.org" {
    const src =
        \\body{background-color:#f0f0f2;margin:0;padding:0;font-family:-apple-system,system-ui,BlinkMacSystemFont,"Segoe UI","Open Sans","Helvetica Neue",Helvetica,Arial,sans-serif;}div{width:600px;margin:5em auto;padding:2em;background-color:#fdfdff;border-radius:0.5em;box-shadow:2px 3px 7px 2px rgba(0,0,0,0.02);}a:link,a:visited{color:#38488f;text-decoration:none;}@media(max-width:700px){div{margin:0 auto;width:auto;}}
    ;
    const expected =
        \\body {
        \\    background-color: #f0f0f2;
        \\    margin: 0;
        \\    padding: 0;
        \\    font-family: -apple-system, system-ui, BlinkMacSystemFont, "Segoe UI", "Open Sans", "Helvetica Neue", Helvetica, Arial, sans-serif;
        \\}
        \\
        \\div {
        \\    width: 600px;
        \\    margin: 5em auto;
        \\    padding: 2em;
        \\    background-color: #fdfdff;
        \\    border-radius: 0.5em;
        \\    box-shadow: 2px 3px 7px 2px rgba(0, 0, 0, 0.02);
        \\}
        \\
        \\a:link, a:visited {
        \\    color: #38488f;
        \\    text-decoration: none;
        \\}
        \\
        \\@media (max-width: 700px) {
        \\    div {
        \\        margin: 0 auto;
        \\        width: auto;
        \\    }
        \\}
    ;

    const ast = try Ast.init(std.testing.allocator, src);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expect(ast.errors.len == 0);
    try std.testing.expectFmt(expected, "{s}", .{ast.formatter(src)});
}

test "media queries" {
    const src =
        \\@media foo, (something: a, b, c), bar {
        \\    p {
        \\        display: none;
        \\    }
        \\}
        \\
        \\@media foo {
        \\    .red {
        \\        color: red;
        \\    }
        \\
        \\    .blue {
        \\        color: blue;
        \\    }
        \\}
        \\
        \\@media foo {}
    ;

    const ast = try Ast.init(std.testing.allocator, src);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expect(ast.errors.len == 0);
    try std.testing.expectFmt(src, "{s}", .{ast.formatter(src)});
}

test "invalid at rule" {
    const src =
        \\@hello foo {
        \\    .red {
        \\        color: red;
        \\    }
        \\
        \\    .blue {
        \\        color: blue;
        \\    }
        \\}
        \\
        \\@foo bar;
        \\
        \\.green {
        \\    color: green;
        \\}
    ;

    const ast = try Ast.init(std.testing.allocator, src);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(&[_]Error{
        .{
            .tag = .invalid_at_rule,
            .loc = .{ .start = 0, .end = 6 },
        },
        .{
            .tag = .invalid_at_rule,
            .loc = .{ .start = 93, .end = 97 },
        },
    }, ast.errors);
}

test "pseudo-classes and pseudo-elements" {
    const src =
        \\a:hover::after {
        \\    content: "Hello";
        \\}
    ;

    const ast = try Ast.init(std.testing.allocator, src);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expect(ast.errors.len == 0);
    try std.testing.expectFmt(src, "{s}", .{ast.formatter(src)});
}
