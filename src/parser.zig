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
    FUNCTION_CALL_STATEMENT,
    IF_STATEMENT,
    EQUALITY_EXPRESSION,
    ADDITIVE_EXPRESSION,
    UNARY_EXPRESSION,
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
    FUNCTION_CALL_STATEMENT: struct {
        name: []const u8,
        arguments: []*Node,
    },
    IF_STATEMENT: struct {
        condition: *Node,
        statements: []*Node,
    },
    EQUALITY_EXPRESSION: struct {
        lhs: *Node,
        rhs: *Node,
    },
    ADDITIVE_EXPRESSION: struct {
        addition: bool,
        lhs: *Node,
        rhs: *Node,
    },
    UNARY_EXPRESSION: struct {
        negation: bool,
        expression: *Node,
    },
    PRIMARY_EXPRESSION: union(enum) {
        NUMBER: struct {
            value: i64,
        },
        BOOLEAN: struct {
            value: bool,
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
        parameters: []*Node,
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
        return try self.parse_program();
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

    // Statement    ::= (AssignmentStatement | FunctionCallStatement | IfStatement | ReturnStatement) SEMICOLON
    fn parse_statement(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing statement\n", .{});

        const statement = self.accept_parse(parse_function_call_statement) orelse
            self.accept_parse(parse_if_statement) orelse
            self.accept_parse(parse_return_statement) orelse
            try self.parse_assignment_statement();

        _ = try self.parse_token(tokenizer.TokenType.SEMICOLON);

        return self.create_node(.{
            .STATEMENT = .{
                .statement = statement,
            },
        });
    }

    // AssignmentStatement ::= "let" IDENTIFIER EQUALS Expression
    fn parse_assignment_statement(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing assignment statement\n", .{});

        var is_declaration: bool = false;
        if (self.accept_token(.LET) != null) {
            is_declaration = true;
        }

        const identifier = try self.parse_token(tokenizer.TokenType.IDENTIFIER);

        _ = try self.parse_token(tokenizer.TokenType.EQUALS);

        const expression = try self.parse_expression();

        return self.create_node(.{
            .ASSIGNMENT_STATEMENT = .{
                .is_declaration = is_declaration,
                .name = try self.allocator.dupe(u8, identifier.IDENTIFIER),
                .expression = @constCast(expression),
            },
        });
    }

    // FunctionCallStatement ::= IDENTIFIER LPAREN FunctionArguments? RPAREN
    fn parse_function_call_statement(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing function call statement\n", .{});

        const identifier = try self.parse_token(tokenizer.TokenType.IDENTIFIER);

        _ = try self.parse_token(tokenizer.TokenType.LPAREN);

        const arguments = try self.parse_function_arguments();

        _ = try self.parse_token(tokenizer.TokenType.RPAREN);

        return self.create_node(.{ .FUNCTION_CALL_STATEMENT = .{
            .name = try self.allocator.dupe(u8, identifier.IDENTIFIER),
            .arguments = arguments,
        } });
    }

    // FunctionArguments ::= Expression ("," Expression)*
    fn parse_function_arguments(self: *Parser) ParserError![]*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing function arguments\n", .{});
        var node_list = std.ArrayList(*Node).init(self.allocator);

        var first = true;
        while (true) {
            if (!first) {
                _ = self.accept_token(tokenizer.TokenType.COMMA);
            }
            first = false;
            const expr = self.accept_parse(parse_expression) orelse return node_list.items;
            try node_list.append(expr);
        }

        return node_list.items;
    }

    // IfStatement ::= "if" Expression LBRACE Statement* RBRACE
    fn parse_if_statement(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing if statement\n", .{});

        _ = try self.parse_token(tokenizer.TokenType.IF);

        const expression = try self.parse_expression();

        _ = try self.parse_token(tokenizer.TokenType.LBRACE);

        var statements = std.ArrayList(*Node).init(self.allocator);
        while (self.accept_parse(parse_statement)) |expr| {
            try statements.append(expr);
        }

        _ = try self.parse_token(tokenizer.TokenType.RBRACE);

        return try self.create_node(.{ .IF_STATEMENT = .{
            .condition = expression,
            .statements = statements.items,
        } });
    }

    // Expression   ::= EqualityExpression | AdditiveExpression | FunctionDefinition
    fn parse_expression(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing expression\n", .{});

        return self.accept_parse(parse_equality_expression) orelse
            self.accept_parse(parse_additive_expression) orelse
            self.accept_parse(parse_function_definition) orelse
            return ParserError.ParsingError;
    }

    // EqualityExpression ::= AdditiveExpression "==" AdditiveExpression
    fn parse_equality_expression(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing equality expression\n", .{});

        const lhs = try self.parse_additive_expression();

        _ = try self.parse_token(tokenizer.TokenType.EQUALS);
        _ = try self.parse_token(tokenizer.TokenType.EQUALS);

        const rhs = try self.parse_additive_expression();

        return self.create_node(.{ .EQUALITY_EXPRESSION = .{
            .lhs = lhs,
            .rhs = rhs,
        } });
    }

    // AdditiveExpression ::= UnaryExpression (("+" | "-") UnaryExpression)*
    fn parse_additive_expression(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing additive expression\n", .{});

        var lhs = try self.parse_unary_expression();

        while (true) {
            const plus = self.accept_token(tokenizer.TokenType.PLUS);
            const minus = self.accept_token(tokenizer.TokenType.MINUS);

            if (plus == null and minus == null) break;

            const rhs = try self.parse_unary_expression();

            lhs = try self.create_node(.{ .ADDITIVE_EXPRESSION = .{
                .addition = plus != null,
                .lhs = lhs,
                .rhs = rhs,
            } });
        }

        return lhs;
    }

    // UnaryExpression ::= "!" UnaryExpression | PrimaryExpression
    fn parse_unary_expression(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing unary expression\n", .{});

        const negation = self.accept_token(tokenizer.TokenType.NOT) != null;

        if (!negation) {
            return try self.parse_primary_expression();
        }

        return self.create_node(.{ .UNARY_EXPRESSION = .{
            .negation = negation,
            .expression = try self.parse_unary_expression(),
        } });
    }

    // PrimaryExpression ::= NUMBER | BOOLEAN | IDENTIFIER | FunctionCallStatement | LPAREN Expression RPAREN
    fn parse_primary_expression(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing primary expression\n", .{});

        if (self.accept_token(tokenizer.TokenType.LPAREN)) |_| {
            const expr = try self.parse_expression();
            _ = try self.parse_token(tokenizer.TokenType.RPAREN);
            std.debug.print("HERE!\n", .{});
            return expr;
        }

        if (self.accept_parse(parse_function_call_statement)) |stmt| return stmt;

        const token = self.consume_token() orelse return ParserError.ParsingError;

        return switch (token) {
            .NUMBER => |number_token| try self.create_node(.{
                .PRIMARY_EXPRESSION = .{
                    .NUMBER = .{
                        .value = number_token,
                    },
                },
            }),
            .BOOLEAN => |boolean_token| try self.create_node(.{
                .PRIMARY_EXPRESSION = .{ .BOOLEAN = .{
                    .value = boolean_token,
                } },
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

    // FunctionDefinition ::= LPAREN FunctionParamters? RPAREN ARROW LBRACE Statement* ReturnStatement RBRACE
    fn parse_function_definition(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing function definition\n", .{});

        _ = try self.parse_token(tokenizer.TokenType.LPAREN);

        const parameters = try self.parse_function_parameters();

        _ = try self.parse_token(tokenizer.TokenType.RPAREN);

        _ = try self.parse_token(tokenizer.TokenType.ARROW);
        _ = try self.parse_token(tokenizer.TokenType.LBRACE);

        var nodes = std.ArrayList(*Node).init(self.allocator);
        while (self.accept_parse(parse_statement)) |expression| {
            try nodes.append(expression);
        }

        std.debug.assert(nodes.getLast().STATEMENT.statement.* == .RETURN_STATEMENT);

        _ = try self.parse_token(tokenizer.TokenType.RBRACE);

        return self.create_node(.{ .FUNCTION_DEFINITION = .{
            .statements = nodes.items,
            .parameters = parameters,
        } });
    }

    // FunctionParameters ::= IDENTIFIER ("," IDENTIFIER)*
    fn parse_function_parameters(self: *Parser) ParserError![]*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing function parameters\n", .{});
        var node_list = std.ArrayList(*Node).init(self.allocator);

        var first = true;
        while (true) {
            if (!first) {
                _ = self.accept_token(tokenizer.TokenType.COMMA);
            }
            first = false;
            const ident = self.accept_token(tokenizer.TokenType.IDENTIFIER) orelse return node_list.items;

            try node_list.append(try self.create_node(.{
                .PRIMARY_EXPRESSION = .{
                    .IDENTIFIER = .{
                        .name = try self.allocator.dupe(u8, ident.IDENTIFIER),
                    },
                },
            }));
        }

        return node_list.items;
    }

    // ReturnStatement ::= RETURN Expression
    fn parse_return_statement(self: *Parser) ParserError!*Node {
        errdefer if (!self.try_context) std.debug.print("Error parsing return statement\n", .{});
        _ = try self.parse_token(tokenizer.TokenType.RETURN);

        const expression = try self.parse_expression();

        return self.create_node(.{
            .RETURN_STATEMENT = .{
                .expression = @constCast(expression),
            },
        });
    }

    fn parse_token(self: *Parser, expected_token: tokenizer.TokenType) ParserError!tokenizer.Token {
        errdefer if (!self.try_context) std.debug.print("Error accepting token: {any}\n", .{expected_token});
        const token = self.peek_token() orelse return ParserError.ParsingError;

        if (token != expected_token) {
            if (!self.try_context) std.debug.print("Expected {any} - found {any}\n", .{ expected_token, token });
            return ParserError.ParsingError;
        }

        return self.consume_token() orelse unreachable;
    }

    fn accept_parse(self: *Parser, parsing_func: *const fn (_: *Parser) ParserError!*Node) ?*Node {
        const prev_offset = self.offset;
        const prev_try_context = self.try_context;
        self.try_context = true;
        const node = parsing_func(self) catch {
            self.offset = prev_offset;
            self.try_context = prev_try_context;
            return null;
        };
        self.try_context = prev_try_context;
        return node;
    }

    fn accept_token(self: *Parser, token: tokenizer.TokenType) ?tokenizer.Token {
        const curr_token = self.peek_token() orelse return null;
        if (curr_token == token) {
            return self.consume_token();
        }
        return null;
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
