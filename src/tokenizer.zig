pub const Tokenizer = struct {
    buf: []u8,
    offset: u32,

    pub fn init(buf: []u8) !Tokenizer {
        return Tokenizer{ .buf = buf, .offset = 0 };
    }

    pub fn next(_: *Tokenizer) ?Token {
        return Token.HI;
    }
};

pub const Token = enum {
    HI,
};
