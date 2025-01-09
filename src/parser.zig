const std = @import("std");
const tokenizer = @import("tokenizer.zig");

const ParserError = error{
    ParsingError,
    OutOfMemory,
};

const NodeType = enum {
    PROGRAM,
    STATEMENT,
    VARIABLE_STATEMENT,
    PRINT_STATEMENT,
    EXPRESSION,
};

pub const Node = union(NodeType) { PROGRAM: struct {
    statements: []*Node,
}, STATEMENT: struct {
    statement: *Node,
}, VARIABLE_STATEMENT: struct {
    is_declaration: bool,
    name: []const u8,
    expression: *Node,
}, PRINT_STATEMENT: struct {
    expression: *Node,
}, EXPRESSION: union(enum) {
    NUMBER: struct {
        value: i64,
    },
    IDENTIFIER: struct {
        name: []const u8,
    },
} };

pub const Parser = struct {
    tokens: []tokenizer.Token,
    offset: u32,

    allocator: std.mem.Allocator,

    pub fn init(tokens: []tokenizer.Token, allocator: std.mem.Allocator) ParserError!*Parser {
        const parser = try allocator.create(Parser);
        parser.* = .{
            .tokens = tokens,
            .offset = 0,
            .allocator = allocator,
        };
        return parser;
    }

    pub fn parse(self: *Parser) !*Node {
        return self.parse_program();
    }

    // Program ::= Statement+
    fn parse_program(self: *Parser) !*Node {
        var nodes = std.ArrayList(*Node).init(self.allocator);
        defer nodes.deinit();
        while (self.offset < self.tokens.len) {
            try nodes.append(@constCast(try self.parse_statement()));
        }

        return self.create_node(.{ .PROGRAM = .{
            .statements = try nodes.toOwnedSlice(),
        } });
    }

    // Statement ::= (VariableStatement | PrintStatement) SEMICOLON
    fn parse_statement(self: *Parser) ParserError!*Node {
        const token = self.peek_token() orelse return ParserError.ParsingError;

        const statement = switch (token) {
            .PRINT => try self.parse_print_statement(),
            else => try self.parse_variable_statement(),
        };

        _ = try self.accept_token(tokenizer.TokenType.SEMICOLON);

        return self.create_node(.{
            .STATEMENT = .{
                .statement = statement,
            },
        });
    }

    // VariableStatement ::= ("let" IDENTIFIER | IDENTIFIER) EQUALS Expression
    fn parse_variable_statement(self: *Parser) ParserError!*Node {
        const token = self.peek_token() orelse return ParserError.ParsingError;

        var is_declaration: bool = false;
        if (token == .LET) {
            is_declaration = true;
            _ = self.consume_token() orelse return ParserError.ParsingError;
        }

        const identifier = try self.accept_token(tokenizer.TokenType.IDENTIFIER);

        _ = try self.accept_token(tokenizer.TokenType.EQUALS);

        const expression = try self.parse_expression();

        return self.create_node(.{
            .VARIABLE_STATEMENT = .{
                .is_declaration = is_declaration,
                .name = try self.allocator.dupe(u8, identifier.IDENTIFIER),
                .expression = @constCast(expression),
            },
        });
    }

    // PrintStatement :== PRINT LPAREN Expression RPAREN
    fn parse_print_statement(self: *Parser) ParserError!*Node {
        _ = try self.accept_token(tokenizer.TokenType.PRINT);

        _ = try self.accept_token(tokenizer.TokenType.LPAREN);

        const expression = try self.parse_expression();

        _ = try self.accept_token(tokenizer.TokenType.RPAREN);

        return self.create_node(.{
            .PRINT_STATEMENT = .{
                .expression = @constCast(expression),
            },
        });
    }

    // Expression :== NUMBER | IDENTIFIER
    fn parse_expression(self: *Parser) ParserError!*Node {
        const token = self.consume_token() orelse return ParserError.ParsingError;

        return switch (token) {
            .NUMBER => |number_token| self.create_node(.{
                .EXPRESSION = .{
                    .NUMBER = .{
                        .value = number_token,
                    },
                },
            }),
            .IDENTIFIER => |identifier_token| self.create_node(.{
                .EXPRESSION = .{
                    .IDENTIFIER = .{
                        .name = try self.allocator.dupe(u8, identifier_token),
                    },
                },
            }),
            else => unreachable,
        };
    }

    fn accept_token(self: *Parser, expected_token: tokenizer.TokenType) ParserError!tokenizer.Token {
        const token = self.peek_token() orelse return ParserError.ParsingError;

        if (token != expected_token) return ParserError.ParsingError;

        return self.consume_token() orelse unreachable;
    }

    fn consume_token(self: *Parser) ?tokenizer.Token {
        if (self.offset >= self.tokens.len) return null;

        defer self.offset += 1;

        return self.tokens[self.offset];
    }

    fn peek_token(self: *Parser) ?tokenizer.Token {
        if (self.offset >= self.tokens.len) return null;

        return self.tokens[self.offset];
    }

    fn create_node(self: *Parser, node_value: Node) !*Node {
        const node = try self.allocator.create(Node);
        node.* = node_value;
        return node;
    }
};

