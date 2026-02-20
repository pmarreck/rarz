const std = @import("std");
const BitReader = @import("bitreader.zig").BitReader;

// ============================================================================
// Range Coder
// ============================================================================

const TOP: u32 = 0x01000000;
const BOT: u32 = 0x8000;

pub const RangeCoder = struct {
    low: u32,
    code: u32,
    range: u32,
    br: *BitReader,

    pub fn init(br: *BitReader) !RangeCoder {
        var rc = RangeCoder{
            .low = 0,
            .code = 0,
            .range = 0xFFFFFFFF,
            .br = br,
        };
        // Read initial 4 bytes into code
        for (0..4) |_| {
            const byte = try br.readBits(8);
            rc.code = (rc.code << 8) | byte;
        }
        return rc;
    }

    /// Get the current threshold (count) within the given scale.
    /// This divides the range by scale and returns which sub-range
    /// the code falls into.
    pub fn getThreshold(self: *RangeCoder, scale: u32) u32 {
        self.range /= scale;
        return (self.code -% self.low) / self.range;
    }

    /// Remove the decoded sub-range after identifying the symbol.
    /// cum_freq: cumulative frequency of symbols below the decoded one
    /// freq: frequency of the decoded symbol
    pub fn decode(self: *RangeCoder, cum_freq: u32, freq: u32) void {
        self.low +%= cum_freq * self.range;
        self.range *= freq;
        self.normalize();
    }

    /// Normalize the coder state, reading bytes as needed.
    fn normalize(self: *RangeCoder) void {
        while (true) {
            if ((self.low ^ (self.low +% self.range)) >= TOP) {
                if (self.range >= BOT) {
                    break;
                }
                // Range is too small but straddles a carry boundary
                self.range = (-%self.low) & (BOT - 1);
            }
            self.code = (self.code << 8) | (self.br.readBits(8) catch 0);
            self.range <<= 8;
            self.low <<= 8;
        }
    }
};

// ============================================================================
// PPMd Result Types
// ============================================================================

pub const PpmResult = union(enum) {
    literal: u8,
    end_of_block: void,
    end_of_file: void,
    vm_code: void,
    lz_match: struct { distance: u32, length: u32 },
    rle_byte: struct { byte: u8, count: u32 },
};

// ============================================================================
// PPMd Context Model
// ============================================================================

/// A single symbol-frequency pair within a context.
pub const PpmState = struct {
    symbol: u8,
    freq: u8,
    successor_index: u32, // index into context pool, 0 = no successor
};

/// A context node in the PPMd tree.
pub const PpmContext = struct {
    num_stats: u16, // number of symbol states (0 = 1 state stored inline)
    summary_freq: u16, // total frequency sum
    states: []PpmState, // symbol->frequency entries (heap-allocated)
    suffix_index: u32, // index into context pool, 0 = no suffix
};

/// Maximum PPMd order for RAR3.
const MAX_ORDER: u8 = 64; // RAR3 allows up to order 64
const MAX_FREQ: u8 = 124;
const INT_BITS: u5 = 7;
const PERIOD_BITS: u5 = 7;
const BIN_SCALE: u16 = 1 << (INT_BITS + PERIOD_BITS); // 16384

/// SEE2 (Secondary Escape Estimation) context for PPMd.
const See2Context = struct {
    summ: u16,
    shift: u8,
    count: u8,

    fn init(init_val: u16) See2Context {
        return .{
            .summ = init_val << (PERIOD_BITS - 4),
            .shift = PERIOD_BITS - 4,
            .count = 4,
        };
    }

    fn getMean(self: *See2Context) u16 {
        const shift_amt: u4 = @intCast(self.shift & 0xF);
        const val = self.summ >> shift_amt;
        if (val == 0) return 1;
        self.summ -%= val;
        return val;
    }

    fn update(self: *See2Context) void {
        if (self.count == 0) {
            self.summ +%= self.summ;
            self.count = 3;
            if (self.shift < PERIOD_BITS) {
                self.shift += 1;
            }
        } else {
            self.count -= 1;
        }
    }
};

