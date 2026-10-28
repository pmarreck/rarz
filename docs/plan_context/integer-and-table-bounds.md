# Integer and Huffman table bounds

A RAR VINT reader discarded overflowing high bits in the tenth byte. Its new
regression expected refusal but observed zero. The reader now accepts only a
final tenth byte of zero or one. Tests classify all 256 possible tenth bytes
with both zero and maximal lower-bit prefixes, preserving valid padded values
and refusing continuation beyond 64 bits. Canonical encodings round-trip at
every bit-width boundary through the full u64 range; padding is intentionally
normalized by the encoder.

RAR5/RAR7 Huffman table parsing accepted an initial repeat symbol before any
code length existed. Its regression expected InvalidData but observed success.
Both short and long repeats now require a predecessor. Controls cover both
format variants and repeat symbols, all-direct tables, and valid repeats after
the first length. These are table-reader controls; the full producer corpus
supplies archive-level compatibility evidence.

The independent development checkout passed 464 tests with these four new
regressions. After integration, complete `./test` passed all 469 unit tests,
the CLI suites, and the large v70 controls. Runtime peak memory was
11,838,009,344 bytes under the unchanged 16 GiB admission limit.
