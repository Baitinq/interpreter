const std = @import("std");
const parser = @import("parser.zig");

const EvaluatorError = error{
    EvaluationError,
    OutOfMemory,
};

pub const Evaluator = struct {
    variables: std.StringHashMap(?*parser.Node), //TODO: Reference vs value

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Evaluator {
        const evaluator = try allocator.create(Evaluator);
        evaluator.* = .{
            .variables = std.StringHashMap(?*parser.Node).init(allocator),
            .allocator = allocator,
        };
        return evaluator;
    }

    pub fn deinit(self: *Evaluator) void {
        self.variables.deinit();
        self.allocator.destroy(self);
    }

    pub fn evaluate_ast(self: *Evaluator, ast: *parser.Node) !i64 {
        errdefer std.debug.print("Error evaluating AST\n", .{});
        std.debug.assert(ast.* == parser.Node.PROGRAM);

        const main = find_main(ast) orelse return EvaluatorError.EvaluationError;
        return try self.evaluate_function_definition(main);
    }

    fn evaluate_statement(self: *Evaluator, statement: *parser.Node) EvaluatorError!void {
        errdefer std.debug.print("Error evaluating statement\n", .{});
        std.debug.assert(statement.* == parser.Node.STATEMENT);

        return switch (statement.STATEMENT.statement.*) {
            .ASSIGNMENT_STATEMENT => |*assignment_statement| try self.evaluate_assignment_statement(@ptrCast(assignment_statement)),
            .PRINT_STATEMENT => |*print_statement| try self.evaluate_print_statement(@ptrCast(print_statement)),
            .FUNCTION_CALL_STATEMENT => |*function_call_statement| _ = try self.evaluate_function_call_statement(@ptrCast(function_call_statement)),
            else => unreachable,
        };
    }

    fn evaluate_assignment_statement(self: *Evaluator, node: *parser.Node) !void {
        errdefer std.debug.print("Error evaluating assignment statement\n", .{});
        std.debug.assert(node.* == parser.Node.ASSIGNMENT_STATEMENT);

        const assignment_statement = node.ASSIGNMENT_STATEMENT;

        //TODO: We should lowercase keys no?
        if (assignment_statement.is_declaration) {
            try self.variables.put(assignment_statement.name, null);
        }

        if (!self.variables.contains(assignment_statement.name)) {
            std.debug.print("Variable not found: {s}\n", .{assignment_statement.name});
            return EvaluatorError.EvaluationError;
        }

        try self.variables.put(assignment_statement.name, assignment_statement.expression);
    }

    fn evaluate_print_statement(self: *Evaluator, print_statement: *parser.Node) !void {
        errdefer std.debug.print("Error evaluating print statement\n", .{});
        std.debug.assert(print_statement.* == parser.Node.PRINT_STATEMENT);

        const print_value = try self.get_expression_value(print_statement.PRINT_STATEMENT.expression);

        std.debug.print("PRINT: {d}\n", .{print_value});
    }

    fn evaluate_function_call_statement(self: *Evaluator, function_call_statement: *parser.Node) !i64 {
        errdefer std.debug.print("Error evaluating function call statement\n", .{});
        std.debug.assert(function_call_statement.* == parser.Node.FUNCTION_CALL_STATEMENT);

        const node = self.variables.get(function_call_statement.FUNCTION_CALL_STATEMENT.name) orelse return EvaluatorError.EvaluationError;

        return try self.evaluate_function_definition(node.?);
    }

    fn evaluate_return_statement(self: *Evaluator, return_statement: *parser.Node) !i64 {
        errdefer std.debug.print("Error evaluating return statement\n", .{});
        std.debug.assert(return_statement.* == parser.Node.RETURN_STATEMENT);

        const return_value = try self.get_expression_value(return_statement.RETURN_STATEMENT.expression);

        return return_value;
    }

    fn get_expression_value(self: *Evaluator, node: *parser.Node) !i64 {
        errdefer std.debug.print("Error getting statement value\n", .{});

        switch (node.*) {
            .ADDITIVE_EXPRESSION => |x| {
                const lhs = try self.get_expression_value(x.lhs);
                const rhs = try self.get_expression_value(x.rhs);
                return lhs + rhs;
            },
            .PRIMARY_EXPRESSION => |x| {
                switch (x) {
                    .NUMBER => |number| return number.value,
                    .IDENTIFIER => |identifier| {
                        const val = self.variables.get(identifier.name) orelse {
                            std.debug.print("Identifier {any} not found\n", .{identifier.name});
                            return EvaluatorError.EvaluationError;
                        };

                        return self.get_expression_value(val.?);
                    },
                    else => unreachable,
                }
            },

            else => unreachable,
        }
    }

    fn evaluate_function_definition(self: *Evaluator, node: *parser.Node) !i64 {
        errdefer std.debug.print("Error evaluating function definition\n", .{});
        std.debug.assert(node.* == parser.Node.FUNCTION_DEFINITION);

        const function_definition = node.*.FUNCTION_DEFINITION;

        var i: usize = 0;
        while (i < function_definition.statements.len - 1) {
            const stmt = function_definition.statements[i];
            try self.evaluate_statement(stmt);
            i += 1;
        }

        const return_stmt = function_definition.statements[i];
        return try self.evaluate_return_statement(return_stmt);
    }

    fn find_main(ast: *parser.Node) ?*parser.Node {
        errdefer std.debug.print("Error finding main function\n", .{});
        std.debug.assert(ast.* == parser.Node.PROGRAM);

        for (ast.PROGRAM.statements) |*statement| {
            const x = statement.*.STATEMENT.statement;
            if (x.* != parser.Node.ASSIGNMENT_STATEMENT) continue;
            const y = x.*.ASSIGNMENT_STATEMENT;
            if (y.is_declaration and std.mem.eql(u8, y.name, "main")) {
                return y.expression;
            }
        }

        return null;
    }
};

test "simple" {
    const ast = &parser.Node{ .PROGRAM = .{ .statements = @constCast(&[_]*parser.Node{ @constCast(&parser.Node{ .STATEMENT = .{ .statement = @constCast(&parser.Node{ .VARIABLE_STATEMENT = .{
        .is_declaration = true,
        .name = @constCast("i"),
        .expression = @constCast(&parser.Node{ .EXPRESSION = .{
            .NUMBER = .{ .value = 2 },
        } }),
    } }) } }), @constCast(&parser.Node{ .STATEMENT = .{ .statement = @constCast(&parser.Node{
        .VARIABLE_STATEMENT = .{
            .is_declaration = false,
            .name = @constCast("i"),
            .expression = @constCast(&parser.Node{ .EXPRESSION = .{
                .NUMBER = .{ .value = 2 },
            } }),
        },
    }) } }) }) } };

    var evaluator = try Evaluator.init(std.testing.allocator);
    defer evaluator.deinit();

    const evaluation_result = try evaluator.evaluate_ast(@constCast(ast));

    try std.testing.expectEqual(0, evaluation_result);
}
