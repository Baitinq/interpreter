const std = @import("std");

const llvm = @import("llvm");
const target_m = llvm.target_machine;
const target = llvm.target;
const types = llvm.types;
const core = llvm.core;
const analysis = llvm.analysis;

const parser = @import("parser.zig");

pub const CodeGenError = error{
    CompilationError,
    OutOfMemory,
};

pub const CodeGen = struct {
    llvm_module: types.LLVMModuleRef,
    builder: types.LLVMBuilderRef,
    environment: *Environment,

    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) !*CodeGen {
        // Initialize LLVM
        target.LLVMInitializeAllTargetInfos();
        target.LLVMInitializeAllTargetMCs();
        target.LLVMInitializeAllTargets();
        target.LLVMInitializeAllAsmPrinters();
        target.LLVMInitializeAllAsmParsers();

        const module: types.LLVMModuleRef = core.LLVMModuleCreateWithName("module");
        const builder = core.LLVMCreateBuilder();

        const self = try arena.create(CodeGen);
        self.* = .{
            .llvm_module = module,
            .builder = builder,
            .environment = try Environment.init(arena),

            .arena = arena,
        };

        const printf_function_type = core.LLVMFunctionType(core.LLVMVoidType(), @constCast(&[_]types.LLVMTypeRef{
            core.LLVMPointerType(core.LLVMInt8Type(), 0),
        }), 1, 1);
        const printf_function = core.LLVMAddFunction(self.llvm_module, "printf", printf_function_type) orelse return CodeGenError.CompilationError;
        try self.environment.add_variable("printf", try self.create_variable(.{
            .value = printf_function,
            .type = printf_function_type,
            .stack_level = null,
        }));

        try self.create_print_function();
        try self.create_printb_function();

        return self;
    }

    pub fn deinit(self: *CodeGen) !void {
        // Dump module
        core.LLVMDumpModule(self.llvm_module);

        // Generate code
        const triple = target_m.LLVMGetDefaultTargetTriple();
        var target_ref: types.LLVMTargetRef = undefined;
        var message: ?[*c]u8 = undefined;
        const xd = target_m.LLVMGetTargetFromTriple(triple, &target_ref, &message.?);
        std.debug.print("XD: {any}.\n", .{xd});
        // std.debug.print("Target output: {any}.\n", .{message});
        // core.LLVMDisposeMessage(message);
        const target_machine = target_m.LLVMCreateTargetMachine(
            target_ref,
            triple,
            "",
            "",
            types.LLVMCodeGenOptLevel.LLVMCodeGenLevelDefault,
            types.LLVMRelocMode.LLVMRelocDefault,
            types.LLVMCodeModel.LLVMCodeModelDefault,
        );

        // Generate the object file
        const filename = "output.o";
        _ = target_m.LLVMTargetMachineEmitToFile(
            target_machine,
            self.llvm_module,
            filename,
            types.LLVMCodeGenFileType.LLVMObjectFile,
            null,
        );
        std.debug.print("Object file generated: {s}\n", .{filename});

        _ = analysis.LLVMVerifyModule(self.llvm_module, types.LLVMVerifierFailureAction.LLVMAbortProcessAction, &message.?);
        // std.debug.print("Verification output: {any}.\n", .{message});
        // core.LLVMDisposeMessage(message);

        // Clean up LLVM resources
        defer core.LLVMDisposeBuilder(self.builder);
        core.LLVMDisposeModule(self.llvm_module);
        core.LLVMShutdown();
    }

    pub fn generate(self: *CodeGen, ast: *parser.Node) CodeGenError!void {
        std.debug.assert(ast.* == parser.Node.PROGRAM);

        const program = ast.PROGRAM;

        for (program.statements) |stmt| {
            _ = try self.generate_statement(stmt);
        }
    }

    fn generate_statement(self: *CodeGen, statement: *parser.Node) CodeGenError!void {
        errdefer std.debug.print("Error generating statement\n", .{});
        std.debug.assert(statement.* == parser.Node.STATEMENT);

        switch (statement.STATEMENT.statement.*) {
            .ASSIGNMENT_STATEMENT => |*assignment_statement| {
                try self.generate_assignment_statement(@ptrCast(assignment_statement));
            },
            .FUNCTION_CALL_STATEMENT => |*function_call_statement| {
                _ = try self.generate_function_call_statement(@ptrCast(function_call_statement));
            },
            .RETURN_STATEMENT => |*return_statement| return try self.generate_return_statement(@ptrCast(return_statement)),
            .IF_STATEMENT => |*if_statement| return try self.generate_if_statement(@ptrCast(if_statement)),
            .WHILE_STATEMENT => |*while_statement| return try self.generate_while_statement(@ptrCast(while_statement)),
            else => unreachable,
        }
    }

    fn generate_assignment_statement(self: *CodeGen, statement: *parser.Node) CodeGenError!void {
        errdefer std.debug.print("Error generating assignment statement\n", .{});
        std.debug.assert(statement.* == parser.Node.ASSIGNMENT_STATEMENT);

        const assignment_statement = statement.ASSIGNMENT_STATEMENT;

        if (assignment_statement.is_declaration and self.environment.scope_stack.items.len > 1) {
            // TODO: vv Int64Type is a problem
            const alloca = core.LLVMBuildAlloca(self.builder, core.LLVMInt64Type(), try std.fmt.allocPrintZ(self.arena, "{s}", .{assignment_statement.name})); //TODO: Correct type
            try self.environment.add_variable(assignment_statement.name, try self.create_variable(.{
                .value = alloca,
                .type = core.LLVMVoidType(), // This gets set to the correct type during the expression type resolution. ALTERNATIVE: Pass the alloca
                .stack_level = null,
            }));
        }

        const variable = try self.generate_expression_value(assignment_statement.expression, assignment_statement.name);
        try self.environment.add_variable(assignment_statement.name, variable);
    }

    fn generate_function_call_statement(self: *CodeGen, statement: *parser.Node) CodeGenError!types.LLVMValueRef {
        errdefer std.debug.print("Error generating function call statement\n", .{});
        std.debug.assert(statement.* == parser.Node.FUNCTION_CALL_STATEMENT);
        const function_call_statement = statement.FUNCTION_CALL_STATEMENT;

        var function: *Variable = undefined;
        switch (function_call_statement.expression.*) {
            .PRIMARY_EXPRESSION => |primary_expression| {
                std.debug.assert(primary_expression == .IDENTIFIER);
                function = self.environment.get_variable(primary_expression.IDENTIFIER.name) orelse return CodeGenError.CompilationError;
                if (core.LLVMGetValueKind(function.value) != types.LLVMValueKind.LLVMFunctionValueKind) {
                    function.value = core.LLVMBuildLoad2(self.builder, core.LLVMPointerType(function.type, 0), function.value, "");
                }
            },
            .FUNCTION_DEFINITION => |*function_definition| {
                function = try self.generate_expression_value(@ptrCast(function_definition), null);
            },
            else => unreachable,
        }

        var arguments = std.ArrayList(types.LLVMValueRef).init(self.arena);

        for (function_call_statement.arguments) |argument| {
            const arg = try self.generate_expression_value(argument, null);
            try arguments.append(arg.value);
        }

        return core.LLVMBuildCall2(self.builder, function.type, function.value, @ptrCast(arguments.items), @intCast(arguments.items.len), "") orelse return CodeGenError.CompilationError;
    }

    fn generate_return_statement(self: *CodeGen, statement: *parser.Node) !void {
        errdefer std.debug.print("Error generating return statement\n", .{});
        std.debug.assert(statement.* == parser.Node.RETURN_STATEMENT);

        const expression = statement.RETURN_STATEMENT.expression;

        const val = try self.generate_expression_value(expression, null);
        _ = core.LLVMBuildRet(self.builder, val.value);
    }

    fn generate_if_statement(self: *CodeGen, statement: *parser.Node) !void {
        errdefer std.debug.print("Error generating if statement\n", .{});
        std.debug.assert(statement.* == parser.Node.IF_STATEMENT);

        const if_statement = statement.IF_STATEMENT;

        const condition_value = try self.generate_expression_value(if_statement.condition, null);

        const current_block = core.LLVMGetInsertBlock(self.builder);

        const then_block = core.LLVMAppendBasicBlock(core.LLVMGetLastFunction(self.llvm_module), "then_block");
        _ = core.LLVMPositionBuilderAtEnd(self.builder, then_block);
        for (if_statement.statements) |stmt| {
            try self.generate_statement(stmt);
        }
        const merge_block = core.LLVMAppendBasicBlock(core.LLVMGetLastFunction(self.llvm_module), "else_block");
        const last_instr = core.LLVMGetLastInstruction(then_block);
        if (core.LLVMIsATerminatorInst(last_instr) == null) {
            _ = core.LLVMBuildBr(self.builder, merge_block);
        }
        core.LLVMPositionBuilderAtEnd(self.builder, current_block);

        _ = core.LLVMBuildCondBr(self.builder, condition_value.value, then_block, merge_block);
        core.LLVMPositionBuilderAtEnd(self.builder, merge_block);
    }

    fn generate_while_statement(self: *CodeGen, statement: *parser.Node) !void {
        errdefer std.debug.print("Error generating while statement\n", .{});
        std.debug.assert(statement.* == parser.Node.WHILE_STATEMENT);

        const while_statement = statement.WHILE_STATEMENT;

        const while_block = core.LLVMAppendBasicBlock(core.LLVMGetLastFunction(self.llvm_module), "while_block");
        _ = core.LLVMBuildBr(self.builder, while_block);
        _ = core.LLVMPositionBuilderAtEnd(self.builder, while_block);
        const condition_value = try self.generate_expression_value(while_statement.condition, null);

        const inner_block = core.LLVMAppendBasicBlock(core.LLVMGetLastFunction(self.llvm_module), "inner_block");
        const outer_block = core.LLVMAppendBasicBlock(core.LLVMGetLastFunction(self.llvm_module), "outer_block");
        _ = core.LLVMBuildCondBr(self.builder, condition_value.value, inner_block, outer_block);

        _ = core.LLVMPositionBuilderAtEnd(self.builder, inner_block);
        for (while_statement.statements) |stmt| {
            try self.generate_statement(stmt);
        }
        const last_instr = core.LLVMGetLastInstruction(inner_block);
        if (core.LLVMIsATerminatorInst(last_instr) == null) {
            _ = core.LLVMBuildBr(self.builder, while_block);
        }

        core.LLVMPositionBuilderAtEnd(self.builder, outer_block);
    }

    fn generate_expression_value(self: *CodeGen, expression: *parser.Node, name: ?[]const u8) !*Variable {
        errdefer std.debug.print("Error generating statement value\n", .{});
        return switch (expression.*) {
            .FUNCTION_DEFINITION => |function_definition| {

                // Functions should be declared "globally"
                const builder_pos = core.LLVMGetInsertBlock(self.builder);

                var paramtypes = std.ArrayList(types.LLVMTypeRef).init(self.arena);
                for (function_definition.parameters) |param| {
                    std.debug.assert(param.PRIMARY_EXPRESSION == .IDENTIFIER);
                    var param_type = try self.get_llvm_type(param.PRIMARY_EXPRESSION.IDENTIFIER.type.?);
                    if (param.PRIMARY_EXPRESSION.IDENTIFIER.type.?.TYPE == .FUNCTION_TYPE) {
                        param_type = core.LLVMPointerType(param_type.?, 0);
                    }
                    try paramtypes.append(param_type);
                }
                const return_type = try self.get_llvm_type(function_definition.return_type);
                const function_type = core.LLVMFunctionType(return_type, paramtypes.items.ptr, @intCast(paramtypes.items.len), 0) orelse return CodeGenError.CompilationError;
                const function = core.LLVMAddFunction(self.llvm_module, try std.fmt.allocPrintZ(self.arena, "{s}", .{name orelse "unnamed_func"}), function_type) orelse return CodeGenError.CompilationError;
                const function_entry = core.LLVMAppendBasicBlock(function, "entrypoint") orelse return CodeGenError.CompilationError;
                core.LLVMPositionBuilderAtEnd(self.builder, function_entry);

                try self.environment.create_scope();
                defer self.environment.drop_scope();

                const ptr = self.environment.get_variable(name.?);

                // Needed for recursive functions
                if (name != null) {
                    try self.environment.add_variable(name.?, try self.create_variable(.{
                        .value = function,
                        .type = function_type,
                        .stack_level = null,
                    }));
                }

                const params = try self.arena.alloc(types.LLVMValueRef, function_definition.parameters.len);
                core.LLVMGetParams(function, params.ptr);

                var parameters_index: usize = 0;
                for (params) |p| {
                    defer parameters_index += 1;
                    const param_node = function_definition.parameters[parameters_index];
                    std.debug.assert(param_node.* == .PRIMARY_EXPRESSION);

                    const param_type = try self.get_llvm_type(param_node.PRIMARY_EXPRESSION.IDENTIFIER.type.?);
                    var alloca_param_type = param_type;
                    if (param_node.PRIMARY_EXPRESSION.IDENTIFIER.type.?.TYPE == .FUNCTION_TYPE) {
                        alloca_param_type = core.LLVMPointerType(alloca_param_type.?, 0);
                    }
                    // We need to alloca params because we assume all identifiers are alloca TODO:: Is this correct
                    const alloca = core.LLVMBuildAlloca(self.builder, alloca_param_type, try std.fmt.allocPrintZ(self.arena, "{s}", .{param_node.PRIMARY_EXPRESSION.IDENTIFIER.name}));
                    _ = core.LLVMBuildStore(self.builder, p, alloca);

                    try self.environment.add_variable(param_node.PRIMARY_EXPRESSION.IDENTIFIER.name, try self.create_variable(.{
                        .value = alloca,
                        .type = param_type,
                        .stack_level = null,
                    }));
                }

                for (function_definition.statements) |stmt| {
                    try self.generate_statement(stmt);
                }

                // TODO: This should be done with a defer when `builder_pos` is declared, but for some reason it doesn't work
                core.LLVMPositionBuilderAtEnd(self.builder, builder_pos);

                // Global functions
                if (self.environment.scope_stack.items.len == 2) {
                    return try self.create_variable(.{
                        .value = function,
                        .type = function_type,
                        .stack_level = null,
                    });
                }

                _ = core.LLVMBuildStore(self.builder, function, ptr.?.value) orelse return CodeGenError.CompilationError;
                ptr.?.type = function_type;
                return ptr.?;
            },
            .FUNCTION_CALL_STATEMENT => |*fn_call| {
                if (name != null) {
                    const ptr = self.environment.get_variable(name.?) orelse unreachable;
                    const result = try self.generate_function_call_statement(@ptrCast(fn_call));
                    _ = core.LLVMBuildStore(self.builder, result, ptr.value) orelse return CodeGenError.CompilationError;
                    ptr.type = core.LLVMInt64Type();
                    return ptr;
                } else {
                    const r = try self.generate_function_call_statement(@ptrCast(fn_call));
                    return try self.create_variable(.{
                        .value = r,
                        .type = core.LLVMInt64Type(),
                        .stack_level = null,
                    });
                }
            },
            .PRIMARY_EXPRESSION => |primary_expression| switch (primary_expression) {
                .NUMBER => |n| {
                    return try self.generate_literal(core.LLVMConstInt(core.LLVMInt64Type(), @intCast(n.value), 0), core.LLVMInt64Type(), name);
                },
                .BOOLEAN => |b| {
                    const int_value: i64 = switch (b.value) {
                        false => 0,
                        true => 1,
                    };

                    return try self.generate_literal(core.LLVMConstInt(core.LLVMInt1Type(), @intCast(int_value), 0), core.LLVMInt1Type(), name);
                },
                .IDENTIFIER => |i| {
                    const variable = self.environment.get_variable(i.name).?;
                    var param_type = variable.type;
                    if (core.LLVMGetTypeKind(param_type.?) == types.LLVMTypeKind.LLVMFunctionTypeKind) {
                        param_type = core.LLVMPointerType(param_type.?, 0);
                    }
                    const loaded = core.LLVMBuildLoad2(self.builder, param_type, variable.value, "");

                    return self.generate_literal(loaded, variable.type, name);
                },
            },
            .ADDITIVE_EXPRESSION => |exp| {
                const lhs_value = try self.generate_expression_value(exp.lhs, null);
                const rhs_value = try self.generate_expression_value(exp.rhs, null);

                var result: types.LLVMValueRef = undefined;
                if (exp.addition) {
                    result = core.LLVMBuildAdd(self.builder, lhs_value.value, rhs_value.value, "") orelse return CodeGenError.CompilationError;
                } else {
                    result = core.LLVMBuildSub(self.builder, lhs_value.value, rhs_value.value, "") orelse return CodeGenError.CompilationError;
                }

                return self.generate_literal(result, core.LLVMInt64Type(), name);
            },
            .MULTIPLICATIVE_EXPRESSION => |exp| {
                const lhs_value = try self.generate_expression_value(exp.lhs, null);
                const rhs_value = try self.generate_expression_value(exp.rhs, null);

                var result: types.LLVMValueRef = undefined;
                switch (exp.typ) {
                    .MUL => {
                        result = core.LLVMBuildMul(self.builder, lhs_value.value, rhs_value.value, "") orelse return CodeGenError.CompilationError;
                    },
                    .DIV => {
                        result = core.LLVMBuildSDiv(self.builder, lhs_value.value, rhs_value.value, "") orelse return CodeGenError.CompilationError;
                    },
                    .MOD => {
                        result = core.LLVMBuildSRem(self.builder, lhs_value.value, rhs_value.value, "") orelse return CodeGenError.CompilationError;
                    },
                }

                return self.generate_literal(result, core.LLVMInt64Type(), name);
            },
            .UNARY_EXPRESSION => |exp| {
                const k = try self.generate_expression_value(exp.expression, null);

                var r: types.LLVMValueRef = undefined;
                var t: types.LLVMTypeRef = undefined;
                switch (exp.negation) {
                    true => {
                        std.debug.assert(k.type == core.LLVMInt1Type());
                        r = core.LLVMBuildICmp(self.builder, types.LLVMIntPredicate.LLVMIntEQ, k.value, core.LLVMConstInt(core.LLVMInt1Type(), 0, 0), "");
                        t = core.LLVMInt1Type();
                    },
                    false => {
                        r = core.LLVMBuildNeg(self.builder, k.value, "");
                        t = core.LLVMInt64Type();
                    },
                }

                return self.generate_literal(r, t, name);
            },
            .EQUALITY_EXPRESSION => |exp| {
                const lhs_value = try self.generate_expression_value(exp.lhs, null);
                const rhs_value = try self.generate_expression_value(exp.rhs, null);

                const op = switch (exp.typ) {
                    .EQ => types.LLVMIntPredicate.LLVMIntEQ,
                    .LT => types.LLVMIntPredicate.LLVMIntSLT,
                    .GT => types.LLVMIntPredicate.LLVMIntSGT,
                };
                const cmp = core.LLVMBuildICmp(self.builder, op, lhs_value.value, rhs_value.value, "");

                return self.generate_literal(cmp, core.LLVMInt1Type(), name);
            },
            else => unreachable,
        };
    }

    fn generate_literal(self: *CodeGen, literal_val: types.LLVMValueRef, literal_type: types.LLVMTypeRef, name: ?[]const u8) !*Variable {
        if (name != null) {
            if (self.environment.scope_stack.items.len == 1) {
                const ptr = try self.create_variable(.{
                    .value = core.LLVMAddGlobal(self.llvm_module, literal_type, try std.fmt.allocPrintZ(self.arena, "{s}", .{name.?})),
                    .type = literal_type,
                    .stack_level = null,
                });
                core.LLVMSetInitializer(ptr.value, literal_val);
                return ptr;
            }
            const ptr = self.environment.get_variable(name.?) orelse unreachable;
            _ = core.LLVMBuildStore(self.builder, literal_val, ptr.value) orelse return CodeGenError.CompilationError;
            ptr.type = literal_type;
            return ptr;
        }

        return try self.create_variable(.{
            .value = literal_val,
            .type = literal_type,
            .stack_level = null,
        });
    }

    fn get_llvm_type(self: *CodeGen, node: *parser.Node) !types.LLVMTypeRef {
        std.debug.assert(node.* == parser.Node.TYPE);
        const type_node = node.TYPE;

        switch (type_node) {
            .SIMPLE_TYPE => |t| {
                if (std.mem.eql(u8, t.name, "i64")) return core.LLVMInt64Type();
                if (std.mem.eql(u8, t.name, "bool")) return core.LLVMInt1Type();
                unreachable;
            },
            // TODO: Properly handle this vv
            .FUNCTION_TYPE => |t| {
                const return_type = try self.get_llvm_type(t.return_type);
                var paramtypes = std.ArrayList(types.LLVMTypeRef).init(self.arena);
                for (t.parameters) |param| {
                    try paramtypes.append(try self.get_llvm_type(param));
                }
                const function_type = core.LLVMFunctionType(return_type, paramtypes.items.ptr, @intCast(paramtypes.items.len), 0) orelse unreachable;
                return function_type;
            },
        }
    }

    fn create_print_function(self: *CodeGen) !void {
        const print_function_type = core.LLVMFunctionType(core.LLVMVoidType(), @constCast(&[_]types.LLVMTypeRef{core.LLVMInt64Type()}), 1, 0);
        const print_function = core.LLVMAddFunction(self.llvm_module, "print", print_function_type);
        const print_function_entry = core.LLVMAppendBasicBlock(print_function, "entrypoint") orelse return CodeGenError.CompilationError;
        core.LLVMPositionBuilderAtEnd(self.builder, print_function_entry);

        const format_str = "%d\n";
        const format_str_ptr = core.LLVMBuildGlobalStringPtr(self.builder, format_str, "format_str_ptr");

        const arguments = @constCast(&[_]types.LLVMValueRef{
            format_str_ptr,
            core.LLVMGetParam(print_function, 0),
        });

        const printf_function_var = self.environment.get_variable("printf") orelse return CodeGenError.CompilationError;

        _ = core.LLVMBuildCall2(self.builder, printf_function_var.type, printf_function_var.value, arguments, 2, "") orelse return CodeGenError.CompilationError;
        _ = core.LLVMBuildRetVoid(self.builder);

        try self.environment.add_variable("print", try self.create_variable(.{
            .value = print_function,
            .type = print_function_type,
            .stack_level = null,
        }));
    }

    fn create_printb_function(self: *CodeGen) !void {
        const print_function_type = core.LLVMFunctionType(core.LLVMVoidType(), @constCast(&[_]types.LLVMTypeRef{core.LLVMInt1Type()}), 1, 0);
        const print_function = core.LLVMAddFunction(self.llvm_module, "printb", print_function_type);
        const print_function_entry = core.LLVMAppendBasicBlock(print_function, "entrypoint") orelse return CodeGenError.CompilationError;
        core.LLVMPositionBuilderAtEnd(self.builder, print_function_entry);

        const format_str = "%d\n";
        const format_str_ptr = core.LLVMBuildGlobalStringPtr(self.builder, format_str, "format_str_ptr");

        const p = core.LLVMGetParam(print_function, 0);
        const x = core.LLVMBuildZExt(self.builder, p, core.LLVMInt64Type(), "");

        const arguments = @constCast(&[_]types.LLVMValueRef{
            format_str_ptr,
            x,
        });

        const printf_function_var = self.environment.get_variable("printf") orelse return CodeGenError.CompilationError;

        _ = core.LLVMBuildCall2(self.builder, printf_function_var.type, printf_function_var.value, arguments, 2, "") orelse return CodeGenError.CompilationError;
        _ = core.LLVMBuildRetVoid(self.builder);

        try self.environment.add_variable("printb", try self.create_variable(.{
            .value = print_function,
            .type = print_function_type,
            .stack_level = null,
        }));
    }

    fn create_variable(self: *CodeGen, variable_value: Variable) !*Variable {
        const variable = try self.arena.create(Variable);
        variable.* = variable_value;
        return variable;
    }
};

