const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser = @import("parser.zig");
const evaluator = @import("evaluator.zig");

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

    // const source_evaluator = try evaluator.Evaluator.init(allocator);
    // defer source_evaluator.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    if (std.mem.eql(u8, path, "-i")) {
        while (true) {
            try stdout.print("> ", .{});

            const buf = try stdin.readUntilDelimiterAlloc(allocator, '\n', 1024);
            defer allocator.free(buf);

            process_buf(buf, allocator, &arena) catch |err| {
                try stdout.print("Error processing line: {any}\n", .{err});
            };
        }
    } else {
        std.debug.print("Tokenizing! {s}\n", .{path});
        const file = try std.fs.cwd().openFile(path, .{});
        const buf = try file.readToEndAlloc(allocator, 1 * 1024 * 1024);
        defer allocator.free(buf);
        try process_buf(buf, allocator, &arena);
    }
}

fn process_buf(buf: []u8, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator) !void {
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

    // const result = try source_evaluator.evaluate_ast(ast);
    // std.debug.print("Evaluation result: {any}\n", .{result});
}

test {
    std.testing.refAllDecls(@This());
}
