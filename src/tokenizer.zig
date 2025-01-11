const std = @import("std");

pub const Tokenizer = struct {
    buf: []u8,
    offset: u32,

    pub fn init(buf: []u8) !Tokenizer {
        return Tokenizer{ .buf = buf, .offset = 0 };
    }

    pub fn next(self: *Tokenizer) ?Token {
        defer self.offset += 1;
        self.skip_whitespace();

        if (self.offset >= self.buf.len) return null;

        const c = self.buf[self.offset];

        if (c == ';') return Token{ .SEMICOLON = void{} };
        if (c == '(') return Token{ .LPAREN = void{} };
        if (c == ')') return Token{ .RPAREN = void{} };
        if (c == '=') return Token{ .EQUALS = void{} };

        const string = self.consume_string();
        self.offset -= 1;

        if (std.mem.eql(u8, string, "let")) return Token{ .LET = void{} };
        if (std.mem.eql(u8, string, "print")) return Token{ .PRINT = void{} };

        if (std.fmt.parseInt(i32, string, 10) catch null) |i| return Token{ .NUMBER = i };

        return Token{ .IDENTIFIER = string };
    }

    fn skip_whitespace(self: *Tokenizer) void {
        while (true) {
            if (self.offset >= self.buf.len) return;
            const c = self.buf[self.offset];
            if (!std.ascii.isWhitespace(c)) return;
            self.offset += 1;
        }
    }

    fn consume_string(self: *Tokenizer) []u8 {
        const start = self.offset;
        while (true) {
            if (self.offset >= self.buf.len) return self.buf[start..self.offset];

            const c = self.buf[self.offset];

            if (!std.ascii.isAlphanumeric(c)) return self.buf[start..self.offset];

            self.offset += 1;
        }
    }
};

pub const TokenType = enum {
    // Keywords
    LET,
    PRINT,

    // Identifiers
    IDENTIFIER,

    // Literals
    NUMBER,

    // Operators
    EQUALS,

    // Punctuation
    SEMICOLON,
    LPAREN,
    RPAREN,
};

pub const Token = union(TokenType) {
    LET: void,
    PRINT: void,
    IDENTIFIER: []u8,
    NUMBER: i64,
    EQUALS: void,
    SEMICOLON: void,
    LPAREN: void,
    RPAREN: void,
};

test "simple" {
    // TODO: Add invalid src test
    const tests = [_]struct {
        buf: []u8,
        tokens: []const Token,
    }{
        .{
            .buf = @constCast(
                \\ let i = 2;
                \\
                \\ print(i);
            ),
            .tokens = &[_]Token{
                Token{ .LET = {} },
                Token{ .IDENTIFIER = @constCast("i") },
                Token{ .EQUALS = {} },
                Token{ .NUMBER = 2 },
                Token{ .SEMICOLON = {} },
                Token{ .PRINT = {} },
                Token{ .LPAREN = {} },
                Token{ .IDENTIFIER = @constCast("i") },
                Token{ .RPAREN = {} },
                Token{ .SEMICOLON = {} },
            },
        },
        .{
            .buf = @constCast(
                \\
                \\ let hello
            ),
            .tokens = &[_]Token{
                Token{ .LET = {} },
                Token{ .IDENTIFIER = @constCast("hello") },
            },
        },
    };

    for (tests) |t| {
        var token_list = std.ArrayList(Token).init(std.testing.allocator);
        defer token_list.deinit();

        var tokenizer = try Tokenizer.init(t.buf);
        while (tokenizer.next()) |token| {
            try token_list.append(token);
        }
        try std.testing.expectEqualDeep(t.tokens, token_list.items);
    }
}