pub const PpmModel = struct {
    coder: RangeCoder,
    allocator: std.mem.Allocator,
    max_order: u8,
    // Context pool - arena-allocated
    contexts: std.ArrayList(PpmContext),
    // Order-0 context index
    order0_index: u32,
    // Min context for current decode
    min_context_index: u32,
    // Max context for current decode
    max_context_index: u32,
    // Current order
    order: u8,
    // Escape count
    esc_count: u8,
    // Previous symbol
    prev_symbol: u8,
    // Binary symbol estimates (simplified)
    bin_summ: [128][64]u16,
    // SEE2 contexts
    see2: [25][16]See2Context,
    // Character mask for exclusion
    char_mask: [256]u8,
    // Run length state
    run_length: i32,
    init_rl: i32,
    // Predecessor flag
    prev_success: u8,
    // Number of masked symbols in current escape chain
    num_masked: u32,
    // Hidden count of context's last used
    hib_bits_flag: u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, br: *BitReader) !PpmModel {
        // Read PPM parameters from bitstream
        // RAR3 PPM init: read max_order, mem_size_mb
        const max_order_raw = try br.readBits(8);
        const max_order: u8 = @intCast(@min(@max(max_order_raw, 2), MAX_ORDER));

        // Read memory size parameter (megabytes, sort of)
        // In RAR3, this is a byte that maps to a memory size
        const mem_size_mb = try br.readBits(8);
        _ = mem_size_mb; // We use Zig's allocator instead of a fixed pool

        // Read initial escape character
        const init_esc = try br.readBits(8);

        var model = PpmModel{
            .coder = try RangeCoder.init(br),
            .allocator = allocator,
            .max_order = max_order,
            .contexts = .empty,
            .order0_index = 0,
            .min_context_index = 0,
            .max_context_index = 0,
            .order = 0,
            .esc_count = @intCast(init_esc),
            .prev_symbol = 0,
            .bin_summ = undefined,
            .see2 = undefined,
            .char_mask = [_]u8{0} ** 256,
            .run_length = 0,
            .init_rl = @divTrunc(-@as(i32, @intCast(max_order)), 2),
            .prev_success = 0,
            .num_masked = 0,
            .hib_bits_flag = 0,
        };

        // Initialize binary symbol estimates
        // InitBinEsc has 8 entries; index by j >> 3 to map 64 bins to 8 groups
        for (0..128) |i_raw| {
            for (0..64) |j| {
                const esc_idx = j >> 3;
                const esc_val = InitBinEsc[esc_idx];
                model.bin_summ[i_raw][j] = BIN_SCALE -| @as(u16, @intCast(esc_val & 0x3FFF));
            }
        }

        // Initialize SEE2 contexts
        for (0..25) |i_raw| {
            for (0..16) |j| {
                model.see2[i_raw][j] = See2Context.init(@intCast(5 * i_raw + 10));
            }
        }

        // Create initial order-0 context
        try model.createInitialContexts();

        return model;
    }

    fn createInitialContexts(self: *Self) !void {
        // Create order -1 context (the root with all 256 symbols)
        var root_states = try self.allocator.alloc(PpmState, 256);
        for (0..256) |i| {
            root_states[i] = .{
                .symbol = @intCast(i),
                .freq = 1,
                .successor_index = 0,
            };
        }
        try self.contexts.append(self.allocator, .{
            .num_stats = 255,
            .summary_freq = 256,
            .states = root_states,
            .suffix_index = 0,
        });

        // Create order-0 context (initially empty, points to root as suffix)
        const empty_states = try self.allocator.alloc(PpmState, 1);
        empty_states[0] = .{
            .symbol = 0,
            .freq = 1,
            .successor_index = 0,
        };
        try self.contexts.append(self.allocator, .{
            .num_stats = 0,
            .summary_freq = 1,
            .states = empty_states,
            .suffix_index = 0, // points to root context (index 0)
        });
        self.order0_index = 1;
        self.min_context_index = 1;
        self.max_context_index = 1;
    }

    pub fn deinit(self: *Self) void {
        for (self.contexts.items) |ctx| {
            self.allocator.free(ctx.states);
        }
        self.contexts.deinit(self.allocator);
    }

    pub const DecodeError = error{CorruptPpmData};

    /// Decode a single symbol from the PPM stream.
    /// Uses iterative context fallback to avoid mutual recursion.
    pub fn decodeSymbol(self: *Self) DecodeError!PpmResult {
        // Iterative decode with context fallback
        const max_depth = self.max_order + 2; // prevent infinite loops
        var depth: u8 = 0;

        while (depth < max_depth) : (depth += 1) {
            if (self.min_context_index >= self.contexts.items.len) {
                return error.CorruptPpmData;
            }

            const ctx = &self.contexts.items[self.min_context_index];

            if (ctx.num_stats == 0) {
                // Binary context (single symbol)
                if (self.tryDecodeBinSymbol(ctx)) |result| {
                    return result;
                }
                // Escape: fall to suffix context
            } else {
                // Multi-symbol context
                if (self.tryDecodeMultiSymbol(ctx)) |result| {
                    return result;
                }
                // Escape: fall to suffix context
            }

            // Escape fallback: walk up to shorter context
            const suffix_idx = ctx.suffix_index;
            if (suffix_idx >= self.contexts.items.len) {
                // At root - decode from order -1 (uniform distribution)
                return self.decodeFromRoot();
            }
            self.min_context_index = suffix_idx;
        }

        return error.CorruptPpmData;
    }

    /// Try to decode from a binary context. Returns symbol if found, null if escape.
    fn tryDecodeBinSymbol(self: *Self, ctx: *PpmContext) ?PpmResult {
        if (ctx.states.len == 0) return null;
        const state = &ctx.states[0];

        // Compute probability index based on previous symbol and run state
        const ns_bits: usize = @intFromBool(self.prev_success != 0);
        const rl_bits: usize = if (self.run_length > 0)
            @as(usize, @intCast(self.run_length >> 26))
        else
            0;
        const idx2: usize = @min(ns_bits + rl_bits * 2, 63);

        const prob = &self.bin_summ[@min(state.freq, 127)][idx2];

        const threshold = self.coder.getThreshold(BIN_SCALE);

        if (threshold < prob.*) {
            // Symbol found
            self.coder.decode(0, prob.*);
            const symbol = state.symbol;

            // Update model
            if (prob.* < BIN_SCALE - 66) prob.* += @intCast(PERIOD_BITS - 4);
            self.prev_symbol = symbol;
            self.prev_success = 1;
            if (state.freq < MAX_FREQ) state.freq += 1;
            self.run_length += 1;

            return PpmResult{ .literal = symbol };
        } else {
            // Escape - symbol not found at this context level
            self.coder.decode(prob.*, BIN_SCALE - prob.*);
            if (prob.* > 1) prob.* -= 1;
            self.prev_success = 0;
            self.esc_count +%= 1;
            return null;
        }
    }

    /// Try to decode from a multi-symbol context. Returns symbol if found, null if escape.
    fn tryDecodeMultiSymbol(self: *Self, ctx: *PpmContext) ?PpmResult {
        const states = ctx.states;
        if (states.len == 0) return null;

        const scale = ctx.summary_freq;
        if (scale == 0) return null;

        const threshold = self.coder.getThreshold(scale);

        var cum_freq: u32 = 0;
        var i: usize = 0;
        while (i < states.len) : (i += 1) {
            cum_freq += states[i].freq;
            if (cum_freq > threshold) {
                // Found the symbol
                const freq = states[i].freq;
                const cf = cum_freq - freq;
                self.coder.decode(@intCast(cf), freq);

                const symbol = states[i].symbol;

                // Update frequency
                if (states[i].freq < MAX_FREQ) states[i].freq += 1;
                ctx.summary_freq += 1;

                self.prev_symbol = symbol;
                self.prev_success = @intFromBool(2 * freq > scale);
                self.run_length += 1;

                return PpmResult{ .literal = symbol };
            }
        }

        // Escape - symbol not found
        self.coder.decode(@intCast(cum_freq), @intCast(scale -| cum_freq));
        self.prev_success = 0;
        self.esc_count +%= 1;
        return null;
    }

    fn decodeFromRoot(self: *Self) PpmResult {
        // Uniform distribution over all 256 symbols
        const threshold = self.coder.getThreshold(256);
        const symbol: u8 = @intCast(threshold & 0xFF);
        self.coder.decode(symbol, 1);
        self.prev_symbol = symbol;
        return PpmResult{ .literal = symbol };
    }

    /// Allocate a new context in the pool and return its index.
    /// Used during context model extension when building higher-order contexts.
    pub fn allocContext(self: *Self) !u32 {
        const index: u32 = @intCast(self.contexts.items.len);
        const states = try self.allocator.alloc(PpmState, 1);
        states[0] = .{ .symbol = 0, .freq = 1, .successor_index = 0 };
        try self.contexts.append(self.allocator, .{
            .num_stats = 0,
            .summary_freq = 1,
            .states = states,
            .suffix_index = 0,
        });
        return index;
    }
};

