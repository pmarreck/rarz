//! RAR5 compression module root.
//!
//! Re-exports all compression submodules for convenient access.

pub const bitwriter = @import("bitwriter.zig");
pub const huffman_encoder = @import("huffman_encoder.zig");
pub const slot_tables = @import("slot_tables.zig");
pub const match_finder = @import("match_finder.zig");
pub const pack50 = @import("pack50.zig");

pub const BitWriter = bitwriter.BitWriter;
pub const LzToken = match_finder.LzToken;
pub const MatchFinder = match_finder.MatchFinder;

/// Compress data into a RAR5 compressed block.
pub const compressBlock = pack50.compressBlock;
