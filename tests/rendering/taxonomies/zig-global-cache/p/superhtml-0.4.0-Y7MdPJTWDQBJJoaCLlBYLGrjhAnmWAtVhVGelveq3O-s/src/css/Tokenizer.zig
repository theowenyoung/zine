const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");
const root = @import("../root.zig");
const Span = root.Span;

idx: u32 = 0,
current: u8 = undefined,

pub const Error = enum {
    truncated_string,
};

pub const Token = union(enum) {
    ident: Span,
    function: Span,
    at_keyword: Span,
    hash: Span,
    string: Span,
    bad_string: Span,
    url: Span,
    bad_url: Span,
    delim: u32,
    number: Span,
    percentage: Span,
    dimension: Dimension,
    cdo: u32,
    cdc: u32,
    colon: u32,
    semicolon: u32,
    comma: u32,
    open_square: u32,
    close_square: u32,
    open_paren: u32,
    close_paren: u32,
    open_curly: u32,
    close_curly: u32,
    err: struct {
        tag: Error,
        span: Span,
    },

    pub const Dimension = struct {
        number: Span,
        unit: Span,
    };

    pub fn span(self: Token) Span {
        return switch (self) {
            .ident,
            .function,
            .at_keyword,
            .hash,
            .string,
            .bad_string,
            .url,
            .bad_url,
            .number,
            .percentage,
            => |s| s,
            .dimension,
            => |d| .{ .start = d.number.start, .end = d.unit.end },
            .cdo,
            => |i| .{ .start = i, .end = i + 4 },
            .cdc,
            => |i| .{ .start = i, .end = i + 3 },
            .delim,
            .colon,
            .semicolon,
            .comma,
            .open_square,
            .close_square,
            .open_paren,
            .close_paren,
            .open_curly,
            .close_curly,
            => |i| .{ .start = i, .end = i + 1 },
            .err,
            => |e| e.span,
        };
    }
};

fn consume(self: *Tokenizer, src: []const u8) bool {
    if (self.idx == src.len) {
        return false;
    }
    self.current = src[self.idx];
    self.idx += 1;
    return true;
}

fn reconsume(self: *Tokenizer, src: []const u8) void {
    self.idx -= 1;
    if (self.idx == 0) {
        self.current = undefined;
    } else {
        self.current = src[self.idx - 1];
    }
}

fn peek(self: *Tokenizer, src: []const u8) ?u8 {
    if (self.idx >= src.len) {
        return null;
    }
    return src[self.idx];
}

// https://www.w3.org/TR/css-syntax-3/#ident-start-code-point
fn isIdentStartChar(char: u8) bool {
    return switch (char) {
        'A'...'Z', 'a'...'z', 0x80...0xff, '_' => true,
        else => false,
    };
}

// https://www.w3.org/TR/css-syntax-3/#ident-code-point
fn isIdentChar(char: u8) bool {
    return switch (char) {
        '0'...'9', '-' => true,
        else => isIdentStartChar(char),
    };
}

// https://www.w3.org/TR/css-syntax-3/#check-if-three-code-points-would-start-an-ident-sequence
fn wouldStartIdent(self: *Tokenizer, src: []const u8) bool {
    const char0 = if (self.idx >= src.len) ' ' else src[self.idx];
    const char1 = if (self.idx + 1 >= src.len) ' ' else src[self.idx + 1];
    const char2 = if (self.idx + 2 >= src.len) ' ' else src[self.idx + 2];

    _ = char2;

    return switch (char0) {
        '-' => isIdentStartChar(char1) or char1 == '-',
        else => isIdentStartChar(char0),
    };
}

