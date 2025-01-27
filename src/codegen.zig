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

pub const CodeGen = struct {
    llvm_module: types.LLVMModuleRef,
    builder: types.LLVMBuilderRef,

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

            .arena = arena,
        };

        const printf_function_type = core.LLVMFunctionType(core.LLVMVoidType(), @constCast(&[_]types.LLVMTypeRef{
            core.LLVMPointerType(core.LLVMInt8Type(), 0),
            core.LLVMInt64Type(),
        }), 2, 0);
        _ = core.LLVMAddFunction(self.llvm_module, "printf", printf_function_type) orelse return CodeGenError.CompilationError;

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

        //tmp
        std.debug.assert(assignment_statement.is_declaration == true);
        std.debug.assert(assignment_statement.expression.* == parser.Node.FUNCTION_DEFINITION);

        const function_name = try std.fmt.allocPrintZ(self.arena, "{s}", .{assignment_statement.name});

        const function_type = core.LLVMFunctionType(core.LLVMInt64Type(), &[_]types.LLVMTypeRef{}, 0, 0) orelse return CodeGenError.CompilationError;
        const function = core.LLVMAddFunction(self.llvm_module, function_name, function_type) orelse return CodeGenError.CompilationError;
        const function_entry = core.LLVMAppendBasicBlock(function, "entrypoint") orelse return CodeGenError.CompilationError;
        core.LLVMPositionBuilderAtEnd(self.builder, function_entry);

        //tmp
        std.debug.assert(assignment_statement.expression.* == parser.Node.FUNCTION_DEFINITION);
        const function_defintion = assignment_statement.expression.FUNCTION_DEFINITION;

        for (function_defintion.statements) |stmt| {
            try self.generate_statement(stmt);
        }
    }

    fn generate_function_call_statement(self: *CodeGen, statement: *parser.Node) !void {
        std.debug.assert(statement.* == parser.Node.FUNCTION_CALL_STATEMENT);
        const function_call_statement = statement.FUNCTION_CALL_STATEMENT;

        std.debug.assert(function_call_statement.expression.* == parser.Node.PRIMARY_EXPRESSION);
        const primary_expression = function_call_statement.expression.PRIMARY_EXPRESSION;

        std.debug.assert(primary_expression == .IDENTIFIER);
        const ident = primary_expression.IDENTIFIER;

        std.debug.assert(function_call_statement.arguments.len == 1);
        const argument = function_call_statement.arguments[0];
        std.debug.assert(argument.* == .PRIMARY_EXPRESSION);
        std.debug.assert(argument.PRIMARY_EXPRESSION == .NUMBER);
        const num_argument = argument.PRIMARY_EXPRESSION.NUMBER;

        const function_name = try std.fmt.allocPrintZ(self.arena, "{s}", .{ident.name});
        const function = core.LLVMGetNamedFunction(self.llvm_module, function_name) orelse return CodeGenError.CompilationError;

        const format_str = "%d\n";
        const format_str_ptr = core.LLVMBuildGlobalStringPtr(self.builder, format_str, "format_str_ptr");

        // TODO: Can we get the type from the function name?
        const fucntion_type = core.LLVMFunctionType(core.LLVMVoidType(), @constCast(&[_]types.LLVMTypeRef{
            core.LLVMPointerType(core.LLVMInt8Type(), 0),
            core.LLVMInt64Type(),
        }), 2, 0);

        const arguments = @constCast(&[_]types.LLVMValueRef{ format_str_ptr, core.LLVMConstInt(core.LLVMInt64Type(), @intCast(num_argument.value), 0) });

        _ = core.LLVMBuildCall2(self.builder, fucntion_type, function, arguments, 2, "function_call") orelse return CodeGenError.CompilationError;
    }

    fn generate_return_statement(self: *CodeGen, statement: *parser.Node) !void {
        std.debug.assert(statement.* == parser.Node.RETURN_STATEMENT);

        const expression = statement.RETURN_STATEMENT.expression;
        std.debug.assert(expression.* == parser.Node.PRIMARY_EXPRESSION);
        const primary_expr = expression.PRIMARY_EXPRESSION.NUMBER.value;
        // std.debug.assert(primary_expr == parser.Node.PRIMARY_EXPRESSION.NUMBER);

        _ = core.LLVMBuildRet(self.builder, core.LLVMConstInt(core.LLVMInt64Type(), @intCast(primary_expr), 0));
    }

    pub fn create_entrypoint(self: *CodeGen) CodeGenError!void {
        const start_function_type = core.LLVMFunctionType(core.LLVMInt8Type(), &[_]types.LLVMTypeRef{}, 0, 0) orelse return CodeGenError.CompilationError;
        const start_function = core.LLVMAddFunction(self.llvm_module, "_start", start_function_type) orelse return CodeGenError.CompilationError;
        const start_function_entry = core.LLVMAppendBasicBlock(start_function, "entrypoint") orelse return CodeGenError.CompilationError;
        core.LLVMPositionBuilderAtEnd(self.builder, start_function_entry);

        const main_function_type = core.LLVMFunctionType(core.LLVMInt8Type(), &[_]types.LLVMTypeRef{}, 0, 0) orelse return CodeGenError.CompilationError;
        const main_function = core.LLVMGetNamedFunction(self.llvm_module, "main") orelse return CodeGenError.CompilationError;
        const main_function_return = core.LLVMBuildCall2(self.builder, main_function_type, main_function, &[_]types.LLVMTypeRef{}, 0, "main_call") orelse return CodeGenError.CompilationError;

        const exit_func_type = core.LLVMFunctionType(core.LLVMInt8Type(), @constCast(&[_]types.LLVMTypeRef{core.LLVMInt8Type()}), 1, 0);
        const exit_func = core.LLVMAddFunction(self.llvm_module, "exit", exit_func_type);
        const exit_func_return = core.LLVMBuildCall2(self.builder, exit_func_type, exit_func, @constCast(&[_]types.LLVMValueRef{main_function_return}), 1, "exit_call");
        _ = core.LLVMBuildRet(self.builder, exit_func_return);
    }

    pub fn generate_poc(self: *CodeGen) void {
        const main_func_type = core.LLVMFunctionType(core.LLVMInt32Type(), null, 0, 0);
        const main_func = core.LLVMAddFunction(self.llvm_module, "_start", main_func_type);
        const main_entry = core.LLVMAppendBasicBlock(main_func, "entrypoint");
        core.LLVMPositionBuilderAtEnd(self.builder, main_entry);

        const format_str = "Hello, World!\n";
        const format_str_ptr = core.LLVMBuildGlobalStringPtr(self.builder, format_str, "format_str_ptr");

        var print_function_params = [_]types.LLVMTypeRef{
            core.LLVMPointerType(core.LLVMInt8Type(), 0),
        };
        const print_func_type = core.LLVMFunctionType(core.LLVMVoidType(), &print_function_params, print_function_params.len, 0);
        const print_func = core.LLVMAddFunction(self.llvm_module, "printf", print_func_type);
        var print_func_args = [_]types.LLVMValueRef{
            format_str_ptr,
        };
        _ = core.LLVMBuildCall2(self.builder, print_func_type, print_func, &print_func_args, print_func_args.len, "print_call");

        var exit_func_params = [_]types.LLVMTypeRef{
            core.LLVMInt32Type(),
        };
        const exit_func_type = core.LLVMFunctionType(core.LLVMInt32Type(), &exit_func_params, exit_func_params.len, 0);
        const exit_func = core.LLVMAddFunction(self.llvm_module, "exit", exit_func_type);

        var exit_func_args = [_]types.LLVMValueRef{
            core.LLVMConstInt(core.LLVMInt32Type(), 7, 0),
        };
        const exit_func_ret = core.LLVMBuildCall2(self.builder, exit_func_type, exit_func, &exit_func_args, exit_func_args.len, "exit_call");
        _ = core.LLVMBuildRet(self.builder, exit_func_ret);
    }
};
