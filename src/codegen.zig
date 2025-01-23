const std = @import("std");
const parser = @import("parser.zig");
const llvm = @import("llvm");
const target_m = llvm.target_machine;
const target = llvm.target;
const types = llvm.types;
const core = llvm.core;

pub const CodeGen = struct {
    pub fn generate() void {
        // Initialize LLVM
        _ = target.LLVMInitializeNativeTarget();
        _ = target.LLVMInitializeNativeAsmPrinter();
        _ = target.LLVMInitializeNativeAsmParser();

        // Create a new LLVM module
        const module: types.LLVMModuleRef = core.LLVMModuleCreateWithName("sum_module");
        var params: [2]types.LLVMTypeRef = [_]types.LLVMTypeRef{
            core.LLVMInt32Type(),
            core.LLVMInt32Type(),
        };

        var exit_params: [1]types.LLVMTypeRef = [_]types.LLVMTypeRef{
            core.LLVMInt32Type(),
        };
        const exit_func_type: types.LLVMTypeRef = core.LLVMFunctionType(core.LLVMInt32Type(), &exit_params, 1, 0);
        const exit_func: types.LLVMValueRef = core.LLVMAddFunction(module, "exit", exit_func_type);

        // Create a function that computes the sum of two integers
        const func_type: types.LLVMTypeRef = core.LLVMFunctionType(core.LLVMInt32Type(), &params, 2, 0);
        const sum_func: types.LLVMValueRef = core.LLVMAddFunction(module, "main", func_type);
        const entry: types.LLVMBasicBlockRef = core.LLVMAppendBasicBlock(sum_func, "entry");
        const builder: types.LLVMBuilderRef = core.LLVMCreateBuilder();
        core.LLVMPositionBuilderAtEnd(builder, entry);
        const arg1: types.LLVMValueRef = core.LLVMGetParam(sum_func, 0);
        const arg2: types.LLVMValueRef = core.LLVMGetParam(sum_func, 1);
        const sum: types.LLVMValueRef = core.LLVMBuildAdd(builder, arg1, arg2, "sum");
        const exit_status: types.LLVMValueRef = core.LLVMConstInt(core.LLVMInt32Type(), 7, 0);
        var exit_args: [1]types.LLVMValueRef = undefined;
        exit_args[0] = exit_status;
        _ = core.LLVMBuildCall2(builder, exit_func_type, exit_func, &exit_args, 1, "exit_call");
        _ = core.LLVMBuildRet(builder, sum);

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
            module,
            filename,
            types.LLVMCodeGenFileType.LLVMObjectFile,
            null,
        );
        std.debug.print("Object file generated: {s}\n", .{filename});

        // Clean up LLVM resources
        core.LLVMDisposeBuilder(builder);
        core.LLVMDisposeModule(module);
        core.LLVMShutdown();
    }
};
