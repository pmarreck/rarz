# RAR5 header and extra-record bounds

The [RAR5 format specification](https://www.rarlab.com/technote.htm) places the
extra area at the end of a header. Each record declares its own extent,
including its type. Unknown record types must be skipped within that extent.

Persistent regressions demonstrated six failures before the corrections:

- Block-specific fields could consume bytes after the declared header.
- The raw BLAKE2sp reader could borrow hash bytes from a following record.
- The allocating extra-record parser accepted incomplete framing as a prefix.
- File extras were read immediately after the name instead of at the header end.
- Block iteration accepted malformed extra framing, including on unknown blocks.
- An impossible declared payload size could advance the iterator past the input.

The iterator now bounds the header and payload before arithmetic or traversal,
validates record framing, and limits main/end bodies before the extra area.
File parsing anchors extras at the header tail and checks name length against
the remaining body. Unknown future body bytes and well-framed record types
remain skippable. A shared bounded record reader serves allocating traversal,
encryption-record recognition, and raw hash extraction.

Tests cover truncated bodies across main/file/service/end blocks, malformed
extras across known and unknown blocks, maximum unsigned payload sizes,
multibyte unknown record types, every truncation of a hash record, and a hash
followed by another record. Existing producer fixtures remain the independent
compatibility controls. This work validates framing; it does not add decoders
for unknown record payloads or change historical coverage measurements.

Acceptance on 2026-10-28 passed all 486 unit tests, every CLI suite, the v70
corpus/mutation gate, native macOS unit/package checks, and `./build`.