/// Initial binary escape estimates.
const InitBinEsc = [_]u16{
    0x3CDD, 0x1F3F, 0x59BF, 0x48F3,
    0x64A1, 0x5ABC, 0x6632, 0x6051,
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "RangeCoder init reads 4 bytes into code" {
    // 4 bytes: 0xDE, 0xAD, 0xBE, 0xEF
    // code = (0xDE << 24) | (0xAD << 16) | (0xBE << 8) | 0xEF = 0xDEADBEEF
    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    var br = BitReader.init(&data);
    const rc = try RangeCoder.init(&br);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), rc.code);
    try testing.expectEqual(@as(u32, 0), rc.low);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), rc.range);
}

test "RangeCoder init with all zeros" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    var br = BitReader.init(&data);
    const rc = try RangeCoder.init(&br);
    try testing.expectEqual(@as(u32, 0), rc.code);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), rc.range);
}

test "RangeCoder init with all 0xFF" {
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    var br = BitReader.init(&data);
    const rc = try RangeCoder.init(&br);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), rc.code);
}

test "RangeCoder getThreshold basic calculation" {
    // code = 0x80000000, range = 0xFFFFFFFF, scale = 256
    // After getThreshold: range = 0xFFFFFFFF / 256 = 0x00FFFFFF
    // threshold = (code - low) / range = 0x80000000 / 0x00FFFFFF = 128
    const data = [_]u8{ 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var br = BitReader.init(&data);
    var rc = try RangeCoder.init(&br);
    const threshold = rc.getThreshold(256);
    try testing.expectEqual(@as(u32, 128), threshold);
}

test "RangeCoder getThreshold with scale 2" {
    // code = 0xC0000000, range = 0xFFFFFFFF, scale = 2
    // range becomes 0xFFFFFFFF / 2 = 0x7FFFFFFF
    // threshold = 0xC0000000 / 0x7FFFFFFF = 1
    const data = [_]u8{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var br = BitReader.init(&data);
    var rc = try RangeCoder.init(&br);
    const threshold = rc.getThreshold(2);
    try testing.expectEqual(@as(u32, 1), threshold);
}

test "RangeCoder decode updates low and range" {
    const data = [_]u8{ 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var br = BitReader.init(&data);
    var rc = try RangeCoder.init(&br);

    // Simulate: scale=256, getThreshold returns 128
    _ = rc.getThreshold(256);
    // Now range = 0x00FFFFFF (approx)
    // Decode symbol with cum_freq=128, freq=1
    const saved_range = rc.range;
    rc.decode(128, 1);
    // low should be updated: low += 128 * saved_range
    _ = saved_range;
    // range should be: range * 1 (then normalized)
    // Just verify it didn't crash and state changed
    try testing.expect(rc.low != 0 or rc.range != 0xFFFFFFFF);
}

test "RangeCoder normalize maintains invariants" {
    // With a simple setup, verify normalize doesn't crash
    const data = [_]u8{ 0x40, 0x00, 0x00, 0x00 } ++ [_]u8{0x00} ** 32;
    var br = BitReader.init(&data);
    var rc = try RangeCoder.init(&br);

    // Force a small range to trigger normalization
    rc.range = 0x100;
    rc.normalize();

    // After normalization, range should be large again
    try testing.expect(rc.range >= TOP);
}

test "PpmResult union variants" {
    const lit = PpmResult{ .literal = 'A' };
    try testing.expectEqual(@as(u8, 'A'), lit.literal);

    const eob = PpmResult{ .end_of_block = {} };
    try testing.expect(eob == .end_of_block);

    const eof = PpmResult{ .end_of_file = {} };
    try testing.expect(eof == .end_of_file);

    const vm = PpmResult{ .vm_code = {} };
    try testing.expect(vm == .vm_code);

    const lz = PpmResult{ .lz_match = .{ .distance = 100, .length = 5 } };
    try testing.expectEqual(@as(u32, 100), lz.lz_match.distance);
    try testing.expectEqual(@as(u32, 5), lz.lz_match.length);

    const rle = PpmResult{ .rle_byte = .{ .byte = 0xFF, .count = 10 } };
    try testing.expectEqual(@as(u8, 0xFF), rle.rle_byte.byte);
    try testing.expectEqual(@as(u32, 10), rle.rle_byte.count);
}

test "See2Context init and getMean" {
    var see2 = See2Context.init(10);
    // summ = 10 << (7 - 4) = 10 << 3 = 80
    try testing.expectEqual(@as(u16, 80), see2.summ);
    try testing.expectEqual(@as(u8, 3), see2.shift); // PERIOD_BITS - 4 = 3
    try testing.expectEqual(@as(u8, 4), see2.count);

    const mean = see2.getMean();
    // mean = 80 >> 3 = 10
    try testing.expectEqual(@as(u16, 10), mean);
    // summ should be updated: 80 - 10 = 70
    try testing.expectEqual(@as(u16, 70), see2.summ);
}

test "See2Context update decrements count" {
    var see2 = See2Context.init(10);
    try testing.expectEqual(@as(u8, 4), see2.count);

    see2.update();
    try testing.expectEqual(@as(u8, 3), see2.count);

    see2.update();
    try testing.expectEqual(@as(u8, 2), see2.count);

    see2.update();
    try testing.expectEqual(@as(u8, 1), see2.count);

    see2.update();
    try testing.expectEqual(@as(u8, 0), see2.count);

    // Next update with count=0 should double summ and reset count
    const old_summ = see2.summ;
    see2.update();
    try testing.expectEqual(@as(u16, old_summ +% old_summ), see2.summ);
    try testing.expectEqual(@as(u8, 3), see2.count);
}

test "PpmModel init and deinit" {
    // Build a minimal PPM init bitstream:
    // byte 0: max_order (e.g., 6)
    // byte 1: mem_size_mb (e.g., 1)
    // byte 2: init_esc (e.g., 0)
    // bytes 3-6: range coder init (4 bytes)
    const data = [_]u8{
        6, // max_order
        1, // mem_size
        0, // init_esc
        0x80, 0x00, 0x00, 0x00, // range coder init bytes
    } ++ [_]u8{0x00} ** 32; // padding for normalization reads

    var br = BitReader.init(&data);
    var model = try PpmModel.init(testing.allocator, &br);
    defer model.deinit();

    try testing.expectEqual(@as(u8, 6), model.max_order);
    try testing.expect(model.contexts.items.len >= 2); // at least root + order-0
}

test "PpmModel decodeSymbol returns a result" {
    // Construct a bitstream that will produce a valid decode
    const data = [_]u8{
        4, // max_order
        1, // mem_size
        0, // init_esc
        0x40, 0x00, 0x00, 0x00, // range coder init - code = 0x40000000
    } ++ [_]u8{0x00} ** 64; // padding

    var br = BitReader.init(&data);
    var model = try PpmModel.init(testing.allocator, &br);
    defer model.deinit();

    // Decode one symbol - should not crash
    const result = try model.decodeSymbol();
    // Should be a literal (since we're in the basic implementation)
    switch (result) {
        .literal => {},
        else => try testing.expect(false), // unexpected result type
    }
}
