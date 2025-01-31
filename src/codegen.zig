const std = @import("std");
const parser = @import("parser.zig");
const llvm = @import("llvm");
const target_m = llvm.target_machine;
const target = llvm.target;
const types = llvm.types;
const core = llvm.core;

pub const CodeGenError = error{
    CompilationError,
    OutOfMemory,
};

const Variable = struct {
    type: types.LLVMTypeRef,
    value: types.LLVMValueRef,
};

pub const CodeGen = struct {
    llvm_module: types.LLVMModuleRef,
    builder: types.LLVMBuilderRef,
    environment: *Environment,

    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) !*CodeGen {
        // Initialize LLVM
        _ = target.LLVMInitializeNativeTarget();
        _ = target.LLVMInitializeNativeAsmPrinter();
        _ = target.LLVMInitializeNativeAsmParser();

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
            core.LLVMInt64Type(),
        }), 2, 1);
        const printf_function = core.LLVMAddFunction(self.llvm_module, "printf", printf_function_type) orelse return CodeGenError.CompilationError;

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

        _ = core.LLVMBuildCall2(self.builder, printf_function_type, printf_function, arguments, 2, "") orelse return CodeGenError.CompilationError;
        _ = core.LLVMBuildRetVoid(self.builder);

        try self.environment.add_variable("print", try self.create_variable(.{
            .value = print_function,
            .type = print_function_type,
        }));

        return self;
    }

    pub fn deinit(self: *CodeGen) !void {
        try self.create_entrypoint();

        // Dump module
        core.LLVMDumpModule(self.llvm_module);

        // Generate code
        const triple = target_m.LLVMGetDefaultTargetTriple();
        var target_ref: types.LLVMTargetRef = undefined;
        _ = target_m.LLVMGetTargetFromTriple(triple, &target_ref, null);
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
        std.debug.assert(statement.* == parser.Node.STATEMENT);

        switch (statement.STATEMENT.statement.*) {
            .ASSIGNMENT_STATEMENT => |*assignment_statement| {
                try self.generate_assignment_statement(@ptrCast(assignment_statement));
            },
            .FUNCTION_CALL_STATEMENT => |*function_call_statement| {
                _ = try self.generate_function_call_statement(@ptrCast(function_call_statement));
            },
            .RETURN_STATEMENT => |*return_statement| return try self.generate_return_statement(@ptrCast(return_statement)),
            else => unreachable,
        }
    }

    fn generate_assignment_statement(self: *CodeGen, statement: *parser.Node) CodeGenError!void {
        std.debug.assert(statement.* == parser.Node.ASSIGNMENT_STATEMENT);

        const assignment_statement = statement.ASSIGNMENT_STATEMENT;

        if (!assignment_statement.is_declaration) {
            std.debug.assert(self.environment.contains_variable(assignment_statement.name));
        }

        const variable = try self.generate_expression_value(assignment_statement.expression);
        try self.environment.add_variable(assignment_statement.name, variable);
    }

    fn generate_function_call_statement(self: *CodeGen, statement: *parser.Node) CodeGenError!types.LLVMValueRef {
        std.debug.assert(statement.* == parser.Node.FUNCTION_CALL_STATEMENT);
        const function_call_statement = statement.FUNCTION_CALL_STATEMENT;

        std.debug.assert(function_call_statement.expression.* == parser.Node.PRIMARY_EXPRESSION);
        const primary_expression = function_call_statement.expression.PRIMARY_EXPRESSION;

        std.debug.assert(primary_expression == .IDENTIFIER);
        const ident = primary_expression.IDENTIFIER;
        const xd = self.environment.get_variable(ident.name) orelse return CodeGenError.CompilationError;

        var arguments = std.ArrayList(types.LLVMValueRef).init(self.arena);

        for (function_call_statement.arguments) |argument| {
            const arg = try self.generate_expression_value(argument);
            try arguments.append(arg.value);
        }

        return core.LLVMBuildCall2(self.builder, xd.type, xd.value, @ptrCast(arguments.items), @intCast(arguments.items.len), "") orelse return CodeGenError.CompilationError;
    }

    fn generate_return_statement(self: *CodeGen, statement: *parser.Node) !void {
        std.debug.assert(statement.* == parser.Node.RETURN_STATEMENT);

        const expression = statement.RETURN_STATEMENT.expression;

        _ = core.LLVMBuildRet(self.builder, (try self.generate_expression_value(expression)).value);
    }

    fn generate_expression_value(self: *CodeGen, expression: *parser.Node) !*Variable {
        return switch (expression.*) {
            .FUNCTION_DEFINITION => |function_definition| {
                try self.environment.create_scope();
                defer self.environment.drop_scope();

                // Functions should be declared "globally"
                const builder_pos = core.LLVMGetInsertBlock(self.builder);
                defer core.LLVMPositionBuilderAtEnd(self.builder, builder_pos);

                const function_type = core.LLVMFunctionType(core.LLVMInt64Type(), &[_]types.LLVMTypeRef{}, 0, 0) orelse return CodeGenError.CompilationError;
                const function = core.LLVMAddFunction(self.llvm_module, "", function_type) orelse return CodeGenError.CompilationError;
                const function_entry = core.LLVMAppendBasicBlock(function, "entrypoint") orelse return CodeGenError.CompilationError;
                core.LLVMPositionBuilderAtEnd(self.builder, function_entry);

                for (function_definition.statements) |stmt| {
                    try self.generate_statement(stmt);
                }

                return try self.create_variable(.{
                    .value = function,
                    .type = function_type,
                });
            },
            .FUNCTION_CALL_STATEMENT => |*fn_call| {
                const r = try self.generate_function_call_statement(@ptrCast(fn_call));
                return try self.create_variable(.{
                    .value = r,
                    .type = core.LLVMInt64Type(),
                });
            },
            .PRIMARY_EXPRESSION => |primary_expression| switch (primary_expression) {
                .NUMBER => |n| {
                    // Global variables
                    var variable: types.LLVMValueRef = undefined;
                    if (self.environment.scope_stack.items.len == 1) {
                        variable = core.LLVMConstInt(core.LLVMInt64Type(), @intCast(n.value), 0);
                    } else {
                        const ptr = core.LLVMBuildAlloca(self.builder, core.LLVMInt64Type(), "") orelse return CodeGenError.CompilationError;
                        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(core.LLVMInt64Type(), @intCast(n.value), 0), ptr) orelse return CodeGenError.CompilationError;
                        variable = core.LLVMBuildLoad2(self.builder, core.LLVMInt64Type(), ptr, "") orelse return CodeGenError.CompilationError;
                    }

                    return try self.create_variable(.{
                        .value = variable,
                        .type = core.LLVMInt64Type(),
                    });
                },
                .IDENTIFIER => |i| self.environment.get_variable(i.name).?,
                else => unreachable,
            },
            .ADDITIVE_EXPRESSION => |exp| {
                const lhs_value = try self.generate_expression_value(exp.lhs);
                const rhs_value = try self.generate_expression_value(exp.rhs);

                const xd = core.LLVMBuildAdd(self.builder, lhs_value.value, rhs_value.value, "") orelse return CodeGenError.CompilationError;
                return self.create_variable(.{
                    .value = xd,
                    .type = core.LLVMInt64Type(),
                });
            },
            else => unreachable,
        };
    }

    fn create_entrypoint(self: *CodeGen) CodeGenError!void {
        const start_function_type = core.LLVMFunctionType(core.LLVMInt8Type(), &[_]types.LLVMTypeRef{}, 0, 0) orelse return CodeGenError.CompilationError;
        const start_function = core.LLVMAddFunction(self.llvm_module, "_start", start_function_type) orelse return CodeGenError.CompilationError;
        const start_function_entry = core.LLVMAppendBasicBlock(start_function, "entrypoint") orelse return CodeGenError.CompilationError;
        core.LLVMPositionBuilderAtEnd(self.builder, start_function_entry);

        const main_function = self.environment.get_variable("main") orelse return CodeGenError.CompilationError;
        const main_function_return = core.LLVMBuildCall2(self.builder, main_function.type, main_function.value, &[_]types.LLVMTypeRef{}, 0, "main_call") orelse return CodeGenError.CompilationError;

        const exit_func_type = core.LLVMFunctionType(core.LLVMVoidType(), @constCast(&[_]types.LLVMTypeRef{core.LLVMInt8Type()}), 1, 0);
        const exit_func = core.LLVMAddFunction(self.llvm_module, "exit", exit_func_type);
        _ = core.LLVMBuildCall2(self.builder, exit_func_type, exit_func, @constCast(&[_]types.LLVMValueRef{main_function_return}), 1, "exit_call");
        _ = core.LLVMBuildRetVoid(self.builder);
    }

    fn create_variable(self: *CodeGen, variable_value: Variable) !*Variable {
        const variable = try self.arena.create(Variable);
        variable.* = variable_value;
        return variable;
    }
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
