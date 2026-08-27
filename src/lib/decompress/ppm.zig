//! PPMd variant H, as used by RAR3 (v29) "text compression" blocks.
//!
//! Clean-room port of the reference decoder (unrar 7.20: model.cpp,
//! suballoc.cpp, coder.cpp — Dmitry Shkarin's public-domain PPMd, Dmitry
//! Subbotin's carryless range coder). This REPLACES an earlier simplified
//! stand-in whose model never learned: contexts were created but no symbol was
//! ever inserted, the init read three plain bytes where the format packs
//! order/reset/escape into flag bits, and its unit tests validated the
//! stand-in against itself. On real PPMd streams the stand-in either failed
//! instantly (false positive on clean archives) or churned escapes for
//! minutes. Correct PPMd IS the fast path.
//!
//! Pointer model: the reference is pointer-heavy inside one malloc'd heap. We
//! mirror it with u32 BYTE OFFSETS into a single `heap` slice. Offset 0 is
//! NULL — no valid pointer can be 0, because successor "stubs" are written at
//! `pText` and recorded AFTER the increment, so the smallest stub offset is 1,
//! and real contexts/states live far above. Every reference guard of the form
//! `ptr <= pText` / `ptr > HeapEnd` then works verbatim on offsets, with NULL
//! naturally failing the first comparison exactly as C NULL does.
//!
//! Layout: we control the struct packing, so UNIT_SIZE == FIXED_UNIT_SIZE
//! == 12 exactly (the reference must paper over larger host pointers; we do
//! not). CONTEXT = {NumStats u16 @0; union @2 {SummFreq u16 @2, Stats u32 @4 |
//! OneState @2..8}; Suffix u32 @8} = 12 bytes. STATE = {Symbol u8, Freq u8,
//! Successor u32} = 6 bytes. MEM_BLK = {Stamp u16, NU u16, next u32, prev u32}
//! = 12 bytes. The OneState/FreqData aliasing the reference gets from a C
//! union falls out of the shared offsets.

const std = @import("std");
const BitReader = @import("bitreader.zig").BitReader;

// ============================================================================
// Constants (RARPPM_DEF and coder)
// ============================================================================

const INT_BITS: u5 = 7;
const PERIOD_BITS: u5 = 7;
const TOT_BITS: u5 = INT_BITS + PERIOD_BITS; // 14
const INTERVAL: u32 = 1 << INT_BITS; // 128
const BIN_SCALE: u32 = 1 << TOT_BITS; // 16384
const MAX_FREQ: u32 = 124;
const MAX_O: usize = 64;

const TOP: u32 = 1 << 24;
const BOT: u32 = 1 << 15;

const UNIT_SIZE: u32 = 12;
const STATE_SIZE: u32 = 6;

/// Heap-offset NULL. See the module comment for why 0 is safe.
const NULL_OFF: u32 = 0;

// ============================================================================
// Carryless range coder (coder.cpp)
// ============================================================================

const RangeCoder = struct {
    low: u32,
    code: u32,
    range: u32,
    low_count: u32,
    high_count: u32,
    scale: u32,

    /// The reference's GetChar reads raw bytes from an over-allocated input
    /// buffer and returns stale bytes at EOF, relying on the model's guards to
    /// notice corruption. Returning 0 on exhaustion has the same property:
    /// deterministic garbage the guards catch, never a panic.
    fn getByte(br: *BitReader) u32 {
        return br.readBits(8) catch 0;
    }

    fn initDecoder(self: *RangeCoder, br: *BitReader) void {
        self.low = 0;
        self.code = 0;
        self.range = 0xFFFFFFFF;
        for (0..4) |_| {
            self.code = (self.code << 8) | getByte(br);
        }
    }

    /// Reference: `return (code-low)/(range /= SubRange.scale)`. A zero
    /// divisor is a corrupt-stream state the C code would crash on; we report
    /// corruption instead.
    fn currentCount(self: *RangeCoder) !u32 {
        if (self.scale == 0) return error.CorruptPpmData;
        self.range /= self.scale;
        if (self.range == 0) return error.CorruptPpmData;
        return (self.code -% self.low) / self.range;
    }

    fn currentShiftCount(self: *RangeCoder, shift: u5) !u32 {
        self.range >>= shift;
        if (self.range == 0) return error.CorruptPpmData;
        return (self.code -% self.low) / self.range;
    }

    fn decodeUpdate(self: *RangeCoder) void {
        self.low +%= self.range *% self.low_count;
        self.range *%= self.high_count -% self.low_count;
    }

    /// ARI_DEC_NORMALIZE. The `||` short-circuit matters: when the top bytes
    /// of low and low+range already differ, range is NOT reset even if small.
    fn normalize(self: *RangeCoder, br: *BitReader) void {
        while (true) {
            if ((self.low ^ (self.low +% self.range)) >= TOP) {
                if (self.range >= BOT) break;
                self.range = (0 -% self.low) & (BOT - 1);
            }
            self.code = (self.code << 8) | getByte(br);
            self.range <<= 8;
            self.low <<= 8;
        }
    }
};

// ============================================================================
// Heap accessors — CONTEXT, STATE, MEM_BLK fields at byte offsets
// ============================================================================

inline fn rd16(h: []u8, off: u32) u16 {
    return std.mem.readInt(u16, h[off..][0..2], .little);
}
inline fn wr16(h: []u8, off: u32, v: u16) void {
    std.mem.writeInt(u16, h[off..][0..2], v, .little);
}
inline fn rd32(h: []u8, off: u32) u32 {
    return std.mem.readInt(u32, h[off..][0..4], .little);
}
inline fn wr32(h: []u8, off: u32, v: u32) void {
    std.mem.writeInt(u32, h[off..][0..4], v, .little);
}

// CONTEXT
inline fn ctxNumStats(h: []u8, c: u32) u16 {
    return rd16(h, c);
}
inline fn ctxSetNumStats(h: []u8, c: u32, v: u16) void {
    wr16(h, c, v);
}
inline fn ctxSummFreq(h: []u8, c: u32) u16 {
    return rd16(h, c + 2);
}
inline fn ctxSetSummFreq(h: []u8, c: u32, v: u16) void {
    wr16(h, c + 2, v);
}
inline fn ctxStats(h: []u8, c: u32) u32 {
    return rd32(h, c + 4);
}
inline fn ctxSetStats(h: []u8, c: u32, v: u32) void {
    wr32(h, c + 4, v);
}
inline fn ctxSuffix(h: []u8, c: u32) u32 {
    return rd32(h, c + 8);
}
inline fn ctxSetSuffix(h: []u8, c: u32, v: u32) void {
    wr32(h, c + 8, v);
}
/// The context's inline single state (union alias of SummFreq+Stats).
inline fn ctxOneState(c: u32) u32 {
    return c + 2;
}

