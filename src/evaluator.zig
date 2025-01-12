const std = @import("std");
const parser = @import("parser.zig");

const EvaluatorError = error{
    EvaluationError,
    OutOfMemory,
};

pub const Evaluator = struct {
    variables: std.StringHashMap(?*parser.Node),

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
        std.debug.assert(ast.* == parser.Node.PROGRAM);

        const program = ast.*.PROGRAM;

        for (program.statements) |statement| {
            try self.evaluate_statement(statement);
        }

        return 0;
    }

    fn evaluate_statement(self: *Evaluator, statement: *parser.Node) !void {
        errdefer std.debug.print("Error evaluating statement\n", .{});
        std.debug.assert(statement.* == parser.Node.STATEMENT);

        return switch (statement.STATEMENT.statement.*) {
            .VARIABLE_STATEMENT => |*variable_statement| try self.evaluate_variable_statement(@ptrCast(variable_statement)),
            .PRINT_STATEMENT => |*print_statement| try self.evaluate_print_statement(@ptrCast(print_statement)),
            else => unreachable,
        };
    }

    fn evaluate_variable_statement(self: *Evaluator, node: *parser.Node) !void {
        errdefer std.debug.print("Error evaluating variable statement\n", .{});
        std.debug.assert(node.* == parser.Node.VARIABLE_STATEMENT);

        const variable_statement = node.VARIABLE_STATEMENT;

        //TODO: We should lowercase keys no?
        if (variable_statement.is_declaration) {
            try self.variables.put(variable_statement.name, null);
        }

        // Make sure identifier exists
        _ = try self.get_expression_value(node.VARIABLE_STATEMENT.expression);

        if (!self.variables.contains(variable_statement.name)) {
            std.debug.print("Variable not found: {s}\n", .{variable_statement.name});
            return EvaluatorError.EvaluationError;
        }

        try self.variables.put(variable_statement.name, node.VARIABLE_STATEMENT.expression); //TODO: We really should enforce this at the compiler level.
    }

    fn evaluate_print_statement(self: *Evaluator, print_statement: *parser.Node) !void {
        errdefer std.debug.print("Error evaluating print statement\n", .{});
        std.debug.assert(print_statement.* == parser.Node.PRINT_STATEMENT);

        const print_value = try self.get_expression_value(print_statement.PRINT_STATEMENT.expression);

        std.debug.print("PRINT: {d}\n", .{print_value});
    }

    fn get_expression_value(self: *Evaluator, node: *parser.Node) !i64 {
        errdefer std.debug.print("Error getting statement value\n", .{});
        std.debug.assert(node.* == parser.Node.EXPRESSION);

        return switch (node.EXPRESSION) {
            .NUMBER => |number| number.value,
            .IDENTIFIER => |identifier| {
                const expression = self.variables.get(identifier.name) orelse {
                    std.debug.print("Identifier {any} not found\n", .{identifier.name});
                    return EvaluatorError.EvaluationError;
                };

                return try self.get_expression_value(expression orelse return EvaluatorError.EvaluationError);
            },
            .BINARY => |operation| {
                //TODO: For now, this just represents sum
                const lhs = try self.get_expression_value(operation.lhs);
                const rhs = try self.get_expression_value(operation.rhs);
                return lhs + rhs;
            },
        };
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
