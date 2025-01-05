const std = @import("std");

pub const Tokenizer = struct {
    buf: []u8,
    offset: u32,

    pub fn init(buf: []u8) !Tokenizer {
        return Tokenizer{ .buf = buf, .offset = 0 };
    }

    pub fn next(_: *Tokenizer) ?Token {
        return null;
        // return Token{
        //     .LET = void{},
        // };
    }
};

const TokenType = enum {
    // Keywords
    LET,
    PRINT,

    // Identifiers
    IDENTIFIER,

    // Literals
    NUMBER,
    STRING,

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
    STRING: []u8,
    EQUALS: void,
    SEMICOLON: void,
    LPAREN: void,
    RPAREN: void,
};

test "simple" {
    const buf =
        \\ let i = 2;
        \\
        \\ print(i);
    ;

    var tokenizer = try Tokenizer.init(@constCast(buf));

    var token_list = std.ArrayList(Token).init(std.testing.allocator);
    while (tokenizer.next()) |token| {
        try token_list.append(token);
    }
    try std.testing.expectEqualSlices(Token, &.{
        Token{ .LET = void{} },
        Token{ .IDENTIFIER = @constCast("i") },
        Token{ .EQUALS = void{} },
        Token{ .NUMBER = 2 },
        Token{ .SEMICOLON = void{} },
        Token{ .PRINT = void{} },
        Token{ .LPAREN = void{} },
        Token{ .IDENTIFIER = @constCast("i") },
        Token{ .RPAREN = void{} },
        Token{ .SEMICOLON = void{} },
    }, token_list.items);
}
