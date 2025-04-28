const std = @import("std");

const llvm = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/TargetMachine.h");
    @cInclude("llvm-c/Types.h");
    @cInclude("llvm-c/Analysis.h");
    @cInclude("llvm-c/Target.h");
});

const parser = @import("parser.zig");

pub const CodeGenError = error{
    CompilationError,
    OutOfMemory,
};

pub const CodeGen = struct {
    llvm_module: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    environment: *Environment,

    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) !*CodeGen {
        // Initialize LLVM
        llvm.LLVMInitializeAllTargetInfos();
        llvm.LLVMInitializeAllTargetMCs();
        llvm.LLVMInitializeAllTargets();
        llvm.LLVMInitializeAllAsmPrinters();
        llvm.LLVMInitializeAllAsmParsers();

        const module: llvm.LLVMModuleRef = llvm.LLVMModuleCreateWithName("module");
        const builder = llvm.LLVMCreateBuilder();

        const self = try arena.create(CodeGen);
        self.* = .{
            .llvm_module = module,
            .builder = builder,
            .environment = try Environment.init(arena),

            .arena = arena,
        };

        return self;
    }

    pub fn compile(self: *CodeGen) void {
        // Dump module
        llvm.LLVMDumpModule(self.llvm_module);

        // Generate code
        const triple = llvm.LLVMGetDefaultTargetTriple();
        var target_ref: llvm.LLVMTargetRef = undefined;
        var message: [*c]u8 = undefined;
        var result = llvm.LLVMGetTargetFromTriple(triple, &target_ref, &message);
        if (result != 0) {
            std.debug.print("Target output: {s}.\n", .{message});
            llvm.LLVMDisposeMessage(message.?);
        }
        const target_machine = llvm.LLVMCreateTargetMachine(
            target_ref,
            triple,
            "",
            "",
            llvm.LLVMCodeGenLevelDefault,
            llvm.LLVMRelocDefault,
            llvm.LLVMCodeModelDefault,
        );

        // Generate the object file
        const filename = "output.o";
        _ = llvm.LLVMTargetMachineEmitToFile(
            target_machine,
            self.llvm_module,
            filename,
            llvm.LLVMObjectFile,
            null,
        );
        std.debug.print("Object file generated: {s}\n", .{filename});

        result = llvm.LLVMVerifyModule(self.llvm_module, llvm.LLVMAbortProcessAction, &message);
        if (result != 0) {
            std.debug.print("Verification output: {any}.\n", .{message});
            llvm.LLVMDisposeMessage(message);
        }
    }

    pub fn deinit(self: *CodeGen) void {
        defer llvm.LLVMDisposeBuilder(self.builder);
        llvm.LLVMDisposeModule(self.llvm_module);
        llvm.LLVMShutdown();
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
            .IMPORT_DECLARATION => |*import_declaration| return try self.generate_import_declaration(),
            else => unreachable,
        }
    }

    fn generate_assignment_statement(self: *CodeGen, statement: *parser.Node) CodeGenError!void {
        errdefer std.debug.print("Error generating assignment statement\n", .{});
        std.debug.assert(statement.* == parser.Node.ASSIGNMENT_STATEMENT);
        const assignment_statement = statement.ASSIGNMENT_STATEMENT;

        if (assignment_statement.lhs.* == .PRIMARY_EXPRESSION) {
            const identifier = assignment_statement.lhs.PRIMARY_EXPRESSION.IDENTIFIER;

            if (assignment_statement.is_declaration and self.environment.scope_stack.items.len > 1) {
                std.debug.assert(assignment_statement.is_dereference == false);
                // TODO: vv Int64Type is a problem
                const alloca = llvm.LLVMBuildAlloca(self.builder, llvm.LLVMInt64Type(), try std.fmt.allocPrintZ(self.arena, "{s}", .{identifier.name})); //TODO: Correct type
                try self.environment.add_variable(identifier.name, try self.create_variable(.{
                    .value = alloca,
                    .type = llvm.LLVMVoidType(), // This gets set to the correct type during the expression type resolution. ALTERNATIVE: Pass the alloca
                    .stack_level = null,
                    .node = statement,
                    .node_type = null,
                }));
            }

            var undereferenced_variable: ?*Variable = null;
            if (assignment_statement.is_dereference) {
                const ptr = self.environment.get_variable(identifier.name) orelse unreachable;
                undereferenced_variable = ptr;
                const x = llvm.LLVMBuildLoad2(self.builder, ptr.type, ptr.value, "") orelse return CodeGenError.CompilationError;
                std.debug.assert(ptr.node_type.?.TYPE == .POINTER_TYPE);
                try self.environment.add_variable(identifier.name, try self.create_variable(.{
                    .value = x,
                    .type = ptr.type,
                    .stack_level = null,
                    .node = statement,
                    .node_type = ptr.node_type.?.TYPE.POINTER_TYPE.type,
                }));
            }

            const variable = try self.generate_expression_value(assignment_statement.rhs, identifier.name);

            if (!assignment_statement.is_dereference) {
                try self.environment.add_variable(identifier.name, variable);
            } else {
                try self.environment.add_variable(identifier.name, undereferenced_variable.?);
            }
        } else {
            const xd = assignment_statement.lhs.UNARY_EXPRESSION.expression;
            const a = try self.generate_expression_value(xd, null);
            const variable = try self.generate_expression_value(assignment_statement.rhs, null);
            _ = llvm.LLVMBuildStore(self.builder, variable.value, a.value);
        }
    }

    fn generate_function_call_statement(self: *CodeGen, statement: *parser.Node) CodeGenError!*Variable {
        errdefer std.debug.print("Error generating function call statement\n", .{});
        std.debug.assert(statement.* == parser.Node.FUNCTION_CALL_STATEMENT);
        const function_call_statement = statement.FUNCTION_CALL_STATEMENT;

        var node = statement;

        var function: *Variable = undefined;
        switch (function_call_statement.expression.*) {
            .PRIMARY_EXPRESSION => |primary_expression| {
                std.debug.assert(primary_expression == .IDENTIFIER);
                function = self.environment.get_variable(primary_expression.IDENTIFIER.name) orelse return CodeGenError.CompilationError;
                if (llvm.LLVMGetValueKind(function.value) != llvm.LLVMFunctionValueKind) {
                    function.value = llvm.LLVMBuildLoad2(self.builder, llvm.LLVMPointerType(function.type, 0), function.value, "");
                    node = function.node.?;
                }
            },
            .FUNCTION_DEFINITION => |*function_definition| {
                function = try self.generate_expression_value(@ptrCast(function_definition), null);
            },
            else => unreachable,
        }

        var arguments = std.ArrayList(llvm.LLVMValueRef).init(self.arena);

        for (function_call_statement.arguments) |argument| {
            const arg = try self.generate_expression_value(argument, null);
            try arguments.append(arg.value);
        }

        const res = llvm.LLVMBuildCall2(self.builder, function.type, function.value, @ptrCast(arguments.items), @intCast(arguments.items.len), "") orelse return CodeGenError.CompilationError;

        const function_return_type = switch (function.node.?.*) {
            .FUNCTION_DEFINITION => |x| x.return_type,
            .PRIMARY_EXPRESSION => |x| x.IDENTIFIER.type.?,
            .TYPE => |x| x.FUNCTION_TYPE.return_type,
            else => unreachable,
        };

        const typ = try self.get_llvm_type(function_return_type);

        return self.create_variable(.{
            .type = typ,
            .value = res,
            .stack_level = null,
            .node = node,
            .node_type = function_return_type,
        }) catch return CodeGenError.CompilationError;
    }

    fn generate_return_statement(self: *CodeGen, statement: *parser.Node) !void {
        errdefer std.debug.print("Error generating return statement\n", .{});
        std.debug.assert(statement.* == parser.Node.RETURN_STATEMENT);

        const expression = statement.RETURN_STATEMENT.expression;

        const val = try self.generate_expression_value(expression, null);
        _ = llvm.LLVMBuildRet(self.builder, val.value);
    }

    fn generate_if_statement(self: *CodeGen, statement: *parser.Node) !void {
        errdefer std.debug.print("Error generating if statement\n", .{});
        std.debug.assert(statement.* == parser.Node.IF_STATEMENT);

        const if_statement = statement.IF_STATEMENT;

        const condition_value = try self.generate_expression_value(if_statement.condition, null);

        const current_block = llvm.LLVMGetInsertBlock(self.builder);

        const then_block = llvm.LLVMAppendBasicBlock(llvm.LLVMGetLastFunction(self.llvm_module), "then_block");
        _ = llvm.LLVMPositionBuilderAtEnd(self.builder, then_block);
        for (if_statement.statements) |stmt| {
            try self.generate_statement(stmt);
        }
        const merge_block = llvm.LLVMAppendBasicBlock(llvm.LLVMGetLastFunction(self.llvm_module), "merge_block");
        const last_instr = llvm.LLVMGetLastInstruction(then_block);
        if (llvm.LLVMIsATerminatorInst(last_instr) == null) {
            _ = llvm.LLVMBuildBr(self.builder, merge_block);
        }
        llvm.LLVMPositionBuilderAtEnd(self.builder, current_block);

        _ = llvm.LLVMBuildCondBr(self.builder, condition_value.value, then_block, merge_block);
        llvm.LLVMPositionBuilderAtEnd(self.builder, merge_block);
    }

    fn generate_while_statement(self: *CodeGen, statement: *parser.Node) !void {
        errdefer std.debug.print("Error generating while statement\n", .{});
        std.debug.assert(statement.* == parser.Node.WHILE_STATEMENT);

        const while_statement = statement.WHILE_STATEMENT;

        const while_block = llvm.LLVMAppendBasicBlock(llvm.LLVMGetLastFunction(self.llvm_module), "while_block");
        _ = llvm.LLVMBuildBr(self.builder, while_block);
        _ = llvm.LLVMPositionBuilderAtEnd(self.builder, while_block);
        const condition_value = try self.generate_expression_value(while_statement.condition, null);

        const inner_block = llvm.LLVMAppendBasicBlock(llvm.LLVMGetLastFunction(self.llvm_module), "inner_block");
        const outer_block = llvm.LLVMAppendBasicBlock(llvm.LLVMGetLastFunction(self.llvm_module), "outer_block");
        _ = llvm.LLVMBuildCondBr(self.builder, condition_value.value, inner_block, outer_block);

        _ = llvm.LLVMPositionBuilderAtEnd(self.builder, inner_block);
        for (while_statement.statements) |stmt| {
            try self.generate_statement(stmt);
        }

        _ = llvm.LLVMBuildBr(self.builder, while_block);

        llvm.LLVMPositionBuilderAtEnd(self.builder, outer_block);
    }

    fn generate_expression_value(self: *CodeGen, expression: *parser.Node, name: ?[]const u8) !*Variable {
        errdefer std.debug.print("Error generating statement value\n", .{});
        return switch (expression.*) {
            .FUNCTION_DEFINITION => |function_definition| {

                // Functions should be declared "globally"
                const builder_pos = llvm.LLVMGetInsertBlock(self.builder);

                var paramtypes = std.ArrayList(llvm.LLVMTypeRef).init(self.arena);
                for (function_definition.parameters) |param| {
                    std.debug.assert(param.PRIMARY_EXPRESSION == .IDENTIFIER);
                    var param_type = try self.get_llvm_type(param.PRIMARY_EXPRESSION.IDENTIFIER.type.?);
                    if (param.PRIMARY_EXPRESSION.IDENTIFIER.type.?.TYPE == .FUNCTION_TYPE) {
                        param_type = llvm.LLVMPointerType(param_type.?, 0);
                    }
                    try paramtypes.append(param_type);
                }
                var return_type = try self.get_llvm_type(function_definition.return_type);
                if (function_definition.return_type.TYPE == .FUNCTION_TYPE) {
                    return_type = llvm.LLVMPointerType(return_type, 0);
                }
                const function_type = llvm.LLVMFunctionType(return_type, paramtypes.items.ptr, @intCast(paramtypes.items.len), 0) orelse return CodeGenError.CompilationError;
                const function = llvm.LLVMAddFunction(self.llvm_module, try std.fmt.allocPrintZ(self.arena, "{s}", .{name orelse "unnamed_func"}), function_type) orelse return CodeGenError.CompilationError;
                const function_entry = llvm.LLVMAppendBasicBlock(function, "entrypoint") orelse return CodeGenError.CompilationError;
                llvm.LLVMPositionBuilderAtEnd(self.builder, function_entry);

                try self.environment.create_scope();
                defer self.environment.drop_scope();

                var ptr: ?*Variable = null;

                // Needed for recursive functions
                if (name != null) {
                    ptr = self.environment.get_variable(name.?);
                    try self.environment.add_variable(name.?, try self.create_variable(.{
                        .value = function,
                        .type = function_type,
                        .stack_level = null,
                        .node = expression,
                        .node_type = null,
                    }));
                }

                const params = try self.arena.alloc(llvm.LLVMValueRef, function_definition.parameters.len);
                llvm.LLVMGetParams(function, params.ptr);

                var parameters_index: usize = 0;
                for (params) |p| {
                    defer parameters_index += 1;
                    const param_node = function_definition.parameters[parameters_index];
                    std.debug.assert(param_node.* == .PRIMARY_EXPRESSION);

                    const param_type = try self.get_llvm_type(param_node.PRIMARY_EXPRESSION.IDENTIFIER.type.?);
                    var alloca_param_type = param_type;
                    if (param_node.PRIMARY_EXPRESSION.IDENTIFIER.type.?.TYPE == .FUNCTION_TYPE) {
                        alloca_param_type = llvm.LLVMPointerType(alloca_param_type.?, 0);
                    }
                    // We need to alloca params because we assume all identifiers are alloca TODO:: Is this correct
                    const alloca = llvm.LLVMBuildAlloca(self.builder, alloca_param_type, try std.fmt.allocPrintZ(self.arena, "{s}", .{param_node.PRIMARY_EXPRESSION.IDENTIFIER.name}));
                    _ = llvm.LLVMBuildStore(self.builder, p, alloca);

                    try self.environment.add_variable(param_node.PRIMARY_EXPRESSION.IDENTIFIER.name, try self.create_variable(.{
                        .value = alloca,
                        .type = param_type,
                        .stack_level = null,
                        .node = param_node,
                        .node_type = param_node.PRIMARY_EXPRESSION.IDENTIFIER.type,
                    }));
                }

                for (function_definition.statements) |stmt| {
                    try self.generate_statement(stmt);
                }

                // TODO: This should be done with a defer when `builder_pos` is declared, but for some reason it doesn't work
                llvm.LLVMPositionBuilderAtEnd(self.builder, builder_pos);

                // Global functions
                if (name == null or self.environment.scope_stack.items.len == 2) {
                    return try self.create_variable(.{
                        .value = function,
                        .type = function_type,
                        .stack_level = null,
                        .node = expression,
                        .node_type = null,
                    });
                }

                _ = llvm.LLVMBuildStore(self.builder, function, ptr.?.value) orelse return CodeGenError.CompilationError;
                ptr.?.type = function_type;
                ptr.?.node = expression;

                return ptr.?;
            },
            .FUNCTION_CALL_STATEMENT => |*fn_call| {
                if (name != null) {
                    const ptr = self.environment.get_variable(name.?) orelse unreachable;
                    const result = try self.generate_function_call_statement(@ptrCast(fn_call));
                    _ = llvm.LLVMBuildStore(self.builder, result.value, ptr.value) orelse return CodeGenError.CompilationError;
                    ptr.type = result.type;
                    ptr.node = result.node;
                    ptr.node_type = result.node_type;
                    return ptr;
                } else {
                    return try self.generate_function_call_statement(@ptrCast(fn_call));
                }
            },
            .PRIMARY_EXPRESSION => |primary_expression| switch (primary_expression) {
                .NUMBER => |n| {
                    return try self.generate_literal(llvm.LLVMConstInt(llvm.LLVMInt64Type(), @intCast(n.value), 0), llvm.LLVMInt64Type(), name, expression, try self.create_node(.{
                        .TYPE = .{
                            .SIMPLE_TYPE = .{
                                .name = "i64",
                            },
                        },
                    }));
                },
                .BOOLEAN => |b| {
                    const int_value: i64 = switch (b.value) {
                        false => 0,
                        true => 1,
                    };

                    return try self.generate_literal(llvm.LLVMConstInt(llvm.LLVMInt1Type(), @intCast(int_value), 0), llvm.LLVMInt1Type(), name, expression, try self.create_node(.{
                        .TYPE = .{
                            .SIMPLE_TYPE = .{
                                .name = "i1",
                            },
                        },
                    }));
                },
                .CHAR => |c| {
                    return try self.generate_literal(llvm.LLVMConstInt(llvm.LLVMInt8Type(), @intCast(c.value), 0), llvm.LLVMInt8Type(), name, expression, try self.create_node(.{
                        .TYPE = .{
                            .SIMPLE_TYPE = .{
                                .name = "i8",
                            },
                        },
                    }));
                },
                .STRING => |s| {
                    const x = llvm.LLVMBuildGlobalStringPtr(self.builder, try std.fmt.allocPrintZ(self.arena, "{s}", .{s.value}), "");
                    return self.create_variable(
                        .{
                            .value = x,
                            .type = llvm.LLVMPointerType(llvm.LLVMInt8Type(), 0),
                            .stack_level = null,
                            .node = expression,
                            .node_type = try self.create_node(.{
                                .TYPE = .{
                                    .POINTER_TYPE = .{
                                        .type = try self.create_node(.{
                                            .TYPE = .{ .SIMPLE_TYPE = .{
                                                .name = "i8",
                                            } },
                                        }),
                                    },
                                },
                            }),
                        },
                    );
                },
                .IDENTIFIER => |i| {
                    const variable = self.environment.get_variable(i.name).?;
                    var param_type = variable.type;
                    if (llvm.LLVMGetTypeKind(param_type.?) == llvm.LLVMFunctionTypeKind) {
                        param_type = llvm.LLVMPointerType(param_type.?, 0);
                    }

                    var loaded: llvm.LLVMValueRef = undefined;

                    if (variable.node.?.* == .PRIMARY_EXPRESSION and variable.node.?.PRIMARY_EXPRESSION == .STRING) {
                        loaded = variable.value;
                    } else {
                        loaded = llvm.LLVMBuildLoad2(self.builder, param_type, variable.value, "");
                    }

                    return self.generate_literal(loaded, variable.type, name, expression, variable.node_type);
                },
            },
            .ADDITIVE_EXPRESSION => |exp| {
                const lhs_value = try self.generate_expression_value(exp.lhs, null);
                const rhs_value = try self.generate_expression_value(exp.rhs, null);

                std.debug.assert(lhs_value.node.?.* == .PRIMARY_EXPRESSION);
                std.debug.assert(rhs_value.node.?.* == .PRIMARY_EXPRESSION);

                var result: llvm.LLVMValueRef = undefined;
                var node_type: *parser.Node = try self.create_node(.{ .TYPE = .{ .SIMPLE_TYPE = .{
                    .name = "i64",
                } } });

                if (exp.addition) {
                    if (llvm.LLVMGetTypeKind(lhs_value.type.?) == llvm.LLVMPointerTypeKind) {
                        std.debug.print("DEBUG: {any}\n", .{expression});
                        result = llvm.LLVMBuildGEP2(self.builder, try self.get_llvm_type(lhs_value.node_type.?.TYPE.POINTER_TYPE.type), lhs_value.value, @constCast(&[_]llvm.LLVMValueRef{rhs_value.value}), 1, "");
                        node_type = lhs_value.node_type.?;
                    } else {
                        result = llvm.LLVMBuildAdd(self.builder, lhs_value.value, rhs_value.value, "") orelse return CodeGenError.CompilationError;
                    }
                } else {
                    result = llvm.LLVMBuildSub(self.builder, lhs_value.value, rhs_value.value, "") orelse return CodeGenError.CompilationError;
                }

                return self.generate_literal(result, llvm.LLVMInt64Type(), name, expression, node_type);
            },
            .MULTIPLICATIVE_EXPRESSION => |exp| {
                const lhs_value = try self.generate_expression_value(exp.lhs, null);
                const rhs_value = try self.generate_expression_value(exp.rhs, null);

                var result: llvm.LLVMValueRef = undefined;
                switch (exp.typ) {
                    .MUL => {
                        result = llvm.LLVMBuildMul(self.builder, lhs_value.value, rhs_value.value, "") orelse return CodeGenError.CompilationError;
                    },
                    .DIV => {
                        result = llvm.LLVMBuildSDiv(self.builder, lhs_value.value, rhs_value.value, "") orelse return CodeGenError.CompilationError;
                    },
                    .MOD => {
                        result = llvm.LLVMBuildSRem(self.builder, lhs_value.value, rhs_value.value, "") orelse return CodeGenError.CompilationError;
                    },
                }

                return self.generate_literal(result, llvm.LLVMInt64Type(), name, expression, lhs_value.node_type);
            },
            .UNARY_EXPRESSION => |exp| {
                const k = try self.generate_expression_value(exp.expression, null);

                var r: llvm.LLVMValueRef = undefined;
                var t: llvm.LLVMTypeRef = undefined;
                var uwu: *parser.Node = k.node_type.?;
                switch (exp.typ) {
                    .NOT => {
                        std.debug.assert(k.type == llvm.LLVMInt1Type());
                        r = llvm.LLVMBuildICmp(self.builder, llvm.LLVMIntEQ, k.value, llvm.LLVMConstInt(llvm.LLVMInt1Type(), 0, 0), "");
                        t = llvm.LLVMInt1Type();
                    },
                    .MINUS => {
                        r = llvm.LLVMBuildNeg(self.builder, k.value, "");
                        t = llvm.LLVMInt64Type();
                    },
                    .STAR => {
                        r = llvm.LLVMBuildLoad2(self.builder, k.type, k.value, "");
                        std.debug.print("TEST: {any}\n", .{k.node_type});
                        std.debug.assert(k.node_type.?.TYPE == .POINTER_TYPE);
                        t = try self.get_llvm_type(k.node_type.?.TYPE.POINTER_TYPE.type);
                        uwu = k.node_type.?.TYPE.POINTER_TYPE.type;
                    },
                }

                return self.generate_literal(r, t, name, expression, uwu); //TODO: Why do we need the llvm type at all
            },
            .EQUALITY_EXPRESSION => |exp| {
                const lhs_value = try self.generate_expression_value(exp.lhs, null);
                const rhs_value = try self.generate_expression_value(exp.rhs, null);

                const op: c_uint = switch (exp.typ) {
                    .EQ => llvm.LLVMIntEQ,
                    .LT => llvm.LLVMIntSLT,
                    .GT => llvm.LLVMIntSGT,
                };
                const cmp = llvm.LLVMBuildICmp(self.builder, op, lhs_value.value, rhs_value.value, "");

                return self.generate_literal(cmp, llvm.LLVMInt1Type(), name, expression, lhs_value.node_type);
            },
            .TYPE => |typ| {
                std.debug.assert(typ == .FUNCTION_TYPE);
                const function_type = try self.get_llvm_type(expression);
                const function = llvm.LLVMAddFunction(self.llvm_module, try std.fmt.allocPrintZ(self.arena, "{s}", .{name.?}), function_type);

                // Global functions
                if (self.environment.scope_stack.items.len == 1) {
                    return try self.create_variable(.{
                        .value = function,
                        .type = function_type,
                        .stack_level = null,
                        .node = expression,
                        .node_type = expression,
                    });
                }

                const ptr = self.environment.get_variable(name.?);
                _ = llvm.LLVMBuildStore(self.builder, function, ptr.?.value) orelse return CodeGenError.CompilationError;
                ptr.?.type = function_type;
                ptr.?.node = expression;
                ptr.?.node_type = expression;

                return ptr.?;
            },
            else => unreachable,
        };
    }

    fn generate_literal(self: *CodeGen, literal_val: llvm.LLVMValueRef, literal_type: llvm.LLVMTypeRef, name: ?[]const u8, node: *parser.Node, node_type: ?*parser.Node) !*Variable {
        if (name != null) {
            if (self.environment.scope_stack.items.len == 1) {
                const ptr = try self.create_variable(.{
                    .value = llvm.LLVMAddGlobal(self.llvm_module, literal_type, try std.fmt.allocPrintZ(self.arena, "{s}", .{name.?})),
                    .type = literal_type,
                    .stack_level = null,
                    .node = node,
                    .node_type = node_type,
                });
                llvm.LLVMSetInitializer(ptr.value, literal_val);
                return ptr;
            }
            const ptr = self.environment.get_variable(name.?) orelse unreachable;
            _ = llvm.LLVMBuildStore(self.builder, literal_val, ptr.value) orelse return CodeGenError.CompilationError;
            ptr.type = literal_type;
            ptr.node = node;
            ptr.node_type = node_type;
            return ptr;
        }

        return try self.create_variable(.{
            .value = literal_val,
            .type = literal_type,
            .stack_level = null,
            .node = node,
            .node_type = node_type,
        });
    }

    fn get_llvm_type(self: *CodeGen, node: *parser.Node) !llvm.LLVMTypeRef {
        std.debug.assert(node.* == parser.Node.TYPE);
        const type_node = node.TYPE;

        switch (type_node) {
            .SIMPLE_TYPE => |t| {
                if (std.mem.eql(u8, t.name, "i8")) return llvm.LLVMInt8Type();
                if (std.mem.eql(u8, t.name, "i64")) return llvm.LLVMInt64Type();
                if (std.mem.eql(u8, t.name, "bool")) return llvm.LLVMInt1Type();
                if (std.mem.eql(u8, t.name, "void")) return llvm.LLVMVoidType();
                unreachable;
            },
            // TODO: Properly handle this vv
            .FUNCTION_TYPE => |t| {
                const return_type = try self.get_llvm_type(t.return_type);
                var paramtypes = std.ArrayList(llvm.LLVMTypeRef).init(self.arena);
                var is_varargs: i8 = 0;
                for (t.parameters) |param| {
                    if (param.TYPE == .SIMPLE_TYPE and std.mem.eql(u8, param.TYPE.SIMPLE_TYPE.name, "varargs")) {
                        is_varargs = 1;
                        continue;
                    }
                    try paramtypes.append(try self.get_llvm_type(param));
                }
                const function_type = llvm.LLVMFunctionType(return_type, paramtypes.items.ptr, @intCast(paramtypes.items.len), is_varargs) orelse unreachable;
                return function_type;
            },
            .POINTER_TYPE => |t| {
                const inner_type = try self.get_llvm_type(t.type);
                return llvm.LLVMPointerType(inner_type, 0);
            },
        }
    }

    fn get_underlying_llvm_ptr_type(self: *CodeGen, node: *parser.Node) !llvm.LLVMTypeRef {
        std.debug.assert(node.* == .TYPE);

        switch (node.TYPE) {
            .POINTER_TYPE => |t| {
                return try self.get_underlying_llvm_ptr_type(t.type);
            },
            else => {
                return try self.get_llvm_type(node);
            },
        }
    }

    fn create_variable(self: *CodeGen, variable_value: Variable) !*Variable {
        const variable = try self.arena.create(Variable);
        variable.* = variable_value;
        return variable;
    }

    fn create_node(self: *CodeGen, node_value: parser.Node) !*parser.Node {
        const node = try self.arena.create(parser.Node);
        node.* = node_value;
        return node;
    }
};

const Variable = struct {
    type: llvm.LLVMTypeRef,
    value: llvm.LLVMValueRef,
    node: ?*parser.Node,
    node_type: ?*parser.Node,
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
