const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const parser = @import("parser.zig");

pub fn main() !void {
    const pathLen = std.mem.len(std.os.argv[1]);
    const path = std.os.argv[1][0..pathLen];
    std.debug.print("Tokenizing! {s}\n", .{path});

    //TODO: Repl mode

    const file = try std.fs.cwd().openFile(path, .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("Memory leak detected!");
    }

    const buf = try file.readToEndAlloc(allocator, 1 * 1024 * 1024);
    defer allocator.free(buf);

    std.debug.print("Buf:\n{s}\n", .{buf});

    var token_list = std.ArrayList(tokenizer.Token).init(allocator);
    defer token_list.deinit();

    var sourceTokenizer = try tokenizer.Tokenizer.init(buf);
    while (sourceTokenizer.next()) |token| {
        try token_list.append(token);
    }

    for (token_list.items) |token| {
        std.debug.print("{any}\n", .{token});
    }

    const ast = try parser.Parser.init(token_list.items).parse();
    std.debug.print("AST: {any}\n", .{ast});
}

test {
    std.testing.refAllDecls(@This());
}
