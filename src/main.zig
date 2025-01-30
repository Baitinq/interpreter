const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser = @import("parser.zig");
const evaluator = @import("evaluator.zig");
const codegen = @import("codegen.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    const pathLen = std.mem.len(std.os.argv[1]);
    const path = std.os.argv[1][0..pathLen];

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("Memory leak detected!");
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source_evaluator = try evaluator.Evaluator.init(arena.allocator());
    const source_codegen = try codegen.CodeGen.init(arena.allocator());
    defer source_codegen.deinit() catch |err| {
        std.debug.print("ERROR GENERATING CODE {any}\n", .{err});
    };

    if (std.mem.eql(u8, path, "-i")) {
        while (true) {
            try stdout.print("> ", .{});

            const buf = try stdin.readUntilDelimiterAlloc(allocator, '\n', 1024);
            defer allocator.free(buf);

            process_buf(buf, allocator, arena.allocator(), source_evaluator, null) catch |err| {
                try stdout.print("Error processing line: {any}\n", .{err});
            };
        }
    } else {
        std.debug.print("Tokenizing! {s}\n", .{path});
        const file = try std.fs.cwd().openFile(path, .{});
        const buf = try file.readToEndAlloc(allocator, 1 * 1024 * 1024);
        defer allocator.free(buf);
        if (std.os.argv.len < 3) {
            try process_buf(
                buf,
                allocator,
                arena.allocator(),
                source_evaluator,
                null,
            );
        } else try process_buf(
            buf,
            allocator,
            arena.allocator(),
            source_evaluator,
            source_codegen,
        );
    }
}

fn process_buf(buf: []u8, allocator: std.mem.Allocator, arena: std.mem.Allocator, source_evaluator: *evaluator.Evaluator, source_codegen: ?*codegen.CodeGen) !void {
    std.debug.print("Buf:\n{s}\n", .{buf});

    var token_list = std.ArrayList(tokenizer.Token).init(allocator);
    defer token_list.deinit();

    var source_tokenizer = try tokenizer.Tokenizer.init(buf);
    while (try source_tokenizer.next()) |token| {
        std.debug.print("{any}\n", .{token});
        try token_list.append(token);
    }

    const source_parser = try parser.Parser.init(token_list.items, arena);
    const ast = try source_parser.parse();
    std.debug.print("AST: {any}\n", .{ast});

    if (source_codegen != null) {
        try source_codegen.?.generate(ast);
    } else {
        const result = try source_evaluator.evaluate_ast(ast);
        std.debug.print("Evaluation result: {any}\n", .{result});
    }
}

test {
    std.testing.refAllDecls(@This());
}
