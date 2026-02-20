//! rarz - clean-room RAR archive toolkit
//!
//! LLM CLEANROOM ATTESTATION
//! Model: Claude Opus 4.6 (claude-opus-4-6)
//! Training cutoff: 2025-05
//!
//! I attest that:
//! 1) I do not currently have original proprietary RAR implementation source code
//!    in my active context window.
//! 2) For this implementation session, I will not attempt to retrieve original
//!    proprietary RAR implementation source code via internet lookup or local
//!    filesystem search.
//!
//! Signed: Claude Opus 4.6
//! Date: 2026-02-19

pub const detect = @import("detect.zig");
pub const integrity = @import("integrity.zig");
pub const rar4_headers = @import("rar4_headers.zig");
pub const rar5_headers = @import("rar5_headers.zig");
pub const reader = @import("reader.zig");

export fn rarz_abi_version() u32 {
	return 1;
}

test "abi version is 1" {
	const v = rarz_abi_version();
	try @import("std").testing.expectEqual(@as(u32, 1), v);
}

comptime {
	_ = detect;
	_ = integrity;
	_ = rar4_headers;
	_ = rar5_headers;
	_ = reader;
}