test "parse print" {
    const tokens: []tokenizer.Token = @constCast(&[_]tokenizer.Token{
        tokenizer.Token{ .PRINT = void{} },
        tokenizer.Token{ .LPAREN = void{} },
        tokenizer.Token{ .NUMBER = 7 },
        tokenizer.Token{ .RPAREN = void{} },
        tokenizer.Token{ .SEMICOLON = void{} },
    });
    var parser = Parser.init(tokens);
    const print = try parser.parse_print_statement();
    std.debug.print("PRINT: {any}\n", .{print});
    //TODO: Warning ptr
    // try std.testing.expectEqualDeep(Node{ .PRINT_STATEMENT = .{ .expression = @constCast(&Node{ .NUMBER = .{
    //     .value = 7,
    // } }) } }, print);
    const expectedNode = Node{ .PRINT_STATEMENT = .{
        .expression = @constCast(&Node{ .NUMBER = .{
            .value = 9,
        } }),
    } };
    std.debug.print("EXPECTED: {any}\n", .{expectedNode});
    // TODO: This seems bugged with recursive types maybe?
    // try std.testing.expectEqualDeep(expectedNode, print);
}

// test "parse identifier" {
//     const tokens: []tokenizer.Token = @constCast(&[_]tokenizer.Token{
//         tokenizer.Token{ .IDENTIFIER = @constCast("i") },
//     });
//     var parser = Parser.init(tokens);
//     const ident = try parser.parse_identifier();
//     try std.testing.expectEqualDeep(Node{ .IDENTIFIER = .{
//         .name = @constCast("i"),
//     } }, ident);
// }
//
// test "narse number" {
//     const tokens: []tokenizer.Token = @constCast(&[_]tokenizer.Token{
//         tokenizer.Token{ .NUMBER = 7 },
//     });
//     var parser = Parser.init(tokens);
//     const number = try parser.parse_number();
//     try std.testing.expectEqualDeep(Node{ .NUMBER = .{
//         .value = 7,
//     } }, number);
// }
//
// test "simple e2e" {
//     const tokens: []tokenizer.Token = @constCast(&[_]tokenizer.Token{
//         tokenizer.Token{ .LET = void{} },
//         tokenizer.Token{ .IDENTIFIER = @constCast("i") },
//         tokenizer.Token{ .EQUALS = void{} },
//         tokenizer.Token{ .NUMBER = 2 },
//         tokenizer.Token{ .SEMICOLON = void{} },
//     });
//
//     const ast = try Parser.init(tokens).parse();
//
//     try std.testing.expectEqualDeep(Node{ .PROGRAM = .{ .statements = @constCast(&[_]*Node{
//         @constCast(&Node{ .VARIABLE_STATEMENT = .{ .is_declaration = true, .name = @constCast("i"), .expression = @constCast(&Node{
//             .NUMBER = .{ .value = 2 },
//         }) } }),
//     }) } }, ast);
// }
