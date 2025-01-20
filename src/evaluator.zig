const std = @import("std");
const parser = @import("parser.zig");

const EvaluatorError = error{
    EvaluationError,
    OutOfMemory,
};

const VariableType = enum { NUMBER, BOOLEAN, FUNCTION_DEFINITION };

const Variable = union(VariableType) {
    NUMBER: i64,
    BOOLEAN: bool,
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
        const ret = try self.evaluate_function_definition(main.FUNCTION_DEFINITION, &[_]*parser.Node{});
        return ret.?.NUMBER;
    }

    fn evaluate_statement(self: *Evaluator, statement: *parser.Node) EvaluatorError!?*Variable {
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

        const variable = try self.get_expression_value(assignment_statement.expression);
        try self.environment.add_variable(assignment_statement.name, variable);
    }

    fn evaluate_function_call_statement(self: *Evaluator, node: *parser.Node) EvaluatorError!?*Variable {
        errdefer std.debug.print("Error evaluating function call statement\n", .{});
        std.debug.assert(node.* == parser.Node.FUNCTION_CALL_STATEMENT);

        const function_call_statement = node.FUNCTION_CALL_STATEMENT;

        // Print function implementation
        if (std.mem.eql(u8, function_call_statement.name, "print")) {
            std.debug.assert(function_call_statement.arguments.len == 1);
            std.debug.print("PRINT: {any}\n", .{try self.get_expression_value(function_call_statement.arguments[0])});
            return null;
        }

        const function_definition = self.environment.get_variable(function_call_statement.name) orelse return EvaluatorError.EvaluationError;

        return self.evaluate_function_definition(function_definition.FUNCTION_DEFINITION, function_call_statement.arguments);
    }

    fn evaluate_if_statement(self: *Evaluator, node: *parser.Node) !?*Variable {
        errdefer std.debug.print("Error evaluating if statement\n", .{});
        std.debug.assert(node.* == parser.Node.IF_STATEMENT);

        const if_statement = node.IF_STATEMENT;

        const if_condition_val = try self.get_expression_value(if_statement.condition);

        std.debug.assert(if_condition_val.?.* == .BOOLEAN);

        if (!if_condition_val.?.BOOLEAN) return null;

        if (try self.evaluate_block_statements(if_statement.statements)) |ret| return ret;

        return null;
    }

    fn evaluate_return_statement(self: *Evaluator, return_statement: *parser.Node) !*Variable {
        errdefer std.debug.print("Error evaluating return statement\n", .{});
        std.debug.assert(return_statement.* == parser.Node.RETURN_STATEMENT);

        const return_value = try self.get_expression_value(return_statement.RETURN_STATEMENT.expression);

        return return_value.?;
    }

    fn get_expression_value(self: *Evaluator, node: *parser.Node) !?*Variable {
        errdefer std.debug.print("Error getting statement value\n", .{});

        switch (node.*) {
            .ADDITIVE_EXPRESSION => |x| {
                const lhs = try self.get_expression_value(x.lhs) orelse return EvaluatorError.EvaluationError;
                const rhs = try self.get_expression_value(x.rhs) orelse return EvaluatorError.EvaluationError;
                std.debug.assert(lhs.* == .NUMBER and rhs.* == .NUMBER);
                if (x.addition) return try self.create_variable(.{ .NUMBER = lhs.NUMBER + rhs.NUMBER });
                return try self.create_variable(.{ .NUMBER = lhs.NUMBER - rhs.NUMBER });
            },
            .UNARY_EXPRESSION => |x| {
                const val = try self.get_expression_value(x.expression) orelse return EvaluatorError.EvaluationError;
                std.debug.assert(val.* == .BOOLEAN);
                return try self.create_variable(.{ .BOOLEAN = !val.BOOLEAN });
            },
            .EQUALITY_EXPRESSION => |x| {
                const lhs = try self.get_expression_value(x.lhs) orelse return EvaluatorError.EvaluationError;
                const rhs = try self.get_expression_value(x.rhs) orelse return EvaluatorError.EvaluationError;
                std.debug.assert(lhs.* == .NUMBER and rhs.* == .NUMBER); //TODO: Generic
                return try self.create_variable(.{ .BOOLEAN = (lhs.NUMBER == rhs.NUMBER) });
            },
            .PRIMARY_EXPRESSION => |x| {
                switch (x) {
                    .NUMBER => |number| return self.create_variable(.{ .NUMBER = number.value }),
                    .BOOLEAN => |b| return self.create_variable(.{ .BOOLEAN = b.value }),
                    .IDENTIFIER => |identifier| {
                        const val = self.environment.get_variable(identifier.name) orelse {
                            std.debug.print("Identifier {any} not found\n", .{identifier.name});
                            return EvaluatorError.EvaluationError;
                        };

                        return val;
                    },
                    else => unreachable,
                }
            },
            // I don't like having 2 places where we evaluate functions
            .FUNCTION_CALL_STATEMENT => return try self.evaluate_function_call_statement(node),
            .FUNCTION_DEFINITION => return try self.create_variable(.{
                .FUNCTION_DEFINITION = node,
            }),

            else => unreachable,
        }
    }

    fn evaluate_function_definition(self: *Evaluator, node: *parser.Node, arguments: []*parser.Node) EvaluatorError!?*Variable {
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

            try self.environment.add_variable(parameter.PRIMARY_EXPRESSION.IDENTIFIER.name, try self.get_expression_value(argument));
        }

        if (try self.evaluate_block_statements(function_definition.statements)) |ret| return ret;

        // We should never get here as there should be a return statement
        return EvaluatorError.EvaluationError;
    }

    fn evaluate_block_statements(self: *Evaluator, statements: []*parser.Node) !?*Variable {
        var i: usize = 0;
        while (i < statements.len) : (i += 1) {
            const stmt = statements[i];
            const res = try self.evaluate_statement(stmt);
            if (res != null) return res.?;
        }
        return null;
    }

    fn create_variable(self: *Evaluator, variable_value: Variable) !*Variable {
        const variable = try self.allocator.create(Variable);
        variable.* = variable_value;
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
