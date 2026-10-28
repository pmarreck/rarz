# RAR5 filename encoding

The RAR5 parser now rejects invalid UTF-8 in file and service names with
`ParseError.InvalidUtf8`. Names retain their exact encoded bytes, including
combining sequences; this does not normalize Unicode or change RAR4 filename
handling. The [RAR5 format specification](https://www.rarlab.com/technote.htm)
defines this field as UTF-8.

Encoding validation remains independent of compression support. A correctly
encoded name with an unknown compression algorithm still parses, preserving
the algorithm identifier for later unsupported-decoding handling. A malformed
name fails during header parsing. Existing C structures and layouts remain
unchanged; parser failures continue through the existing open/validation paths.

The regression first demonstrated acceptance of invalid byte sequences. Tests
then classify all 65,280 nonzero one-byte and two-byte candidates, plus selected
three/four-byte boundaries: overlong forms, surrogate encodings, maximum scalar
values, out-of-range scalars, and truncated sequences. Valid noncharacters and
combining sequences remain accepted. These are encoding tests, not a new
filesystem-path or Unicode-normalization policy.

Independent RAR 7.20 store/compressed archives contain ASCII, accented, Greek,
emoji, and decomposed names. UNRAR accepts both archives; rarz validates,
verifies, and extracts their original names and file bytes. The runtime CLI
control uses private files inside the existing isolation boundary.

Acceptance on 2026-10-28 passed all 479 unit tests, every CLI suite, the v70
corpus/mutation gate, native macOS unit/package checks, and `./build`.
