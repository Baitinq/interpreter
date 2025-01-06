const std = @import("std");
const tokenizer = @import("tokenizer.zig");

const NodeType = enum {
    PROGRAM,
    VARIABLE_STATEMENT,
    PRINT_STATEMENT,
    NUMBER,
    IDENTIFIER,
};

pub const Node = union(NodeType) {
    PROGRAM: struct {
        statements: []*Node,
    },
    VARIABLE_STATEMENT: struct {
        is_declaration: bool,
        name: []const u8,
        expression: *Node,
    },
    PRINT_STATEMENT: struct {
        expression: *Node,
    },
    NUMBER: struct {
        value: i64,
    },
    IDENTIFIER: struct {
        name: []const u8,
    },
};

pub const Parser = struct {
    tokens: []tokenizer.Token,
    offset: u32,

    pub fn init(tokens: []tokenizer.Token) *Parser {
        return @constCast(&Parser{
            .tokens = tokens,
            .offset = 0,
        });
    }

    pub fn parse(parser: *Parser) !Node {
        return parser.parse_program();
    }

    fn parse_program(_: *Parser) !Node {
        return Node{
            .NUMBER = .{ .value = 9 },
        };
    }

    fn parse_identifier(self: *Parser) !Node {
        const token = self.peek_token() orelse return error.InvalidArgument;

        if (token != .IDENTIFIER) return error.InvalidArgument;

        _ = self.consume_token();

        return Node{ .IDENTIFIER = .{
            .name = token.IDENTIFIER,
        } };
    }

    fn parse_number(self: *Parser) !Node {
        const token = self.peek_token() orelse return error.InvalidArgument;

        if (token != .NUMBER) return error.InvalidArgument;

        _ = self.consume_token();

        return Node{ .NUMBER = .{
            .value = token.NUMBER,
        } };
    }

    fn consume_token(self: *Parser) ?tokenizer.Token {
        if (self.offset >= self.tokens.len) return null;

        defer self.offset += 1;

        return self.tokens[self.offset];
    }

    fn peek_token(self: Parser) ?tokenizer.Token {
        if (self.offset >= self.tokens.len) return null;

        return self.tokens[self.offset];
    }
};

test "parse identifier" {
    const tokens: []tokenizer.Token = @constCast(&[_]tokenizer.Token{
        tokenizer.Token{ .IDENTIFIER = @constCast("i") },
    });
    var parser = Parser.init(tokens);
    const ident = try parser.parse_identifier();
    try std.testing.expectEqualDeep(Node{ .IDENTIFIER = .{
        .name = @constCast("i"),
    } }, ident);
}

test "parse number" {
    const tokens: []tokenizer.Token = @constCast(&[_]tokenizer.Token{
        tokenizer.Token{ .NUMBER = 7 },
    });
    var parser = Parser.init(tokens);
    const number = try parser.parse_number();
    try std.testing.expectEqualDeep(Node{ .NUMBER = .{
        .value = 7,
    } }, number);
}

test "simple e2e" {
    const tokens: []tokenizer.Token = @constCast(&[_]tokenizer.Token{
        tokenizer.Token{ .LET = void{} },
        tokenizer.Token{ .IDENTIFIER = @constCast("i") },
        tokenizer.Token{ .EQUALS = void{} },
        tokenizer.Token{ .NUMBER = 2 },
        tokenizer.Token{ .SEMICOLON = void{} },
    });

    const ast = try Parser.init(tokens).parse();

    try std.testing.expectEqualDeep(Node{ .PROGRAM = .{ .statements = @constCast(&[_]*Node{
        @constCast(&Node{ .VARIABLE_STATEMENT = .{ .is_declaration = true, .name = @constCast("i"), .expression = @constCast(&Node{
            .NUMBER = .{ .value = 2 },
        }) } }),
    }) } }, ast);
}
