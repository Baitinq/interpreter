const std = @import("std");

const TokenizerError = error{
    TokenizingError,
};

pub const TokenType = union(enum) {
    // Keywords
    LET: void,
    IF: void,
    WHILE: void,
    RETURN: void,
    ARROW: void,

    // Identifiers
    IDENTIFIER: []u8,

    // Literals
    NUMBER: i64,
    BOOLEAN: bool,

    // Operators
    EQUALS: void,
    PLUS: void,
    MINUS: void,
    MUL: void,
    DIV: void,
    BANG: void,
    LESS: void,
    GREATER: void,

    // Punctuation
    SEMICOLON: void,
    COMMA: void,
    COLON: void,
    LPAREN: void,
    RPAREN: void,
    LBRACE: void,
    RBRACE: void,
};

const TokenLocation = struct {
    col: u64,
    row: u64,
};

pub const Token = struct {
    location: TokenLocation,
    offset: u64,
    type: TokenType,
};

pub const Tokenizer = struct {
    buf: []u8,
    offset: u64,

    pub fn init(buf: []u8) !Tokenizer {
        return Tokenizer{ .buf = buf, .offset = 0 };
    }

    pub fn next(self: *Tokenizer) TokenizerError!?Token {
        self.skip_whitespace();
        self.skip_comments();
        self.skip_whitespace();

        if (self.offset >= self.buf.len) return null;

        if (self.accept_string("let")) return self.create_token(.{ .LET = void{} });
        if (self.accept_string("if")) return self.create_token(.{ .IF = void{} });
        if (self.accept_string("while")) return self.create_token(.{ .WHILE = void{} });
        if (self.accept_string("return")) return self.create_token(.{ .RETURN = void{} });
        if (self.accept_string("true")) return self.create_token(.{ .BOOLEAN = true });
        if (self.accept_string("false")) return self.create_token(.{ .BOOLEAN = false });

        if (self.accept_string("=>")) return self.create_token(.{ .ARROW = void{} });
        if (self.accept_string(";")) return self.create_token(.{ .SEMICOLON = void{} });
        if (self.accept_string(",")) return self.create_token(.{ .COMMA = void{} });
        if (self.accept_string(":")) return self.create_token(.{ .COLON = void{} });
        if (self.accept_string("(")) return self.create_token(.{ .LPAREN = void{} });
        if (self.accept_string(")")) return self.create_token(.{ .RPAREN = void{} });
        if (self.accept_string("{")) return self.create_token(.{ .LBRACE = void{} });
        if (self.accept_string("}")) return self.create_token(.{ .RBRACE = void{} });
        if (self.accept_string("=")) return self.create_token(.{ .EQUALS = void{} });
        if (self.accept_string("+")) return self.create_token(.{ .PLUS = void{} });
        if (self.accept_string("-")) return self.create_token(.{ .MINUS = void{} });
        if (self.accept_string("*")) return self.create_token(.{ .MUL = void{} });
        if (self.accept_string("/")) return self.create_token(.{ .DIV = void{} });
        if (self.accept_string("!")) return self.create_token(.{ .BANG = void{} });
        if (self.accept_string("<")) return self.create_token(.{ .LESS = void{} });
        if (self.accept_string(">")) return self.create_token(.{ .GREATER = void{} });

        const string = self.consume_string();
        if (string.len == 0) return TokenizerError.TokenizingError;

        if (std.fmt.parseInt(i32, string, 10) catch null) |i| return self.create_token(.{ .NUMBER = i });

        return self.create_token(.{ .IDENTIFIER = string });
    }

    fn skip_comments(self: *Tokenizer) void {
        if (!self.accept_string("/*")) return;

        while (!self.accept_string("*/")) {
            self.offset += 1;
        }
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
            defer self.offset += 1;
            if (self.offset >= self.buf.len) return self.buf[start..self.offset];

            const c = self.buf[self.offset];

            if (!std.ascii.isAlphanumeric(c) and c != '_') return self.buf[start..self.offset];
        }
    }

    fn accept_string(self: *Tokenizer, substr: []const u8) bool {
        if (self.offset + substr.len > self.buf.len) return false;
        if (std.mem.eql(u8, self.buf[self.offset .. self.offset + substr.len], substr)) {
            self.offset += substr.len;
            return true;
        }
        return false;
    }

    fn create_token(self: *Tokenizer, token_type: TokenType) Token {
        return Token{
            .location = self.compute_location(),
            .offset = self.offset - 1,
            .type = token_type,
        };
    }

    fn compute_location(self: *Tokenizer) TokenLocation {
        var location = TokenLocation{ .col = 1, .row = 1 };

        var i: usize = 0;
        while (i < self.offset) : (i += 1) {
            if (self.buf[i] == '\n') {
                location.row += 1;
                location.col = 1;
            } else {
                location.col += 1;
            }
        }

        // We need to do this because we call this fn after we consume the token
        location.row -= 1;
        location.col -= 1;

        return location;
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
