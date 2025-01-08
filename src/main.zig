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

    if (std.mem.eql(u8, path, "-i")) {
        while (true) {
            try stdout.print("> ", .{});

            const buf = try stdin.readUntilDelimiterAlloc(allocator, '\n', 1024);
            defer allocator.free(buf);

            process_buf(buf, allocator) catch |err| {
                try stdout.print("Error parsing line: {any}\n", .{err});
            };
        }
    } else {
        std.debug.print("Tokenizing! {s}\n", .{path});
        const file = try std.fs.cwd().openFile(path, .{});
        const buf = try file.readToEndAlloc(allocator, 1 * 1024 * 1024);
        defer allocator.free(buf);
        try process_buf(buf, allocator);
    }
}

fn process_buf(buf: []u8, allocator: std.mem.Allocator) !void {
    std.debug.print("Buf:\n{s}\n", .{buf});

    var token_list = std.ArrayList(tokenizer.Token).init(allocator);
    defer token_list.deinit();

    var source_tokenizer = try tokenizer.Tokenizer.init(buf);
    while (source_tokenizer.next()) |token| {
        try token_list.append(token);
    }

    for (token_list.items) |token| {
        std.debug.print("{any}\n", .{token});
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    const source_parser = try parser.Parser.init(token_list.items, arena.allocator());
    defer arena.deinit();
    const ast = try source_parser.parse();
    std.debug.print("AST: {any}\n", .{ast});

    const source_evaluator = try evaluator.Evaluator.init(allocator);
    defer source_evaluator.deinit();
    const result = try source_evaluator.evaluate_ast(ast);
    std.debug.print("Evaluation result: {any}\n", .{result});
}

test {
    std.testing.refAllDecls(@This());
}