// STATE (6 bytes)
inline fn stSym(h: []u8, s: u32) u8 {
    return h[s];
}
inline fn stSetSym(h: []u8, s: u32, v: u8) void {
    h[s] = v;
}
inline fn stFreq(h: []u8, s: u32) u8 {
    return h[s + 1];
}
inline fn stSetFreq(h: []u8, s: u32, v: u8) void {
    h[s + 1] = v;
}
inline fn stSucc(h: []u8, s: u32) u32 {
    return rd32(h, s + 2);
}
inline fn stSetSucc(h: []u8, s: u32, v: u32) void {
    wr32(h, s + 2, v);
}
inline fn stCopy(h: []u8, dst: u32, src: u32) void {
    @memcpy(h[dst..][0..STATE_SIZE], h[src..][0..STATE_SIZE]);
}
inline fn stSwap(h: []u8, a: u32, b: u32) void {
    var tmp: [STATE_SIZE]u8 = undefined;
    @memcpy(&tmp, h[a..][0..STATE_SIZE]);
    @memcpy(h[a..][0..STATE_SIZE], h[b..][0..STATE_SIZE]);
    @memcpy(h[b..][0..STATE_SIZE], &tmp);
}

/// A state value held OUTSIDE the heap (the reference's stack-local
/// RARPPM_STATE, e.g. UpState in CreateSuccessors).
const LocalState = struct {
    sym: u8,
    freq: u8,
    succ: u32,

    fn load(h: []u8, s: u32) LocalState {
        return .{ .sym = stSym(h, s), .freq = stFreq(h, s), .succ = stSucc(h, s) };
    }
    fn store(self: LocalState, h: []u8, s: u32) void {
        stSetSym(h, s, self.sym);
        stSetFreq(h, s, self.freq);
        stSetSucc(h, s, self.succ);
    }
};

// MEM_BLK
inline fn mbStamp(h: []u8, m: u32) u16 {
    return rd16(h, m);
}
inline fn mbSetStamp(h: []u8, m: u32, v: u16) void {
    wr16(h, m, v);
}
inline fn mbNU(h: []u8, m: u32) u16 {
    return rd16(h, m + 2);
}
inline fn mbSetNU(h: []u8, m: u32, v: u16) void {
    wr16(h, m + 2, v);
}
inline fn mbNext(h: []u8, m: u32) u32 {
    return rd32(h, m + 4);
}
inline fn mbSetNext(h: []u8, m: u32, v: u32) void {
    wr32(h, m + 4, v);
}
inline fn mbPrev(h: []u8, m: u32) u32 {
    return rd32(h, m + 8);
}
inline fn mbSetPrev(h: []u8, m: u32, v: u32) void {
    wr32(h, m + 8, v);
}

// ============================================================================
// SubAllocator (suballoc.cpp)
// ============================================================================

const N1 = 4;
const N2 = 4;
const N3 = 4;
const N4 = (128 + 3 - 1 * N1 - 2 * N2 - 3 * N3) / 4; // 26
const N_INDEXES = N1 + N2 + N3 + N4; // 38

