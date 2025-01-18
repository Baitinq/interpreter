const std = @import("std");
const parser = @import("parser.zig");

const EvaluatorError = error{
    EvaluationError,
    OutOfMemory,
};

const VariableType = enum { NUMBER, FUNCTION_DEFINITION };

const Variable = union(VariableType) {
    NUMBER: i64,
    FUNCTION_DEFINITION: *parser.Node,
};

pub const Evaluator = struct {
    ast: ?*parser.Node,
    environment: *Environment,

    allocator: std.mem.Allocator,

    pub fn init(arena_allocator: *std.heap.ArenaAllocator) !*Evaluator {
        const allocator = arena_allocator.allocator();
        const evaluator = try allocator.create(Evaluator);
        evaluator.* = .{
            .ast = null,
            .environment = try Environment.init(arena_allocator),
            .allocator = allocator,
        };
        return evaluator;
    }

    pub fn evaluate_ast(self: *Evaluator, ast: *parser.Node) !i64 {
        errdefer std.debug.print("Error evaluating AST\n", .{});
        std.debug.assert(ast.* == parser.Node.PROGRAM);

        const program = ast.PROGRAM;

        for (program.statements) |stmt| {
            _ = try self.evaluate_statement(stmt);
        }

        const main = self.environment.get_variable("main") orelse return EvaluatorError.EvaluationError;
        return try self.evaluate_function_definition(main.FUNCTION_DEFINITION, &[_]*parser.Node{});
    }

    fn evaluate_statement(self: *Evaluator, statement: *parser.Node) EvaluatorError!?i64 {
        errdefer std.debug.print("Error evaluating statement\n", .{});
        std.debug.assert(statement.* == parser.Node.STATEMENT);

        switch (statement.STATEMENT.statement.*) {
            .ASSIGNMENT_STATEMENT => |*assignment_statement| {
                try self.evaluate_assignment_statement(@ptrCast(assignment_statement));
                return null;
            },
            .FUNCTION_CALL_STATEMENT => |*function_call_statement| {
                _ = try self.evaluate_function_call_statement(@ptrCast(function_call_statement));
                return null;
            },
            .IF_STATEMENT => |*if_statement| {
                return try self.evaluate_if_statement(@ptrCast(if_statement));
            },
            .RETURN_STATEMENT => |*return_statement| return try self.evaluate_return_statement(@ptrCast(return_statement)),
            else => unreachable,
        }

        return null;
    }

    fn evaluate_assignment_statement(self: *Evaluator, node: *parser.Node) !void {
        errdefer std.debug.print("Error evaluating assignment statement\n", .{});
        std.debug.assert(node.* == parser.Node.ASSIGNMENT_STATEMENT);

        const assignment_statement = node.ASSIGNMENT_STATEMENT;

        //TODO: We should lowercase keys no?
        if (assignment_statement.is_declaration) {
            try self.environment.add_variable(assignment_statement.name, null);
        }

        if (!self.environment.contains_variable(assignment_statement.name)) {
            std.debug.print("Variable not found: {s}\n", .{assignment_statement.name});
            return EvaluatorError.EvaluationError;
        }

        const variable = try self.create_variable(assignment_statement.expression);
        try self.environment.add_variable(assignment_statement.name, variable);
    }

    fn evaluate_function_call_statement(self: *Evaluator, node: *parser.Node) EvaluatorError!i64 {
        errdefer std.debug.print("Error evaluating function call statement\n", .{});
        std.debug.assert(node.* == parser.Node.FUNCTION_CALL_STATEMENT);

        const function_call_statement = node.FUNCTION_CALL_STATEMENT;

        // Print function implementation
        if (std.mem.eql(u8, function_call_statement.name, "print")) {
            std.debug.assert(function_call_statement.arguments.len == 1);
            std.debug.print("PRINT: {any}\n", .{try self.get_expression_value(function_call_statement.arguments[0])});
            return 0;
        }

        const function_definition = self.environment.get_variable(function_call_statement.name) orelse return EvaluatorError.EvaluationError;

        return self.evaluate_function_definition(function_definition.FUNCTION_DEFINITION, function_call_statement.arguments);
    }

    fn evaluate_if_statement(self: *Evaluator, node: *parser.Node) !?i64 {
        errdefer std.debug.print("Error evaluating if statement\n", .{});
        std.debug.assert(node.* == parser.Node.IF_STATEMENT);

        const if_statement = node.IF_STATEMENT;

        const if_condition_val = try self.get_expression_value(if_statement.condition);

        if (if_condition_val != 0) return null;

        if (try self.evaluate_block_statements(if_statement.statements)) |ret| return ret;

        return null;
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
                        const val = self.environment.get_variable(identifier.name) orelse {
                            std.debug.print("Identifier {any} not found\n", .{identifier.name});
                            return EvaluatorError.EvaluationError;
                        };

                        return val.NUMBER;
                    },
                    else => unreachable,
                }
            },
            // I don't like having 2 places where we evaluate functions
            .FUNCTION_CALL_STATEMENT => return try self.evaluate_function_call_statement(node),

            else => unreachable,
        }
    }

    fn evaluate_function_definition(self: *Evaluator, node: *parser.Node, arguments: []*parser.Node) EvaluatorError!i64 {
        errdefer std.debug.print("Error evaluating function definition\n", .{});
        std.debug.assert(node.* == parser.Node.FUNCTION_DEFINITION);

        const function_definition = node.*.FUNCTION_DEFINITION;

        try self.environment.create_scope();
        defer self.environment.drop_scope();

        std.debug.assert(function_definition.parameters.len == arguments.len);

        var i: usize = 0;
        while (i < arguments.len) : (i += 1) {
            const parameter = function_definition.parameters[i];
            const argument = arguments[i];

            try self.environment.add_variable(parameter.PRIMARY_EXPRESSION.IDENTIFIER.name, try self.create_variable(argument));
        }

        if (try self.evaluate_block_statements(function_definition.statements)) |ret| return ret;

        // We should never get here as there should be a return statement
        return EvaluatorError.EvaluationError;
    }

    fn evaluate_block_statements(self: *Evaluator, statements: []*parser.Node) !?i64 {
        var i: usize = 0;
        while (i < statements.len) : (i += 1) {
            const stmt = statements[i];
            const res = try self.evaluate_statement(stmt);
            if (res != null) return res.?;
        }
        return null;
    }

    fn create_variable(self: *Evaluator, node: *parser.Node) !*Variable {
        const variable = try self.allocator.create(Variable);
        if (node.* == parser.Node.FUNCTION_DEFINITION) {
            variable.* = .{
                .FUNCTION_DEFINITION = node,
            };
        } else {
            const val = try self.get_expression_value(node);
            variable.* = .{
                .NUMBER = val,
            };
        }

        return variable;
    }
};

