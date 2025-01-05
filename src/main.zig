const std = @import("std");
const tokenizer = @import("tokenizer.zig");

pub fn main() !void {
    const pathLen = std.mem.len(std.os.argv[1]);
    const path = std.os.argv[1][0..pathLen];
    std.debug.print("Tokenizing! {s}\n", .{path});

    const file = try std.fs.cwd().openFile(path, .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("Memory leak detected!");
    }

    const buf = try file.readToEndAlloc(allocator, 1 * 1024 * 1024);
    defer allocator.free(buf);

    var tknizer = try tokenizer.Tokenizer.init(buf);
    std.debug.print("Next: {any}\n", .{tknizer.next()});
}