const SubAllocator = struct {
    allocator: std.mem.Allocator,
    heap: []u8,
    sub_allocator_size: u32, // `t` in the reference: the ORIGINAL byte size
    glue_count: u8,
    indx2units: [N_INDEXES]u8,
    units2indx: [128]u8,
    free_list: [N_INDEXES]u32, // head offsets; 0 = empty
    ptext: u32,
    units_start: u32,
    fake_units_start: u32,
    heap_end: u32,
    lo_unit: u32,
    hi_unit: u32,

    fn initEmpty(allocator: std.mem.Allocator) SubAllocator {
        return .{
            .allocator = allocator,
            .heap = &.{},
            .sub_allocator_size = 0,
            .glue_count = 0,
            .indx2units = undefined,
            .units2indx = undefined,
            .free_list = [_]u32{NULL_OFF} ** N_INDEXES,
            .ptext = 0,
            .units_start = 0,
            .fake_units_start = 0,
            .heap_end = 0,
            .lo_unit = 0,
            .hi_unit = 0,
        };
    }

    fn stop(self: *SubAllocator) void {
        if (self.sub_allocator_size != 0) {
            self.sub_allocator_size = 0;
            self.allocator.free(self.heap);
            self.heap = &.{};
        }
    }

    fn start(self: *SubAllocator, sa_size_mb: u32) bool {
        const t: u32 = sa_size_mb << 20;
        if (self.sub_allocator_size == t) return true;
        self.stop();
        const alloc_size: u32 = t / UNIT_SIZE * UNIT_SIZE + 2 * UNIT_SIZE;
        self.heap = self.allocator.alloc(u8, alloc_size) catch return false;
        self.heap_end = alloc_size - UNIT_SIZE;
        self.sub_allocator_size = t;
        return true;
    }

    fn initSubAllocator(self: *SubAllocator) void {
        @memset(&self.free_list, NULL_OFF);
        self.ptext = 0;

        const t = self.sub_allocator_size;
        // 7/8 of the pool for units, 1/8 for the text area; UNIT_SIZE ==
        // FIXED_UNIT_SIZE collapses the reference's Real*/Fake* split except
        // for the +UNIT_SIZE remainder compensation, kept verbatim.
        const size2: u32 = UNIT_SIZE * (t / 8 / UNIT_SIZE * 7);
        const size1: u32 = t - size2;
        const real_size1: u32 = size1 / UNIT_SIZE * UNIT_SIZE + UNIT_SIZE;

        self.units_start = real_size1;
        self.lo_unit = real_size1;
        self.fake_units_start = size1;
        self.hi_unit = self.lo_unit + size2;

        var i: usize = 0;
        var k: u8 = 1;
        while (i < N1) : ({
            i += 1;
            k += 1;
        }) self.indx2units[i] = k;
        k += 1;
        while (i < N1 + N2) : ({
            i += 1;
            k += 2;
        }) self.indx2units[i] = k;
        k += 1;
        while (i < N1 + N2 + N3) : ({
            i += 1;
            k += 3;
        }) self.indx2units[i] = k;
        k += 1;
        while (i < N_INDEXES) : ({
            i += 1;
            k += 4;
        }) self.indx2units[i] = k;

        self.glue_count = 0;
        var ii: usize = 0;
        for (0..128) |kk| {
            if (self.indx2units[ii] < kk + 1) ii += 1;
            self.units2indx[kk] = @intCast(ii);
        }
    }

    inline fn u2b(nu: u32) u32 {
        return UNIT_SIZE * nu;
    }

    inline fn insertNode(self: *SubAllocator, p: u32, indx: usize) void {
        wr32(self.heap, p, self.free_list[indx]);
        self.free_list[indx] = p;
    }

    inline fn removeNode(self: *SubAllocator, indx: usize) u32 {
        const r = self.free_list[indx];
        self.free_list[indx] = rd32(self.heap, r);
        return r;
    }

    fn splitBlock(self: *SubAllocator, pv: u32, old_indx: usize, new_indx: usize) void {
        var udiff: u32 = @as(u32, self.indx2units[old_indx]) - self.indx2units[new_indx];
        var p: u32 = pv + u2b(self.indx2units[new_indx]);
        var i: usize = self.units2indx[udiff - 1];
        if (self.indx2units[i] != udiff) {
            i -= 1;
            self.insertNode(p, i);
            const iu: u32 = self.indx2units[i];
            p += u2b(iu);
            udiff -= iu;
        }
        self.insertNode(p, self.units2indx[udiff - 1]);
    }

    /// GlueFreeBlocks. The reference threads a stack-local sentinel node (s0)
    /// into the doubly-linked list; we keep the sentinel's links in locals and
    /// route accesses through these helpers.
    const S0: u32 = 0xFFFFFFFF;

    fn glueFreeBlocks(self: *SubAllocator) void {
        var s0_next: u32 = S0;
        var s0_prev: u32 = S0;
        const h = self.heap;

        const getNext = struct {
            fn f(hh: []u8, sn: *u32, x: u32) u32 {
                return if (x == S0) sn.* else mbNext(hh, x);
            }
        }.f;
        _ = getNext;

        if (self.lo_unit != self.hi_unit) h[self.lo_unit] = 0;

        // Phase 1: drain the free lists into one stamped, doubly-linked list.
        for (0..N_INDEXES) |i| {
            while (self.free_list[i] != NULL_OFF) {
                const p = self.removeNode(i);
                // insertAt(&s0)
                const next = s0_next;
                mbSetPrev(h, p, S0);
                mbSetNext(h, p, next);
                if (next == S0) s0_prev = p else mbSetPrev(h, next, p);
                s0_next = p;
                mbSetStamp(h, p, 0xFFFF);
                mbSetNU(h, p, @intCast(self.indx2units[i]));
            }
        }

        // Phase 2: merge physically adjacent stamped blocks.
        var p = s0_next;
        while (p != S0) : (p = mbNext(h, p)) {
            while (true) {
                const p1 = p + u2b(mbNU(h, p));
                if (p1 + UNIT_SIZE > h.len) break; // panic guard; unreachable for valid states
                if (mbStamp(h, p1) != 0xFFFF) break;
                const total: u32 = @as(u32, mbNU(h, p)) + mbNU(h, p1);
                if (total >= 0x10000) break;
                // p1->remove()
                const pr = mbPrev(h, p1);
                const nx = mbNext(h, p1);
                if (pr == S0) s0_next = nx else mbSetNext(h, pr, nx);
                if (nx == S0) s0_prev = pr else mbSetPrev(h, nx, pr);
                mbSetNU(h, p, @intCast(total));
            }
        }

        // Phase 3: re-insert, chopping >128-unit runs.
        while (s0_next != S0) {
            p = s0_next;
            // p->remove()
            {
                const nx = mbNext(h, p);
                if (nx == S0) s0_prev = S0 else mbSetPrev(h, nx, S0);
                s0_next = nx;
            }
            var sz: u32 = mbNU(h, p);
            while (sz > 128) : (sz -= 128) {
                self.insertNode(p, N_INDEXES - 1);
                p += u2b(128);
            }
            var i: usize = self.units2indx[sz - 1];
            if (self.indx2units[i] != sz) {
                i -= 1;
                const k: u32 = sz - self.indx2units[i];
                self.insertNode(p + u2b(sz - k), @intCast(k - 1));
            }
            self.insertNode(p, i);
        }
    }

    fn allocUnitsRare(self: *SubAllocator, indx: usize) u32 {
        if (self.glue_count == 0) {
            self.glue_count = 255;
            self.glueFreeBlocks();
            if (self.free_list[indx] != NULL_OFF)
                return self.removeNode(indx);
        }
        var i = indx;
        while (true) {
            i += 1;
            if (i == N_INDEXES) {
                self.glue_count -%= 1;
                const bytes: u32 = u2b(self.indx2units[indx]);
                // FIXED_UNIT_SIZE == UNIT_SIZE, so the reference's separate
                // fake-units bookkeeping moves in lockstep with the real one.
                if (self.fake_units_start > self.ptext and
                    self.fake_units_start - self.ptext > bytes)
                {
                    self.fake_units_start -= bytes;
                    self.units_start -= bytes;
                    return self.units_start;
                }
                return NULL_OFF;
            }
            if (self.free_list[i] != NULL_OFF) break;
        }
        const ret = self.removeNode(i);
        self.splitBlock(ret, i, indx);
        return ret;
    }

    fn allocUnits(self: *SubAllocator, nu: u32) u32 {
        const indx: usize = self.units2indx[nu - 1];
        if (self.free_list[indx] != NULL_OFF)
            return self.removeNode(indx);
        const ret = self.lo_unit;
        self.lo_unit += u2b(self.indx2units[indx]);
        if (self.lo_unit <= self.hi_unit) return ret;
        self.lo_unit -= u2b(self.indx2units[indx]);
        return self.allocUnitsRare(indx);
    }

    fn allocContext(self: *SubAllocator) u32 {
        if (self.hi_unit != self.lo_unit) {
            self.hi_unit -= UNIT_SIZE;
            return self.hi_unit;
        }
        if (self.free_list[0] != NULL_OFF)
            return self.removeNode(0);
        return self.allocUnitsRare(0);
    }

    fn expandUnits(self: *SubAllocator, old_ptr: u32, old_nu: u32) u32 {
        const idx_old: usize = self.units2indx[old_nu - 1];
        const idx_new: usize = self.units2indx[old_nu];
        if (idx_old == idx_new) return old_ptr;
        const ptr = self.allocUnits(old_nu + 1);
        if (ptr != NULL_OFF) {
            std.mem.copyForwards(u8, self.heap[ptr..][0..u2b(old_nu)], self.heap[old_ptr..][0..u2b(old_nu)]);
            self.insertNode(old_ptr, idx_old);
        }
        return ptr;
    }

    fn shrinkUnits(self: *SubAllocator, old_ptr: u32, old_nu: u32, new_nu: u32) u32 {
        const idx_old: usize = self.units2indx[old_nu - 1];
        const idx_new: usize = self.units2indx[new_nu - 1];
        if (idx_old == idx_new) return old_ptr;
        if (self.free_list[idx_new] != NULL_OFF) {
            const ptr = self.removeNode(idx_new);
            std.mem.copyForwards(u8, self.heap[ptr..][0..u2b(new_nu)], self.heap[old_ptr..][0..u2b(new_nu)]);
            self.insertNode(old_ptr, idx_old);
            return ptr;
        }
        self.splitBlock(old_ptr, idx_old, idx_new);
        return old_ptr;
    }

    fn freeUnits(self: *SubAllocator, ptr: u32, old_nu: u32) void {
        self.insertNode(ptr, self.units2indx[old_nu - 1]);
    }
};

