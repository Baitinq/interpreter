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
        value: i32,
    },
    IDENTIFIER: struct {
        name: []const u8,
    },
};

pub const Parser = struct {
    pub fn parse(_: []tokenizer.Token) !Node {
        return Node{
            .NUMBER = .{ .value = 9 },
        };
    }
};

test "simple" {
    const tokens: []tokenizer.Token = @constCast(&[_]tokenizer.Token{
        tokenizer.Token{ .LET = void{} },
        tokenizer.Token{ .IDENTIFIER = @constCast("i") },
        tokenizer.Token{ .EQUALS = void{} },
        tokenizer.Token{ .NUMBER = 2 },
        tokenizer.Token{ .SEMICOLON = void{} },
    });

    const ast = try Parser.parse(tokens);

    try std.testing.expectEqualDeep(Node{ .PROGRAM = .{ .statements = @constCast(&[_]*Node{
        @constCast(&Node{ .VARIABLE_STATEMENT = .{ .is_declaration = true, .name = @constCast("i"), .expression = @constCast(&Node{
            .NUMBER = .{ .value = 2 },
        }) } }),
    }) } }, ast);
}
