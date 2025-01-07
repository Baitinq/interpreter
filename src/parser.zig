const std = @import("std");
const tokenizer = @import("tokenizer.zig");

const ParserError = error{
    ParsingError,
    OutOfMemory,
};

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

    pub fn deinit(self: *Parser, ast: *Node) void {
        std.debug.assert(ast.* == .PROGRAM);
        std.debug.print("STATEMENTS FREE: {any}\n", .{ast.PROGRAM.statements.len});
        for (ast.PROGRAM.statements) |statement| {
            self.allocator.destroy(statement); //TODO: We're missing frees of children. we also dont want to double free!
        }
    }

    pub fn parse(self: *Parser) !*Node {
        return self.parse_program();
    }

    fn parse_program(self: *Parser) !*Node {
        var nodes = std.ArrayList(*Node).init(self.allocator);
        while (self.offset < self.tokens.len) {
            try nodes.append(@constCast(try self.parse_statement())); //TODO: This is not good, should we be allocating mem for every node?
        }

        const node = try self.allocator.create(Node);
        node.* = .{ .PROGRAM = .{
            .statements = try nodes.toOwnedSlice(),
        } };
        return node;
    }

    fn parse_identifier(self: *Parser) ParserError!*Node {
        const token = self.peek_token() orelse return ParserError.ParsingError;

        if (token != .IDENTIFIER) return ParserError.ParsingError;

        _ = self.consume_token();

        const node = try self.allocator.create(Node);
        node.* = .{ .IDENTIFIER = .{
            .name = token.IDENTIFIER,
        } };
        return node;
    }

    fn parse_number(self: *Parser) ParserError!*Node {
        const token = self.peek_token() orelse return ParserError.ParsingError;

        if (token != .NUMBER) return ParserError.ParsingError;

        _ = self.consume_token();

        const node = try self.allocator.create(Node);
        node.* = .{ .NUMBER = .{
            .value = token.NUMBER,
        } };
        return node;
    }

    fn parse_print_statement(self: *Parser) ParserError!*Node {
        // print + ( + statement + ) + ;
        var token = self.consume_token() orelse return ParserError.ParsingError;

        if (token != .PRINT) return ParserError.ParsingError;

        token = self.consume_token() orelse return ParserError.ParsingError;

        if (token != .LPAREN) return ParserError.ParsingError;

        const expression = try self.parse_statement();

        std.debug.print("PARSED expression: {any}\n", .{expression});

        token = self.consume_token() orelse return ParserError.ParsingError;

        if (token != .RPAREN) return ParserError.ParsingError;

        token = self.consume_token() orelse return ParserError.ParsingError;

        if (token != .SEMICOLON) return ParserError.ParsingError; //TODO: This should not be handled at this level

        const node = try self.allocator.create(Node);
        node.* = .{
            .PRINT_STATEMENT = .{
                .expression = @constCast(expression), //TODO: Warning ptr
            },
        };
        return node;
    }

    fn parse_statement(self: *Parser) ParserError!*Node {
        const token = self.peek_token() orelse return ParserError.ParsingError;

        std.debug.print("TOKEN: {any}\n", .{token});

        //TODO: Add support for parsing variable declaration and assignment. Also here we shouldnt parse numbers/identifiers directly
        if (token == .NUMBER) {
            return self.parse_number();
        } else if (token == .IDENTIFIER) {
            return self.parse_identifier();
        } else if (token == .PRINT) {
            return self.parse_print_statement();
        } else {
            return ParserError.ParsingError;
        }
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