// ============================================================================
// SEE2 (model.hpp)
// ============================================================================

const See2 = struct {
    summ: u16,
    shift: u8,
    count: u8,

    fn init(init_val: u32) See2 {
        const shift: u8 = PERIOD_BITS - 4;
        return .{
            .summ = @truncate(init_val << @intCast(shift)),
            .shift = shift,
            .count = 4,
        };
    }

    /// Signed arithmetic exactly as the reference: `short RetVal =
    /// (short)Summ >> Shift` sign-extends, and the return converts through
    /// int to uint.
    fn getMean(self: *See2) u32 {
        const ret: i32 = @as(i16, @bitCast(self.summ)) >> @intCast(self.shift);
        self.summ -%= @bitCast(@as(i16, @truncate(ret)));
        return @bitCast(ret + @intFromBool(ret == 0));
    }

    fn update(self: *See2) void {
        if (self.shift < PERIOD_BITS) {
            self.count -%= 1;
            if (self.count == 0) {
                self.summ +%= self.summ;
                self.count = @truncate(@as(u32, 3) << @intCast(self.shift));
                self.shift += 1;
            }
        }
    }
};

// ============================================================================
// Model (model.cpp)
// ============================================================================

/// GET_MEAN(SUMM,SHIFT,ROUND) from the reference.
inline fn getMeanSpread(summ: u32, comptime shift: u5, comptime round: u5) u32 {
    return (summ + (@as(u32, 1) << (shift - round))) >> shift;
}

const ExpEscape = [16]u8{ 25, 14, 9, 7, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2 };
const InitBinEsc = [8]u16{ 0x3CDD, 0x1F3F, 0x59BF, 0x48F3, 0x64A1, 0x5ABC, 0x6632, 0x6051 };