const Scope = struct {
    variables: std.StringHashMap(?*Variable),
};

const Environment = struct {
    scope_stack: std.ArrayList(*Scope),

    allocator: std.mem.Allocator,

    fn init(arena_allocator: *std.heap.ArenaAllocator) !*Environment {
        const allocator = arena_allocator.allocator();
        const self = try allocator.create(Environment);

        self.* = .{
            .scope_stack = std.ArrayList(*Scope).init(allocator),
            .allocator = allocator,
        };

        //TODO: Add more scopes when evaluating functions
        // Create global scope
        try self.create_scope();

        return self;
    }

    fn create_scope(self: *Environment) !void {
        const scope = try self.allocator.create(Scope);
        scope.* = .{
            .variables = std.StringHashMap(?*Variable).init(self.allocator),
        };
        try self.scope_stack.append(scope);
    }

    fn drop_scope(self: *Environment) void {
        _ = self.scope_stack.pop();
    }

    fn add_variable(self: *Environment, name: []const u8, variable: ?*Variable) !void {
        try self.scope_stack.getLast().variables.put(name, variable);
    }

    fn get_variable(self: *Environment, name: []const u8) ?*Variable {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            const scope = self.scope_stack.items[i];
            if (scope.variables.get(name)) |v| return v;
        }
        return null;
    }

    fn contains_variable(self: *Environment, name: []const u8) bool {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            const scope = self.scope_stack.items[i];
            if (scope.variables.contains(name)) return true;
        }
        return false;
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
