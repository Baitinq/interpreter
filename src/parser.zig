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
    RETURN_STATEMENT,
    EXPRESSION,
};

pub const Node = union(NodeType) {
    PROGRAM: struct {
        statements: []*Node,
    },
    STATEMENT: struct {
        statement: *Node,
    },
    VARIABLE_STATEMENT: struct {
        is_declaration: bool,
        name: []const u8,
        expression: *Node,
    },
    PRINT_STATEMENT: struct {
        expression: *Node,
    },
    RETURN_STATEMENT: struct {
        expression: *Node,
    },
    EXPRESSION: union(enum) {
        NUMBER: struct {
            value: i64,
        },
        IDENTIFIER: struct {
            name: []const u8,
        },
        BINARY: struct {
            //TODO: For now, this just represents sum
            lhs: *Node,
            rhs: *Node,
        },
    },
};

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
        errdefer std.debug.print("Error parsing statement\n", .{});
        const token = self.peek_token() orelse return ParserError.ParsingError;

        const statement = switch (token) {
            .PRINT => try self.parse_print_statement(),
            .RETURN => try self.parse_return_statement(),
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
        errdefer std.debug.print("Error parsing variable statement\n", .{});

        var is_declaration: bool = false;
        if (self.match_token(.LET)) {
            is_declaration = true;
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
        errdefer std.debug.print("Error parsing print statement\n", .{});
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

    // ReturnStatement :== RETURN Expression
    fn parse_return_statement(self: *Parser) ParserError!*Node {
        errdefer std.debug.print("Error parsing return statement\n", .{});
        _ = try self.accept_token(tokenizer.TokenType.RETURN);

        const expression = try self.parse_expression();

        return self.create_node(.{
            .RETURN_STATEMENT = .{
                .expression = @constCast(expression),
            },
        });
    }

    // Expression :== NUMBER | IDENTIFIER | Expression + Expression
    fn parse_expression(self: *Parser) ParserError!*Node {
        errdefer std.debug.print("Error parsing expression\n", .{});
        const token = self.consume_token() orelse return ParserError.ParsingError;

        const lhs = try switch (token) {
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

        if (self.match_token(tokenizer.TokenType.PLUS)) {
            const rhs = try self.parse_expression();

            return self.create_node(.{ .EXPRESSION = .{ .BINARY = .{
                .lhs = lhs,
                .rhs = rhs,
            } } });
        }

        return lhs;
    }

    fn accept_token(self: *Parser, expected_token: tokenizer.TokenType) ParserError!tokenizer.Token {
        errdefer std.debug.print("Error accepting token: {any}\n", .{expected_token});
        const token = self.peek_token() orelse return ParserError.ParsingError;

        if (token != expected_token) return ParserError.ParsingError;

        return self.consume_token() orelse unreachable;
    }

    fn match_token(self: *Parser, token: tokenizer.TokenType) bool {
        const curr_token = self.peek_token() orelse return false;
        if (curr_token == token) {
            _ = self.consume_token();
            return true;
        }
        return false;
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(tokens, arena.allocator());
    const actualNode = try parser.parse_print_statement();
    const expectedNode = Node{ .PRINT_STATEMENT = .{
        .expression = @constCast(&Node{ .EXPRESSION = .{
            .NUMBER = .{ .value = 7 },
        } }),
    } };
    try std.testing.expectEqualDeep(&expectedNode, actualNode);
}

test "parse identifier" {
    const tokens: []tokenizer.Token = @constCast(&[_]tokenizer.Token{
        tokenizer.Token{ .IDENTIFIER = @constCast("i") },
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(tokens, arena.allocator());
    const actualNode = try parser.parse_expression();
    const expectedNode = Node{ .EXPRESSION = .{
        .IDENTIFIER = .{
            .name = @constCast("i"),
        },
    } };
    try std.testing.expectEqualDeep(&expectedNode, actualNode);
}

test "parse number" {
    const tokens: []tokenizer.Token = @constCast(&[_]tokenizer.Token{
        tokenizer.Token{ .NUMBER = 12 },
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(tokens, arena.allocator());
    const actualNode = try parser.parse_expression();
    const expectedNode = Node{ .EXPRESSION = .{
        .NUMBER = .{
            .value = 12,
        },
    } };
    try std.testing.expectEqualDeep(&expectedNode, actualNode);
}

test "simple e2e" {
    const tokens: []tokenizer.Token = @constCast(&[_]tokenizer.Token{
        tokenizer.Token{ .LET = void{} },
        tokenizer.Token{ .IDENTIFIER = @constCast("i") },
        tokenizer.Token{ .EQUALS = void{} },
        tokenizer.Token{ .NUMBER = 2 },
        tokenizer.Token{ .SEMICOLON = void{} },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(tokens, arena.allocator());
    const ast = try parser.parse();
    const expected_ast = Node{ .PROGRAM = .{ .statements = @constCast(&[_]*Node{@constCast(&Node{ .STATEMENT = .{ .statement = @constCast(&Node{ .VARIABLE_STATEMENT = .{
        .is_declaration = true,
        .name = @constCast("i"),
        .expression = @constCast(&Node{ .EXPRESSION = .{
            .NUMBER = .{ .value = 2 },
        } }),
    } }) } })}) } };
    try std.testing.expectEqualDeep(&expected_ast, ast);
}