pub const PpmModel = struct {
    coder: RangeCoder,
    sub: SubAllocator,

    see2: [25][16]See2,
    dummy_see2: See2,
    min_context: u32,
    max_context: u32,
    found_state: u32, // state offset, NULL_OFF when escaped
    num_masked: u32,
    init_esc: u32,
    order_fall: i32,
    max_order: u32,
    run_length: i32,
    init_rl: i32,
    char_mask: [256]u8,
    ns2indx: [256]u8,
    ns2bsindx: [256]u8,
    hb2flag: [256]u8,
    esc_count: u8,
    prev_success: u8,
    hi_bits_flag: u8,
    bin_summ: [128][64]u16,

    const Self = @This();
    pub const DecodeError = error{CorruptPpmData};

    pub fn init(allocator: std.mem.Allocator) Self {
        var m: Self = undefined;
        m.sub = SubAllocator.initEmpty(allocator);
        m.min_context = NULL_OFF;
        m.max_context = NULL_OFF;
        m.found_state = NULL_OFF;
        return m;
    }

    pub fn deinit(self: *Self) void {
        self.sub.stop();
    }

    fn restartModelRare(self: *Self) !void {
        @memset(&self.char_mask, 0);
        self.sub.initSubAllocator();
        self.init_rl = -@as(i32, @intCast(@min(self.max_order, 12))) - 1;
        const mc = self.sub.allocContext();
        if (mc == NULL_OFF) return error.CorruptPpmData;
        self.min_context = mc;
        self.max_context = mc;
        const h = self.sub.heap;
        ctxSetSuffix(h, mc, NULL_OFF);
        self.order_fall = @intCast(self.max_order);
        ctxSetNumStats(h, mc, 256);
        ctxSetSummFreq(h, mc, 256 + 1);
        const stats = self.sub.allocUnits(256 / 2);
        if (stats == NULL_OFF) return error.CorruptPpmData;
        ctxSetStats(h, mc, stats);
        self.found_state = stats;
        self.run_length = self.init_rl;
        self.prev_success = 0;
        for (0..256) |i| {
            const s = stats + @as(u32, @intCast(i)) * STATE_SIZE;
            stSetSym(h, s, @intCast(i));
            stSetFreq(h, s, 1);
            stSetSucc(h, s, NULL_OFF);
        }

        for (0..128) |i| {
            for (0..8) |k| {
                var m: usize = 0;
                while (m < 64) : (m += 8) {
                    self.bin_summ[i][k + m] =
                        @truncate(BIN_SCALE - InitBinEsc[k] / (@as(u32, @intCast(i)) + 2));
                }
            }
        }
        for (0..25) |i| {
            for (0..16) |k| {
                self.see2[i][k] = See2.init(5 * @as(u32, @intCast(i)) + 10);
            }
        }
    }

    fn startModelRare(self: *Self, max_order: u32) !void {
        self.esc_count = 1;
        self.max_order = max_order;
        try self.restartModelRare();
        self.ns2bsindx[0] = 2 * 0;
        self.ns2bsindx[1] = 2 * 1;
        @memset(self.ns2bsindx[2..11], 2 * 2);
        @memset(self.ns2bsindx[11..256], 2 * 3);
        for (0..3) |i| self.ns2indx[i] = @intCast(i);
        {
            var m: u8 = 3;
            var k: u32 = 1;
            var step: u32 = 1;
            var i: usize = 3;
            while (i < 256) : (i += 1) {
                self.ns2indx[i] = m;
                k -= 1;
                if (k == 0) {
                    step += 1;
                    k = step;
                    m += 1;
                }
            }
        }
        @memset(self.hb2flag[0..0x40], 0);
        @memset(self.hb2flag[0x40..0x100], 0x08);
        self.dummy_see2 = .{ .summ = 0, .shift = PERIOD_BITS, .count = 64 };
    }

    /// reset PPM after data error, allowing safe resuming (CleanUp)
    pub fn cleanUp(self: *Self) void {
        self.sub.stop();
        if (self.sub.start(1)) {
            self.startModelRare(2) catch {};
        }
    }

    fn createChild(self: *Self, c: u32, p_state: u32, first: LocalState) u32 {
        const pc = self.sub.allocContext();
        if (pc != NULL_OFF) {
            const h = self.sub.heap;
            ctxSetNumStats(h, pc, 1);
            first.store(h, ctxOneState(pc));
            ctxSetSuffix(h, pc, c);
            stSetSucc(h, p_state, pc);
        }
        return pc;
    }

    fn rescale(self: *Self, c: u32) void {
        const h = self.sub.heap;
        const old_ns: u32 = ctxNumStats(h, c);
        var i: u32 = old_ns - 1;
        const stats = ctxStats(h, c);

        // Move the found state to the front.
        {
            var p = self.found_state;
            while (p != stats) : (p -= STATE_SIZE) {
                stSwap(h, p, p - STATE_SIZE);
            }
        }
        stSetFreq(h, stats, stFreq(h, stats) +| 4);
        ctxSetSummFreq(h, c, ctxSummFreq(h, c) +% 4);
        var esc_freq: u32 = @as(u32, ctxSummFreq(h, c)) -% stFreq(h, stats);
        const adder: u32 = @intFromBool(self.order_fall != 0);
        stSetFreq(h, stats, @intCast((@as(u32, stFreq(h, stats)) + adder) >> 1));
        var summ_freq: u32 = stFreq(h, stats);

        var p = stats;
        while (i != 0) : (i -= 1) {
            p += STATE_SIZE;
            esc_freq -%= stFreq(h, p);
            stSetFreq(h, p, @intCast((@as(u32, stFreq(h, p)) + adder) >> 1));
            summ_freq += stFreq(h, p);
            if (stFreq(h, p) > stFreq(h, p - STATE_SIZE)) {
                // insertion sort the grown entry backwards
                var p1 = p;
                var tmp: [STATE_SIZE]u8 = undefined;
                @memcpy(&tmp, h[p1..][0..STATE_SIZE]);
                const tmp_freq = tmp[1];
                while (p1 != stats and tmp_freq > stFreq(h, p1 - STATE_SIZE)) : (p1 -= STATE_SIZE) {
                    stCopy(h, p1, p1 - STATE_SIZE);
                }
                @memcpy(h[p1..][0..STATE_SIZE], &tmp);
            }
        }

        if (stFreq(h, p) == 0) {
            var zeros: u32 = 0;
            while (stFreq(h, p) == 0) {
                zeros += 1;
                p -= STATE_SIZE;
            }
            esc_freq +%= zeros;
            const new_ns = old_ns - zeros;
            ctxSetNumStats(h, c, @intCast(new_ns));
            if (new_ns == 1) {
                var tmp = LocalState.load(h, stats);
                var ef = esc_freq;
                while (true) {
                    tmp.freq -= tmp.freq >> 1;
                    ef >>= 1;
                    if (ef <= 1) break;
                }
                self.sub.freeUnits(stats, (old_ns + 1) >> 1);
                const one = ctxOneState(c);
                tmp.store(h, one);
                self.found_state = one;
                return;
            }
        }
        const ns: u32 = ctxNumStats(h, c);
        esc_freq -%= esc_freq >> 1;
        ctxSetSummFreq(h, c, @truncate(summ_freq + esc_freq));
        const n0 = (old_ns + 1) >> 1;
        const n1 = (ns + 1) >> 1;
        if (n0 != n1) {
            const moved = self.sub.shrinkUnits(stats, n0, n1);
            ctxSetStats(h, c, moved);
        }
        self.found_state = ctxStats(h, c);
    }

    fn createSuccessors(self: *Self, skip: bool, p1: u32) u32 {
        const h = self.sub.heap;
        var pc = self.min_context;
        const up_branch = stSucc(h, self.found_state);
        var ps: [MAX_O]u32 = undefined;
        var nps: usize = 0;
        var p: u32 = NULL_OFF;

        var goto_no_loop = false;
        var goto_loop_entry = false;
        if (!skip) {
            ps[nps] = self.found_state;
            nps += 1;
            if (ctxSuffix(h, pc) == NULL_OFF) goto_no_loop = true;
        }
        if (!goto_no_loop and p1 != NULL_OFF) {
            p = p1;
            pc = ctxSuffix(h, pc);
            goto_loop_entry = true;
        }
        if (!goto_no_loop) {
            while (true) {
                if (!goto_loop_entry) {
                    pc = ctxSuffix(h, pc);
                    if (ctxNumStats(h, pc) != 1) {
                        p = ctxStats(h, pc);
                        if (stSym(h, p) != stSym(h, self.found_state)) {
                            while (true) {
                                p += STATE_SIZE;
                                if (p + STATE_SIZE > h.len) return NULL_OFF; // panic guard
                                if (stSym(h, p) == stSym(h, self.found_state)) break;
                            }
                        }
                    } else {
                        p = ctxOneState(pc);
                    }
                }
                goto_loop_entry = false;
                if (stSucc(h, p) != up_branch) {
                    pc = stSucc(h, p);
                    break;
                }
                if (nps >= MAX_O) return NULL_OFF; // CVE-2017-17969 guard
                ps[nps] = p;
                nps += 1;
                if (ctxSuffix(h, pc) == NULL_OFF) break;
            }
        }
        if (nps == 0) return pc;

        var up: LocalState = .{
            .sym = h[up_branch],
            .freq = 0,
            .succ = up_branch + 1,
        };
        if (ctxNumStats(h, pc) != 1) {
            if (pc <= self.sub.ptext) return NULL_OFF;
            var pp = ctxStats(h, pc);
            if (stSym(h, pp) != up.sym) {
                while (true) {
                    pp += STATE_SIZE;
                    if (pp + STATE_SIZE > h.len) return NULL_OFF; // panic guard
                    if (stSym(h, pp) == up.sym) break;
                }
            }
            const cf: u32 = @as(u32, stFreq(h, pp)) - 1;
            const s0: u32 = @as(u32, ctxSummFreq(h, pc)) -% ctxNumStats(h, pc) -% cf;
            up.freq = @intCast(1 + (if (2 * cf <= s0)
                @intFromBool(5 * cf > s0)
            else
                (2 * cf + 3 * s0 - 1) / (2 * s0)));
        } else {
            up.freq = stFreq(h, ctxOneState(pc));
        }

        while (true) {
            nps -= 1;
            pc = self.createChild(pc, ps[nps], up);
            if (pc == NULL_OFF) return NULL_OFF;
            if (nps == 0) break;
        }
        return pc;
    }

    fn updateModel(self: *Self) !void {
        const h = self.sub.heap;
        const fs = LocalState.load(h, self.found_state);
        var fs_succ = fs.succ;
        var p: u32 = NULL_OFF;

        if (fs.freq < MAX_FREQ / 4 and ctxSuffix(h, self.min_context) != NULL_OFF) {
            const pc = ctxSuffix(h, self.min_context);
            if (ctxNumStats(h, pc) != 1) {
                p = ctxStats(h, pc);
                if (stSym(h, p) != fs.sym) {
                    while (true) {
                        p += STATE_SIZE;
                        if (p + STATE_SIZE > h.len) return error.CorruptPpmData;
                        if (stSym(h, p) == fs.sym) break;
                    }
                    if (stFreq(h, p) >= stFreq(h, p - STATE_SIZE)) {
                        stSwap(h, p, p - STATE_SIZE);
                        p -= STATE_SIZE;
                    }
                }
                if (stFreq(h, p) < MAX_FREQ - 9) {
                    stSetFreq(h, p, stFreq(h, p) + 2);
                    ctxSetSummFreq(h, pc, ctxSummFreq(h, pc) +% 2);
                }
            } else {
                p = ctxOneState(pc);
                if (stFreq(h, p) < 32) stSetFreq(h, p, stFreq(h, p) + 1);
            }
        }

        if (self.order_fall == 0) {
            const succ = self.createSuccessors(true, p);
            if (succ == NULL_OFF) {
                try self.restartModelRare();
                self.esc_count = 0;
                return;
            }
            stSetSucc(h, self.found_state, succ);
            self.min_context = succ;
            self.max_context = succ;
            return;
        }

        h[self.sub.ptext] = fs.sym;
        self.sub.ptext += 1;
        var successor: u32 = self.sub.ptext;
        if (self.sub.ptext >= self.sub.fake_units_start) {
            try self.restartModelRare();
            self.esc_count = 0;
            return;
        }

        if (fs_succ != NULL_OFF) {
            if (fs_succ <= self.sub.ptext) {
                fs_succ = self.createSuccessors(false, p);
                if (fs_succ == NULL_OFF) {
                    try self.restartModelRare();
                    self.esc_count = 0;
                    return;
                }
            }
            self.order_fall -= 1;
            if (self.order_fall == 0) {
                successor = fs_succ;
                if (self.max_context != self.min_context) self.sub.ptext -= 1;
            }
        } else {
            stSetSucc(h, self.found_state, successor);
            fs_succ = self.min_context;
        }

        const ns: u32 = ctxNumStats(h, self.min_context);
        const s0: u32 = @as(u32, ctxSummFreq(h, self.min_context)) -% ns -% (@as(u32, fs.freq) - 1);
        var pc = self.max_context;
        while (pc != self.min_context) : (pc = ctxSuffix(h, pc)) {
            const ns1: u32 = ctxNumStats(h, pc);
            if (ns1 != 1) {
                if ((ns1 & 1) == 0) {
                    const grown = self.sub.expandUnits(ctxStats(h, pc), ns1 >> 1);
                    if (grown == NULL_OFF) {
                        try self.restartModelRare();
                        self.esc_count = 0;
                        return;
                    }
                    ctxSetStats(h, pc, grown);
                }
                const bump: u32 = @as(u32, @intFromBool(2 * ns1 < ns)) +
                    2 * @as(u32, @intFromBool((4 * ns1 <= ns) and
                        (ctxSummFreq(h, pc) <= 8 * ns1)));
                ctxSetSummFreq(h, pc, ctxSummFreq(h, pc) +% @as(u16, @truncate(bump)));
            } else {
                const np = self.sub.allocUnits(1);
                if (np == NULL_OFF) {
                    try self.restartModelRare();
                    self.esc_count = 0;
                    return;
                }
                stCopy(h, np, ctxOneState(pc));
                ctxSetStats(h, pc, np);
                var f: u32 = stFreq(h, np);
                if (f < MAX_FREQ / 4 - 1) f += f else f = MAX_FREQ - 4;
                stSetFreq(h, np, @intCast(f));
                ctxSetSummFreq(h, pc, @truncate(f + self.init_esc +
                    @intFromBool(ns > 3)));
            }
            var cf: u32 = 2 * @as(u32, fs.freq) * (@as(u32, ctxSummFreq(h, pc)) + 6);
            const sf: u32 = s0 +% ctxSummFreq(h, pc);
            if (cf < 6 * sf) {
                cf = 1 + @as(u32, @intFromBool(cf > sf)) + @intFromBool(cf >= 4 * sf);
                ctxSetSummFreq(h, pc, ctxSummFreq(h, pc) +% 3);
            } else {
                cf = 4 + @as(u32, @intFromBool(cf >= 9 * sf)) +
                    @intFromBool(cf >= 12 * sf) + @intFromBool(cf >= 15 * sf);
                ctxSetSummFreq(h, pc, ctxSummFreq(h, pc) +% @as(u16, @truncate(cf)));
            }
            const np2 = ctxStats(h, pc) + ns1 * STATE_SIZE;
            if (np2 + STATE_SIZE > h.len) return error.CorruptPpmData;
            stSetSucc(h, np2, successor);
            stSetSym(h, np2, fs.sym);
            stSetFreq(h, np2, @truncate(cf));
            ctxSetNumStats(h, pc, @intCast(ns1 + 1));
        }
        self.min_context = fs_succ;
        self.max_context = fs_succ;
    }

    fn decodeBinSymbol(self: *Self, c: u32) void {
        const h = self.sub.heap;
        const rs = ctxOneState(c);
        self.hi_bits_flag = self.hb2flag[stSym(h, self.found_state)];
        const freq_idx: usize = stFreq(h, rs) - 1;
        const suffix_ns: usize = ctxNumStats(h, ctxSuffix(h, c));
        const bs_idx: usize = @as(usize, self.prev_success) +
            self.ns2bsindx[suffix_ns - 1] +
            self.hi_bits_flag +
            2 * @as(usize, self.hb2flag[stSym(h, rs)]) +
            @as(usize, @intCast((self.run_length >> 26) & 0x20));
        const bs = &self.bin_summ[freq_idx][bs_idx];

        const shifted = self.coder.currentShiftCount(TOT_BITS) catch {
            // Range collapse: force the escape path; guards will surface it.
            self.found_state = NULL_OFF;
            self.coder.low_count = 0;
            self.coder.high_count = BIN_SCALE;
            return;
        };
        if (shifted < bs.*) {
            self.found_state = rs;
            if (stFreq(h, rs) < 128) stSetFreq(h, rs, stFreq(h, rs) + 1);
            self.coder.low_count = 0;
            self.coder.high_count = bs.*;
            bs.* = @truncate(@as(u32, bs.*) + INTERVAL - getMeanSpread(bs.*, PERIOD_BITS, 2));
            self.prev_success = 1;
            self.run_length += 1;
        } else {
            self.coder.low_count = bs.*;
            bs.* = @truncate(@as(u32, bs.*) - getMeanSpread(bs.*, PERIOD_BITS, 2));
            self.coder.high_count = BIN_SCALE;
            self.init_esc = ExpEscape[bs.* >> 10];
            self.num_masked = 1;
            self.char_mask[stSym(h, rs)] = self.esc_count;
            self.prev_success = 0;
            self.found_state = NULL_OFF;
        }
    }

    fn update1(self: *Self, c: u32, p_in: u32) void {
        const h = self.sub.heap;
        var p = p_in;
        self.found_state = p;
        stSetFreq(h, p, stFreq(h, p) + 4);
        ctxSetSummFreq(h, c, ctxSummFreq(h, c) +% 4);
        if (stFreq(h, p) > stFreq(h, p - STATE_SIZE)) {
            stSwap(h, p, p - STATE_SIZE);
            p -= STATE_SIZE;
            self.found_state = p;
            if (stFreq(h, p) > MAX_FREQ) self.rescale(c);
        }
    }

    fn decodeSymbol1(self: *Self, c: u32) !bool {
        const h = self.sub.heap;
        self.coder.scale = ctxSummFreq(h, c);
        var p = ctxStats(h, c);
        const count = try self.coder.currentCount();
        if (count >= self.coder.scale) return false;
        var hi_cnt: u32 = stFreq(h, p);
        if (count < hi_cnt) {
            self.coder.high_count = hi_cnt;
            self.prev_success = @intFromBool(2 * hi_cnt > self.coder.scale);
            self.run_length += self.prev_success;
            hi_cnt += 4;
            self.found_state = p;
            stSetFreq(h, p, @intCast(hi_cnt));
            ctxSetSummFreq(h, c, ctxSummFreq(h, c) +% 4);
            if (hi_cnt > MAX_FREQ) self.rescale(c);
            self.coder.low_count = 0;
            return true;
        } else if (self.found_state == NULL_OFF) {
            return false;
        }
        self.prev_success = 0;
        var i: u32 = ctxNumStats(h, c) - 1;
        while (true) {
            p += STATE_SIZE;
            if (p + STATE_SIZE > h.len) return error.CorruptPpmData;
            hi_cnt += stFreq(h, p);
            if (hi_cnt > count) break;
            i -= 1;
            if (i == 0) {
                self.hi_bits_flag = self.hb2flag[stSym(h, self.found_state)];
                self.coder.low_count = hi_cnt;
                self.char_mask[stSym(h, p)] = self.esc_count;
                self.num_masked = ctxNumStats(h, c);
                self.found_state = NULL_OFF;
                var j: u32 = self.num_masked - 1;
                var pp = p;
                while (j != 0) : (j -= 1) {
                    pp -= STATE_SIZE;
                    self.char_mask[stSym(h, pp)] = self.esc_count;
                }
                self.coder.high_count = self.coder.scale;
                return true;
            }
        }
        self.coder.high_count = hi_cnt;
        self.coder.low_count = hi_cnt - stFreq(h, p);
        self.update1(c, p);
        return true;
    }

    fn update2(self: *Self, c: u32, p: u32) void {
        const h = self.sub.heap;
        self.found_state = p;
        stSetFreq(h, p, stFreq(h, p) + 4);
        ctxSetSummFreq(h, c, ctxSummFreq(h, c) +% 4);
        if (stFreq(h, p) > MAX_FREQ) self.rescale(c);
        self.esc_count +%= 1;
        self.run_length = self.init_rl;
    }

    fn makeEscFreq2(self: *Self, c: u32, diff: u32) *See2 {
        const h = self.sub.heap;
        const num_stats: u32 = ctxNumStats(h, c);
        if (num_stats != 256) {
            const suffix_ns: u32 = ctxNumStats(h, ctxSuffix(h, c));
            const idx1: usize = self.ns2indx[diff - 1];
            const idx2: usize = @as(usize, @intFromBool(diff < suffix_ns - num_stats)) +
                2 * @as(usize, @intFromBool(ctxSummFreq(h, c) < 11 * num_stats)) +
                4 * @as(usize, @intFromBool(self.num_masked > diff)) +
                self.hi_bits_flag;
            const psee = &self.see2[idx1][idx2];
            self.coder.scale = psee.getMean();
            return psee;
        }
        self.coder.scale = 1;
        return &self.dummy_see2;
    }

    fn decodeSymbol2(self: *Self, c: u32) !bool {
        const h = self.sub.heap;
        var i: u32 = ctxNumStats(h, c) - self.num_masked;
        const psee = self.makeEscFreq2(c, i);
        var ps: [256]u32 = undefined;
        var nps: usize = 0;
        var hi_cnt: u32 = 0;
        var p: u32 = ctxStats(h, c) -% STATE_SIZE;
        while (true) {
            while (true) {
                p +%= STATE_SIZE;
                if (p + STATE_SIZE > h.len) return error.CorruptPpmData;
                if (self.char_mask[stSym(h, p)] != self.esc_count) break;
            }
            hi_cnt += stFreq(h, p);
            if (nps >= 256) return error.CorruptPpmData;
            ps[nps] = p;
            nps += 1;
            i -= 1;
            if (i == 0) break;
        }
        self.coder.scale +%= hi_cnt;
        const count = try self.coder.currentCount();
        if (count >= self.coder.scale) return false;

        var pi: usize = 0;
        p = ps[0];
        if (count < hi_cnt) {
            var acc: u32 = 0;
            while (true) {
                acc += stFreq(h, p);
                if (acc > count) break;
                pi += 1;
                if (pi >= nps) return error.CorruptPpmData;
                p = ps[pi];
            }
            self.coder.high_count = acc;
            self.coder.low_count = acc - stFreq(h, p);
            psee.update();
            self.update2(c, p);
        } else {
            self.coder.low_count = hi_cnt;
            self.coder.high_count = self.coder.scale;
            for (ps[0..nps]) |sp| {
                self.char_mask[stSym(h, sp)] = self.esc_count;
            }
            psee.summ +%= @truncate(self.coder.scale);
            self.num_masked = ctxNumStats(h, c);
        }
        return true;
    }

    fn clearMask(self: *Self) void {
        self.esc_count = 1;
        @memset(&self.char_mask, 0);
    }

    /// ModelPPM::DecodeInit. The FIRST byte read here is the same byte whose
    /// top bit was the PPM-block flag in ReadTables30 — the reference peeks
    /// that flag without consuming, so bits 0-6 of the flag byte are the
    /// order/reset/escape fields. Consuming even one flag bit before calling
    /// this desynchronises the entire stream.
    pub fn decodeInit(self: *Self, br: *BitReader, esc_char: *u8) !bool {
        var max_order: u32 = RangeCoder.getByte(br);
        const reset = (max_order & 0x20) != 0;
        var max_mb: u32 = 0;
        if (reset) {
            max_mb = RangeCoder.getByte(br);
        } else {
            if (self.sub.sub_allocator_size == 0) return false;
        }
        if (max_order & 0x40 != 0) esc_char.* = @intCast(RangeCoder.getByte(br));
        self.coder.initDecoder(br);
        if (reset) {
            max_order = (max_order & 0x1f) + 1;
            if (max_order > 16) max_order = 16 + (max_order - 16) * 3;
            if (max_order == 1) {
                self.sub.stop();
                return false;
            }
            if (!self.sub.start(max_mb + 1)) return false;
            try self.startModelRare(max_order);
        }
        return self.min_context != NULL_OFF;
    }

    /// ModelPPM::DecodeChar. Returns the decoded byte, or error on corrupt
    /// data (the reference's -1).
    pub fn decodeChar(self: *Self, br: *BitReader) !u32 {
        const h = self.sub.heap;
        if (self.min_context <= self.sub.ptext or self.min_context > self.sub.heap_end)
            return error.CorruptPpmData;
        if (ctxNumStats(h, self.min_context) != 1) {
            const stats = ctxStats(h, self.min_context);
            if (stats <= self.sub.ptext or stats > self.sub.heap_end)
                return error.CorruptPpmData;
            if (!try self.decodeSymbol1(self.min_context))
                return error.CorruptPpmData;
        } else {
            self.decodeBinSymbol(self.min_context);
        }
        self.coder.decodeUpdate();
        while (self.found_state == NULL_OFF) {
            self.coder.normalize(br);
            while (true) {
                self.order_fall += 1;
                self.min_context = ctxSuffix(h, self.min_context);
                if (self.min_context <= self.sub.ptext or
                    self.min_context > self.sub.heap_end)
                    return error.CorruptPpmData;
                if (ctxNumStats(h, self.min_context) != self.num_masked) break;
            }
            if (!try self.decodeSymbol2(self.min_context))
                return error.CorruptPpmData;
            self.coder.decodeUpdate();
        }
        const symbol: u32 = stSym(h, self.found_state);
        if (self.order_fall == 0 and stSucc(h, self.found_state) > self.sub.ptext) {
            const succ = stSucc(h, self.found_state);
            self.min_context = succ;
            self.max_context = succ;
        } else {
            try self.updateModel();
            if (self.esc_count == 0) self.clearMask();
        }
        self.coder.normalize(br);
        return symbol;
    }
};

