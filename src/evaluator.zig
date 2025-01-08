const std = @import("std");
const parser = @import("parser.zig");

pub const Evaluator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Evaluator {
        const evaluator = try allocator.create(Evaluator);
        evaluator.* = .{
            .allocator = allocator,
        };
        return evaluator;
    }

    pub fn deinit(self: *Evaluator) void {
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
        std.debug.assert(statement.* == parser.Node.STATEMENT);

        return switch (statement.STATEMENT.statement.*) {
            .VARIABLE_STATEMENT => |*variable_statement| try self.evaluate_variable_statement(@ptrCast(variable_statement)),
            .PRINT_STATEMENT => |*print_statement| try self.evaluate_print_statement(@ptrCast(print_statement)),
            else => unreachable,
        };
    }

    fn evaluate_variable_statement(_: *Evaluator, variable_statement: *parser.Node) !void {
        std.debug.assert(variable_statement.* == parser.Node.VARIABLE_STATEMENT);
        @panic("evaluate_variable_statement unimplemented");
    }

    fn evaluate_print_statement(self: *Evaluator, print_statement: *parser.Node) !void {
        std.debug.assert(print_statement.* == parser.Node.PRINT_STATEMENT);

        const print_value = try self.get_expression_value(print_statement.PRINT_STATEMENT.expression);

        std.debug.print("PRINT: {d}\n", .{print_value});
    }

    fn get_expression_value(_: *Evaluator, expression: *parser.Node) !i64 {
        std.debug.assert(expression.* == parser.Node.EXPRESSION);

        return switch (expression.EXPRESSION) {
            .NUMBER => |number| number.value,
            .IDENTIFIER => @panic("printing identifiers not implemented"),
        };
    }
};
