const std = @import("std");
const tokenizer = @import("tokenizer.zig");

const ParserError = error{
    ParsingError,
    OutOfMemory,
};

const NodeType = enum {
    PROGRAM,
    STATEMENT,
    ASSIGNMENT_STATEMENT,
    PRINT_STATEMENT,
    FUNCTION_CALL_STATEMENT,
    EXPRESSION,
    ADDITIVE_EXPRESSION,
    PRIMARY_EXPRESSION,
    FUNCTION_DEFINITION,
    RETURN_STATEMENT,
};

pub const Node = union(NodeType) {
    PROGRAM: struct {
        statements: []*Node,
    },
    STATEMENT: struct {
        statement: *Node,
    },
    ASSIGNMENT_STATEMENT: struct {
        is_declaration: bool,
        name: []const u8,
        expression: *Node,
    },
    PRINT_STATEMENT: struct {
        expression: *Node,
    },
    FUNCTION_CALL_STATEMENT: struct {
        name: []const u8,
    },
    EXPRESSION: struct {
        ADDITIVE_EXPRESSION: struct {
            expression: *Node,
        },
        FUNCTION_DEFINITION: struct {
            expression: *Node,
        },
    },
    ADDITIVE_EXPRESSION: struct {
        lhs: *Node,
        rhs: *Node,
    },
    PRIMARY_EXPRESSION: union(enum) {
        NUMBER: struct {
            value: i64,
        },
        IDENTIFIER: struct {
            name: []const u8,
        },
        FUNCTION_CALL: struct {
            name: []const u8,
        },
    },
    FUNCTION_DEFINITION: struct {
        statements: []*Node,
    },
    RETURN_STATEMENT: struct {
        expression: *Node,
    },
};