// ============================================================================
// Tests. Real verification is differential: the committed PPMd fixtures must
// decode byte-identical to unrar, and the unit suite's role here is only the
// pieces with closed-form expectations. The previous suite asserted a
// simplified stand-in against itself, which is exactly how a non-functional
// PPMd survived 18 green tests.
// ============================================================================

const testing = std.testing;

test "RangeCoder init reads 4 bytes into code" {
    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    var br = BitReader.init(&data);
    var rc: RangeCoder = undefined;
    rc.initDecoder(&br);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), rc.code);
    try testing.expectEqual(@as(u32, 0), rc.low);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), rc.range);
}

test "SubAllocator unit tables match the reference construction" {
    var sub = SubAllocator.initEmpty(testing.allocator);
    defer sub.stop();
    try testing.expect(sub.start(1));
    sub.initSubAllocator();
    // Indx2Units: 1,2,3,4, 6,8,10,12, 15,18,21,24, 28,32,...
    try testing.expectEqual(@as(u8, 1), sub.indx2units[0]);
    try testing.expectEqual(@as(u8, 4), sub.indx2units[3]);
    try testing.expectEqual(@as(u8, 6), sub.indx2units[4]);
    try testing.expectEqual(@as(u8, 12), sub.indx2units[7]);
    try testing.expectEqual(@as(u8, 15), sub.indx2units[8]);
    try testing.expectEqual(@as(u8, 24), sub.indx2units[11]);
    try testing.expectEqual(@as(u8, 28), sub.indx2units[12]);
    try testing.expectEqual(@as(u8, 128), sub.indx2units[N_INDEXES - 1]);
    // Units2Indx must be the inverse rounding up.
    for (0..128) |k| {
        const idx = sub.units2indx[k];
        try testing.expect(sub.indx2units[idx] >= k + 1);
        if (idx > 0) try testing.expect(sub.indx2units[idx - 1] < k + 1);
    }
}

