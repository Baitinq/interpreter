const std = @import("std");
const parser = @import("parser.zig");

const EvaluatorError = error{
    EvaluationError,
    OutOfMemory,
};

const VariableType = enum { NUMBER, FUNCTION };

const Variable = union(VariableType) {
    NUMBER: i64,
    FUNCTION: *parser.Node,
};

pub const Evaluator = struct {
    ast: ?*parser.Node,
    variables: std.StringHashMap(?*Variable),
    //TODO: CREATE STACK WITH SCOPES AND WE CAN SEARCH UP SCOPES

    allocator: std.mem.Allocator,

    pub fn init(arena_allocator: *std.heap.ArenaAllocator) !*Evaluator {
        const allocator = arena_allocator.allocator();
        const evaluator = try allocator.create(Evaluator);
        evaluator.* = .{
            .ast = null,
            .variables = std.StringHashMap(?*Variable).init(allocator),
            .allocator = allocator,
        };
        return evaluator;
    }

    pub fn evaluate_ast(self: *Evaluator, ast: *parser.Node) !i64 {
        errdefer std.debug.print("Error evaluating AST\n", .{});
        std.debug.assert(ast.* == parser.Node.PROGRAM);

        const program = ast.PROGRAM;

        for (program.statements) |stmt| {
            try self.evaluate_statement(stmt);
        }

        const main = self.variables.get("main") orelse return EvaluatorError.EvaluationError;
        return try self.evaluate_function_definition(main.?.FUNCTION);
    }

    fn evaluate_statement(self: *Evaluator, statement: *parser.Node) EvaluatorError!void {
        errdefer std.debug.print("Error evaluating statement\n", .{});
        std.debug.assert(statement.* == parser.Node.STATEMENT);

        return switch (statement.STATEMENT.statement.*) {
            .ASSIGNMENT_STATEMENT => |*assignment_statement| try self.evaluate_assignment_statement(@ptrCast(assignment_statement)),
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

        if (assignment_statement.expression.* == parser.Node.FUNCTION_DEFINITION) {
            try self.variables.put(assignment_statement.name, try self.create_variable(.{
                .FUNCTION = assignment_statement.expression,
            }));
        } else {
            const val = try self.get_expression_value(assignment_statement.expression);
            try self.variables.put(assignment_statement.name, try self.create_variable(.{
                .NUMBER = val,
            }));
        }
    }

    fn evaluate_function_call_statement(self: *Evaluator, node: *parser.Node) !i64 {
        errdefer std.debug.print("Error evaluating function call statement\n", .{});
        std.debug.assert(node.* == parser.Node.FUNCTION_CALL_STATEMENT);

        const function_call_statement = node.FUNCTION_CALL_STATEMENT;

        // Print function implementation
        if (std.mem.eql(u8, function_call_statement.name, "print")) {
            std.debug.assert(function_call_statement.arguments.len == 1);
            std.debug.print("PRINT: {any}\n", .{try self.get_expression_value(function_call_statement.arguments[0])});
            return 0;
        }

        const val = self.variables.get(function_call_statement.name) orelse return EvaluatorError.EvaluationError;

        return self.evaluate_function_definition(val.?.FUNCTION); //TODO: Pass arguments to this
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

                        return val.?.NUMBER;
                    },
                    else => unreachable,
                }
            },
            .FUNCTION_CALL_STATEMENT => |x| {
                const func = self.variables.get(x.name) orelse return EvaluatorError.EvaluationError;

                return try self.evaluate_function_definition(func.?.FUNCTION);
            },

            else => unreachable,
        }
    }

    fn evaluate_function_definition(self: *Evaluator, node: *parser.Node) EvaluatorError!i64 {
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

    fn create_variable(self: *Evaluator, variable_value: Variable) !*Variable {
        const variable = try self.allocator.create(Variable);
        variable.* = variable_value;
        return variable;
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