const Variable = struct {
    type: types.LLVMTypeRef,
    value: types.LLVMValueRef,
    stack_level: ?usize,
};

const Scope = struct {
    variables: std.StringHashMap(*Variable),
};

const Environment = struct {
    scope_stack: std.ArrayList(*Scope),

    arena: std.mem.Allocator,

    fn init(arena_allocator: std.mem.Allocator) !*Environment {
        const self = try arena_allocator.create(Environment);

        self.* = .{
            .scope_stack = std.ArrayList(*Scope).init(arena_allocator),
            .arena = arena_allocator,
        };

        // Create global scope
        try self.create_scope();

        return self;
    }

    fn create_scope(self: *Environment) !void {
        const scope = try self.arena.create(Scope);
        scope.* = .{
            .variables = std.StringHashMap(*Variable).init(self.arena),
        };
        try self.scope_stack.append(scope);
    }

    fn drop_scope(self: *Environment) void {
        _ = self.scope_stack.pop();
    }

    fn add_variable(self: *Environment, name: []const u8, variable: *Variable) !void {
        try self.scope_stack.getLast().variables.put(name, variable);
    }

    fn get_variable(self: *Environment, name: []const u8) ?*Variable {
        var i = self.scope_stack.items.len;
        var variable: ?*Variable = null;
        while (i > 0) {
            i -= 1;
            const scope = self.scope_stack.items[i];
            if (scope.variables.get(name)) |v| {
                if (variable == null) {
                    variable = v;
                }
                variable.?.stack_level = i;
            }
        }
        return variable;
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
