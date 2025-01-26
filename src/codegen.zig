const std = @import("std");
const parser = @import("parser.zig");
const llvm = @import("llvm");
const target_m = llvm.target_machine;
const target = llvm.target;
const types = llvm.types;
const core = llvm.core;

pub const CodeGen = struct {
    llvm_module: types.LLVMModuleRef,
    builder: types.LLVMBuilderRef,

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
        };

        return self;
    }

    pub fn deinit(self: *CodeGen) void {
        // Generate code
        const triple = target_m.LLVMGetDefaultTargetTriple();
        var target_ref: types.LLVMTargetRef = undefined;
        _ = target_m.LLVMGetTargetFromTriple(triple, &target_ref, null);
        const target_machine = target_m.LLVMCreateTargetMachine(
            target_ref,
            triple,
            "generic",
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

    pub fn generate(self: *CodeGen, ast: *parser.Node) !void {
        std.debug.assert(ast.* == parser.Node.PROGRAM);

        const program = ast.PROGRAM;

        for (program.statements) |stmt| {
            _ = try self.generate_statement(stmt);
        }
    }

    fn generate_statement(self: *CodeGen, statement: *parser.Node) !void {
        std.debug.assert(statement.* == parser.Node.STATEMENT);

        switch (statement.STATEMENT.statement.*) {
            // .ASSIGNMENT_STATEMENT => |*assignment_statement| {
            //     try self.evaluate_assignment_statement(@ptrCast(assignment_statement));
            //     return null;
            // },
            // .FUNCTION_CALL_STATEMENT => |*function_call_statement| {
            //     _ = try self.evaluate_function_call_statement(@ptrCast(function_call_statement));
            //     return null;
            // },
            .RETURN_STATEMENT => |*return_statement| return try self.generate_return_statement(@ptrCast(return_statement)),
            else => unreachable,
        }

        return null;
    }

    fn generate_return_statement(self: *CodeGen, statement: *parser.Node) !void {
        std.debug.assert(statement.* == parser.Node.RETURN_STATEMENT);

        // const return_value = statement.RETURN_STATEMENT.return_value;

        _ = core.LLVMBuildRet(self.builder, core.LLVMConstInt(core.LLVMInt32Type(), 12, 0));
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