// https://www.w3.org/TR/css-syntax-3/#check-if-three-code-points-would-start-a-number
fn wouldStartNumber(self: *Tokenizer, src: []const u8) bool {
    if (self.peek(src)) |first| {
        switch (first) {
            '+', '-' => {
                std.debug.assert(self.consume(src));
                defer self.reconsume(src);

                if (self.peek(src)) |second| {
                    switch (second) {
                        '0'...'9' => return true,
                        '.' => {
                            std.debug.assert(self.consume(src));
                            defer self.reconsume(src);

                            if (self.peek(src)) |third| {
                                switch (third) {
                                    '0'...'9' => return true,
                                    else => {},
                                }
                            }
                        },
                        else => {},
                    }
                }

                return false;
            },
            '.' => {
                std.debug.assert(self.consume(src));
                defer self.reconsume(src);

                return if (self.peek(src)) |second|
                    switch (second) {
                        '0'...'9' => true,
                        else => false,
                    }
                else
                    false;
            },
            '0'...'9' => return true,
            else => return false,
        }
    } else return false;
}

// https://www.w3.org/TR/css-syntax-3/#consume-token
pub fn next(self: *Tokenizer, src: []const u8) ?Token {
    if (self.consume(src)) {
        switch (self.current) {
            '\n', '\t', ' ' => {
                while (true) {
                    if (self.peek(src)) |c| switch (c) {
                        '\n', '\t', ' ' => std.debug.assert(self.consume(src)),
                        else => break,
                    } else break;
                }

                return self.next(src);
            },
            '"', '\'' => return self.string(src),
            '#' => {
                if (self.peek(src) != null and isIdentChar(self.peek(src).?)) {
                    var token = .{ .hash = self.identSequence(src) };
                    token.hash.start -= 1;
                    return token;
                } else {
                    return .{ .delim = self.idx - 1 };
                }
            },
            '(' => return .{ .open_paren = self.idx - 1 },
            ')' => return .{ .close_paren = self.idx - 1 },
            ',' => return .{ .comma = self.idx - 1 },
            '+', '-' => |char| {
                if (self.wouldStartNumber(src)) {
                    self.reconsume(src);
                    return self.numeric(src);
                } else if (char == '-' and self.peek(src) != null) {
                    const first = self.peek(src);
                    std.debug.assert(self.consume(src));

                    if (self.peek(src)) |second| {
                        if (first == '-' and second == '>') {
                            std.debug.assert(self.consume(src));

                            return .{ .cdc = self.idx - 3 };
                        }
                    }

                    self.reconsume(src);
                }

                if (char == '-' and self.wouldStartIdent(src)) {
                    self.reconsume(src);
                    return self.identLike(src);
                } else {
                    return .{ .delim = self.idx - 1 };
                }
            },
            '.' => {
                if (self.wouldStartNumber(src)) {
                    self.reconsume(src);
                    return self.numeric(src);
                }

                return .{ .delim = self.idx - 1 };
            },
            ':' => return .{ .colon = self.idx - 1 },
            ';' => return .{ .semicolon = self.idx - 1 },
            '<' => {
                if (self.idx + 2 < src.len and std.mem.eql(u8, src[self.idx .. self.idx + 3], "!--")) {
                    for (0..3) |_| std.debug.assert(self.consume(src));
                    return .{ .cdo = self.idx - 4 };
                } else {
                    return .{ .delim = self.idx - 1 };
                }
            },
            '@' => {
                if (self.wouldStartIdent(src)) {
                    const name = self.identSequence(src);
                    return .{ .at_keyword = .{ .start = name.start - 1, .end = name.end } };
                } else {
                    return .{ .delim = self.idx - 1 };
                }
            },
            '[' => return .{ .open_square = self.idx - 1 },
            ']' => return .{ .close_square = self.idx - 1 },
            '{' => return .{ .open_curly = self.idx - 1 },
            '}' => return .{ .close_curly = self.idx - 1 },
            '0'...'9' => {
                self.reconsume(src);
                return self.numeric(src);
            },
            else => |c| if (isIdentStartChar(c)) {
                self.reconsume(src);
                return self.identLike(src);
            } else {
                return .{ .delim = self.idx - 1 };
            },
        }
    } else {
        return null;
    }
}

// https://www.w3.org/TR/css-syntax-3/#consume-an-ident-sequence
fn identSequence(self: *Tokenizer, src: []const u8) Span {
    const start = self.idx;

    while (true) {
        if (self.consume(src)) {
            if (!isIdentChar(self.current)) {
                self.reconsume(src);
                break;
            }
        } else break;
    }

    return .{ .start = start, .end = self.idx };
}

