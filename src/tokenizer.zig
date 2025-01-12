const std = @import("std");

const TokenizerError = error{
    TokenizingError,
};

pub const TokenType = enum {
    // Keywords
    LET,
    PRINT,
    RETURN,
    ARROW,

    // Identifiers
    IDENTIFIER,

    // Literals
    NUMBER,

    // Operators
    EQUALS,
    PLUS,

    // Punctuation
    SEMICOLON,
    LPAREN,
    RPAREN,
    LBRACE,
    RBRACE,
};

pub const Token = union(TokenType) {
    LET: void,
    PRINT: void,
    RETURN: void,
    ARROW: void,
    IDENTIFIER: []u8,
    NUMBER: i64,
    EQUALS: void,
    PLUS: void,
    SEMICOLON: void,
    LPAREN: void,
    RPAREN: void,
    LBRACE: void,
    RBRACE: void,
};

pub const Tokenizer = struct {
    buf: []u8,
    offset: u64,

    pub fn init(buf: []u8) !Tokenizer {
        return Tokenizer{ .buf = buf, .offset = 0 };
    }

    pub fn next(self: *Tokenizer) TokenizerError!?Token {
        defer self.offset += 1;
        self.skip_whitespace();

        if (self.offset >= self.buf.len) return null;

        const c = self.buf[self.offset];

        if (self.accept_substr("=>")) return Token{ .ARROW = void{} };
        if (c == ';') return Token{ .SEMICOLON = void{} };
        if (c == '(') return Token{ .LPAREN = void{} };
        if (c == ')') return Token{ .RPAREN = void{} };
        if (c == '{') return Token{ .LBRACE = void{} };
        if (c == '}') return Token{ .RBRACE = void{} };
        if (c == '=') return Token{ .EQUALS = void{} };
        if (c == '+') return Token{ .PLUS = void{} };

        const string = self.consume_string();
        if (string.len == 0) return TokenizerError.TokenizingError;

        if (std.mem.eql(u8, string, "let")) return Token{ .LET = void{} };
        if (std.mem.eql(u8, string, "print")) return Token{ .PRINT = void{} };
        if (std.mem.eql(u8, string, "return")) return Token{ .RETURN = void{} };

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
        defer self.offset = if (self.offset > 0) self.offset - 1 else self.offset;
        const start = self.offset;
        while (true) {
            if (self.offset >= self.buf.len) return self.buf[start..self.offset];

            const c = self.buf[self.offset];

            if (!std.ascii.isAlphanumeric(c)) return self.buf[start..self.offset];

            self.offset += 1;
        }
    }

    fn accept_substr(self: *Tokenizer, substr: []const u8) bool {
        if (self.offset + substr.len > self.buf.len) return false;
        if (std.mem.eql(u8, self.buf[self.offset .. self.offset + substr.len], substr)) {
            self.offset += substr.len;
            return true;
        }
        return false;
    }
};

test "simple" {
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
        while (try tokenizer.next()) |token| {
            try token_list.append(token);
        }
        try std.testing.expectEqualDeep(t.tokens, token_list.items);
    }
}
