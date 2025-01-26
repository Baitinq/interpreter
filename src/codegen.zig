const std = @import("std");
const parser = @import("parser.zig");
const llvm = @import("llvm");
const target_m = llvm.target_machine;
const target = llvm.target;
const types = llvm.types;
const core = llvm.core;

pub const CodeGen = struct {
    llvm_module: types.LLVMModuleRef,

    pub fn init(arena: std.mem.Allocator) !*CodeGen {
        // Initialize LLVM
        _ = target.LLVMInitializeNativeTarget();
        _ = target.LLVMInitializeNativeAsmPrinter();
        _ = target.LLVMInitializeNativeAsmParser();

        const module: types.LLVMModuleRef = core.LLVMModuleCreateWithName("module");

        const self = try arena.create(CodeGen);
        self.* = .{
            .llvm_module = module,
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
        core.LLVMDisposeModule(self.llvm_module);
        core.LLVMShutdown();
    }

    pub fn generate(self: *CodeGen) void {
        const builder = core.LLVMCreateBuilder();
        defer core.LLVMDisposeBuilder(builder);

        const main_func_type = core.LLVMFunctionType(core.LLVMInt32Type(), null, 0, 0);
        const main_func = core.LLVMAddFunction(self.llvm_module, "_start", main_func_type);
        const main_entry = core.LLVMAppendBasicBlock(main_func, "entrypoint");
        core.LLVMPositionBuilderAtEnd(builder, main_entry);

        const format_str = "Hello, World!\n";
        const format_str_ptr = core.LLVMBuildGlobalStringPtr(builder, format_str, "format_str_ptr");

        var print_function_params = [_]types.LLVMTypeRef{
            core.LLVMPointerType(core.LLVMInt8Type(), 0),
        };
        const print_func_type = core.LLVMFunctionType(core.LLVMVoidType(), &print_function_params, print_function_params.len, 0);
        const print_func = core.LLVMAddFunction(self.llvm_module, "printf", print_func_type);
        var print_func_args = [_]types.LLVMValueRef{
            format_str_ptr,
        };
        _ = core.LLVMBuildCall2(builder, print_func_type, print_func, &print_func_args, print_func_args.len, "print_call");

        var exit_func_params = [_]types.LLVMTypeRef{
            core.LLVMInt32Type(),
        };
        const exit_func_type = core.LLVMFunctionType(core.LLVMInt32Type(), &exit_func_params, exit_func_params.len, 0);
        const exit_func = core.LLVMAddFunction(self.llvm_module, "exit", exit_func_type);

        var exit_func_args = [_]types.LLVMValueRef{
            core.LLVMConstInt(core.LLVMInt32Type(), 7, 0),
        };
        const exit_func_ret = core.LLVMBuildCall2(builder, exit_func_type, exit_func, &exit_func_args, exit_func_args.len, "exit_call");
        _ = core.LLVMBuildRet(builder, exit_func_ret);
    }
};