// https://www.w3.org/TR/css-syntax-3/#consume-an-ident-like-token
fn identLike(self: *Tokenizer, src: []const u8) Token {
    const span = self.identSequence(src);

    if (std.ascii.eqlIgnoreCase(span.slice(src), "url") and
        self.peek(src) != null and self.peek(src).? == '(')
    {
        @panic("TODO");
    } else if (self.peek(src) != null and self.peek(src).? == '(') {
        std.debug.assert(self.consume(src));
        return .{ .function = .{ .start = span.start, .end = self.idx } };
    } else {
        return .{ .ident = span };
    }
}

// https://www.w3.org/TR/css-syntax-3/#consume-a-numeric-token
fn numeric(self: *Tokenizer, src: []const u8) Token {
    const start = self.idx;

    if (self.peek(src)) |c| {
        if (c == '+' or c == '-') {
            std.debug.assert(self.consume(src));
        }
    }

    while (self.peek(src)) |c| {
        switch (c) {
            '0'...'9' => std.debug.assert(self.consume(src)),
            else => break,
        }
    }

    if (self.peek(src)) |dot| {
        if (dot == '.') {
            std.debug.assert(self.consume(src));
            if (self.peek(src)) |digit| {
                switch (digit) {
                    '0'...'9' => {
                        std.debug.assert(self.consume(src));

                        while (self.peek(src)) |c| {
                            switch (c) {
                                '0'...'9' => std.debug.assert(self.consume(src)),
                                else => break,
                            }
                        }
                    },
                    else => self.reconsume(src),
                }
            } else self.reconsume(src);
        }
    }

    // TODO: Support exponents

    if (self.wouldStartIdent(src)) {
        const num_end = self.idx;

        const unit = self.identSequence(src);

        return .{
            .dimension = .{
                .number = .{ .start = start, .end = num_end },
                .unit = unit,
            },
        };
    } else if (self.peek(src) != null and self.peek(src).? == '%') {
        std.debug.assert(self.consume(src));
        return .{
            .percentage = .{ .start = start, .end = self.idx },
        };
    } else {
        return .{
            .number = .{ .start = start, .end = self.idx },
        };
    }
}

fn string(self: *Tokenizer, src: []const u8) Token {
    const ending = self.current;
    const start = self.idx - 1;

    while (true) {
        if (self.consume(src)) {
            switch (self.current) {
                '\n' => {
                    return .{
                        .err = .{
                            .tag = .truncated_string,
                            .span = .{ .start = start, .end = self.idx - 1 },
                        },
                    };
                },
                else => {
                    if (self.current == ending) {
                        return .{
                            .string = .{ .start = start, .end = self.idx },
                        };
                    }
                },
            }
        } else {
            return .{
                .err = .{
                    .tag = .truncated_string,
                    .span = .{ .start = start, .end = self.idx },
                },
            };
        }
    }
}

test {
    const src =
        \\p {
        \\    color: red;
        \\}
    ;

    var tokenizer = Tokenizer{};

    try std.testing.expectEqual(Token{ .ident = .{ .start = 0, .end = 1 } }, tokenizer.next(src).?);
    try std.testing.expectEqual(Token{ .open_curly = 2 }, tokenizer.next(src).?);
    try std.testing.expectEqual(Token{ .ident = .{ .start = 8, .end = 13 } }, tokenizer.next(src).?);
    try std.testing.expectEqual(Token{ .colon = 13 }, tokenizer.next(src).?);
    try std.testing.expectEqual(Token{ .ident = .{ .start = 15, .end = 18 } }, tokenizer.next(src).?);
    try std.testing.expectEqual(Token{ .semicolon = 18 }, tokenizer.next(src).?);
    try std.testing.expectEqual(Token{ .close_curly = 20 }, tokenizer.next(src).?);
    try std.testing.expectEqual(null, tokenizer.next(src));
}