test "SubAllocator alloc/free round-trips through the free list" {
    var sub = SubAllocator.initEmpty(testing.allocator);
    defer sub.stop();
    try testing.expect(sub.start(1));
    sub.initSubAllocator();
    const a = sub.allocUnits(2);
    try testing.expect(a != NULL_OFF);
    sub.freeUnits(a, 2);
    const b = sub.allocUnits(2);
    try testing.expectEqual(a, b); // freelist returns the same block
    const c = sub.allocContext();
    try testing.expect(c != NULL_OFF);
    try testing.expect(c > b);
}

test "See2 getMean and update follow the reference arithmetic" {
    var s = See2.init(10);
    try testing.expectEqual(@as(u16, 80), s.summ);
    try testing.expectEqual(@as(u8, 3), s.shift);
    try testing.expectEqual(@as(u32, 10), s.getMean());
    try testing.expectEqual(@as(u16, 70), s.summ);
    // update: count 4->3->2->1, then doubles summ, count = 3<<shift, shift++
    s.update();
    s.update();
    s.update();
    const before = s.summ;
    s.update();
    try testing.expectEqual(before *% 2, s.summ);
    try testing.expectEqual(@as(u8, 4), s.shift);
    try testing.expectEqual(@as(u8, 3 << 3), s.count);
}