pub const Parser = struct {
    tokens: []tokenizer.Token,
    offset: u32,

    allocator: std.mem.Allocator,

    try_context: bool, //TODO: I dont like this

    pub fn init(tokens: []tokenizer.Token, arena_allocator: *std.heap.ArenaAllocator) ParserError!*Parser {
        const parser = try arena_allocator.allocator().create(Parser);
        parser.* = .{
            .tokens = tokens,
            .offset = 0,
            .allocator = arena_allocator.allocator(),
            .try_context = false,
        };
        return parser;
    }

    pub fn parse(self: *Parser) !*Node {
        return self.parse_program();
    }

    // Program ::= Statement+
    fn parse_program(self: *Parser) !*Node {
        var nodes = std.ArrayList(*Node).init(self.allocator);
        while (self.offset < self.tokens.len) {
            try nodes.append(@constCast(try self.parse_statement()));
        }

        return self.create_node(.{ .PROGRAM = .{
            .statements = try nodes.toOwnedSlice(),
        } });
    }

    // Statement ::= (AssignmentStatement | PrintStatement | FunctionCallStatement) SEMICOLON
    fn parse_statement(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing statement\n", .{});

        var statement: ?*Node = undefined;
        if (self.accept_parse(parse_print_statement)) |stmt| {
            statement = stmt;
        } else if (self.accept_parse(parse_function_call_statement)) |stmt| {
            statement = stmt;
        } else {
            statement = try self.parse_assignment_statement();
        }
        _ = try self.accept_token(tokenizer.TokenType.SEMICOLON);

        return self.create_node(.{
            .STATEMENT = .{
                .statement = statement.?,
            },
        });
    }

    // AssignmentStatement ::= "let" IDENTIFIER EQUALS Expression
    fn parse_assignment_statement(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing assignment statement\n", .{});

        var is_declaration: bool = false;
        if (self.match_token(.LET)) {
            is_declaration = true;
        }

        const identifier = try self.accept_token(tokenizer.TokenType.IDENTIFIER);

        _ = try self.accept_token(tokenizer.TokenType.EQUALS);

        const expression = try self.parse_expression();

        return self.create_node(.{
            .ASSIGNMENT_STATEMENT = .{
                .is_declaration = is_declaration,
                .name = try self.allocator.dupe(u8, identifier.IDENTIFIER),
                .expression = @constCast(expression),
            },
        });
    }

    // PrintStatement :== PRINT LPAREN Expression RPAREN
    fn parse_print_statement(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing print statement\n", .{});
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

    // FunctionCallStatement ::= IDENTIFIER LPAREN RPAREN
    fn parse_function_call_statement(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing function call statement\n", .{});

        const identifier = try self.accept_token(tokenizer.TokenType.IDENTIFIER);

        _ = try self.accept_token(tokenizer.TokenType.LPAREN);
        _ = try self.accept_token(tokenizer.TokenType.RPAREN);

        return self.create_node(.{ .FUNCTION_CALL_STATEMENT = .{ .name = try self.allocator.dupe(u8, identifier.IDENTIFIER) } });
    }

    // Expression   ::= AdditiveExpression | FunctionDefinition
    fn parse_expression(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing expression\n", .{});

        if (self.accept_parse(parse_additive_expression)) |expression| {
            return expression;
        } else if (self.accept_parse(parse_function_definition)) |expression| {
            return expression;
        }

        return ParserError.ParsingError;
    }

    // AdditiveExpression ::= PrimaryExpression ("+" AdditiveExpression)
    fn parse_additive_expression(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing additive expression\n", .{});

        const lhs = try self.parse_primary_expression();

        if (self.match_token(tokenizer.TokenType.PLUS)) {
            const rhs = try self.parse_additive_expression();
            return self.create_node(.{ .ADDITIVE_EXPRESSION = .{
                .lhs = lhs,
                .rhs = rhs,
            } });
        }

        return lhs;
    }

    // PrimaryExpression ::= NUMBER | IDENTIFIER | FunctionCallStatement
    fn parse_primary_expression(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing primary expression\n", .{});

        const token = self.consume_token() orelse return ParserError.ParsingError;

        if (self.accept_parse(parse_function_call_statement)) |stmt| return stmt;

        return switch (token) {
            .NUMBER => |number_token| try self.create_node(.{
                .PRIMARY_EXPRESSION = .{
                    .NUMBER = .{
                        .value = number_token,
                    },
                },
            }),
            .IDENTIFIER => |identifier_token| try self.create_node(.{
                .PRIMARY_EXPRESSION = .{
                    .IDENTIFIER = .{
                        .name = try self.allocator.dupe(u8, identifier_token),
                    },
                },
            }),
            else => ParserError.ParsingError,
        };
    }

    // FunctionDefinition ::= ARROW LBRACE Statement* ReturnStatement RBRACE
    fn parse_function_definition(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing function definition\n", .{});

        _ = try self.accept_token(tokenizer.TokenType.LPAREN);
        _ = try self.accept_token(tokenizer.TokenType.RPAREN);
        _ = try self.accept_token(tokenizer.TokenType.ARROW);
        _ = try self.accept_token(tokenizer.TokenType.LBRACE);

        var nodes = std.ArrayList(*Node).init(self.allocator);
        while (self.accept_parse(parse_statement)) |expression| {
            try nodes.append(expression);
        }

        try nodes.append(try self.parse_return_statement());

        _ = try self.accept_token(tokenizer.TokenType.RBRACE);

        return self.create_node(.{ .FUNCTION_DEFINITION = .{
            .statements = nodes.items,
        } });
    }

    // ReturnStatement :== RETURN Expression
    fn parse_return_statement(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing return statement\n", .{});
        _ = try self.accept_token(tokenizer.TokenType.RETURN);

        const expression = try self.parse_expression();

        _ = try self.accept_token(tokenizer.TokenType.SEMICOLON); //TODO: I dont like this

        return self.create_node(.{
            .RETURN_STATEMENT = .{
                .expression = @constCast(expression),
            },
        });
    }

    fn accept_parse(self: *Parser, parsing_func: *const fn (_: *Parser) ParserError!*Node) ?*Node {
        const prev_offset = self.offset;
        self.try_context = true;
        defer self.try_context = false;
        const node = parsing_func(self) catch {
            self.offset = prev_offset;
            return null;
        };
        return node;
    }

    fn accept_token(self: *Parser, expected_token: tokenizer.TokenType) ParserError!tokenizer.Token {
        errdefer if (!self.try_context) std.debug.print("Error accepting token: {any}\n", .{expected_token});
        const token = self.peek_token() orelse return ParserError.ParsingError;

        if (token != expected_token) {
            if (!self.try_context) std.debug.print("Expected {any} - found {any}\n", .{ expected_token, token });
            return ParserError.ParsingError;
        }

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
    const expected_ast = Node{ .PROGRAM = .{ .statements = @constCast(&[_]*Node{@constCast(&Node{ .STATEMENT = .{ .statement = @constCast(&Node{ .ASSIGNMENT_STATEMENT = .{
        .is_declaration = true,
        .name = @constCast("i"),
        .expression = @constCast(&Node{ .EXPRESSION = .{
            .NUMBER = .{ .value = 2 },
        } }),
    } }) } })}) } };
    try std.testing.expectEqualDeep(&expected_ast, ast);
}