test "model restart builds the 256-symbol root and BinSumm per reference" {
    var m = PpmModel.init(testing.allocator);
    defer m.deinit();
    try testing.expect(m.sub.start(1));
    try m.startModelRare(4);
    const h = m.sub.heap;
    try testing.expectEqual(@as(u16, 256), ctxNumStats(h, m.min_context));
    try testing.expectEqual(@as(u16, 257), ctxSummFreq(h, m.min_context));
    const stats = ctxStats(h, m.min_context);
    try testing.expectEqual(@as(u8, 0), stSym(h, stats));
    try testing.expectEqual(@as(u8, 255), stSym(h, stats + 255 * STATE_SIZE));
    // BinSumm[i][k] = BIN_SCALE - InitBinEsc[k]/(i+2), k folded mod 8
    try testing.expectEqual(@as(u16, @truncate(BIN_SCALE - InitBinEsc[0] / 2)), m.bin_summ[0][0]);
    try testing.expectEqual(@as(u16, @truncate(BIN_SCALE - InitBinEsc[3] / 7)), m.bin_summ[5][3]);
    try testing.expectEqual(m.bin_summ[5][3], m.bin_summ[5][3 + 8]);
    // NS2Indx, traced from the reference loop: 0,1,2,3,4,4,5,5,5,6,...
    try testing.expectEqual(@as(u8, 2), m.ns2indx[2]);
    try testing.expectEqual(@as(u8, 3), m.ns2indx[3]);
    try testing.expectEqual(@as(u8, 4), m.ns2indx[4]);
    try testing.expectEqual(@as(u8, 4), m.ns2indx[5]);
    try testing.expectEqual(@as(u8, 5), m.ns2indx[8]);
}
