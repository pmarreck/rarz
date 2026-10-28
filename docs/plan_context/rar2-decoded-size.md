# RAR2 decoded-size overshoot

The seed-44 campaign's case 214 changes the last compressed match for
`text1.txt` in a RAR 2.90 producer fixture. Independent UNRAR extraction produces
7,214 bytes and reports checksum damage. rarz previously clipped the result to
the declared 7,212 bytes. That prefix equals the pristine file, so its checksum
passes and the corruption was missed.

The v20 decoder now rejects a decoded length larger than the entry's declared
length before either buffered or streaming output reports success. Streaming
callers can already have received a prefix; refusal is not an atomic-output
promise. The sink remains bounded to the declared size.

Two unit regressions first observed successful decoding where refusal was
expected. One reproduces the exact campaign mutation with pristine length and
CRC controls at two adequate dictionary sizes. The other uses an existing
independent 767,356-byte producer entry and a 64 KiB dictionary to exercise
streaming refusal when a match crosses a shortened declared end. Its full-size
control still matches the producer checksum. The CLI regression independently
checks the exact mutant hash and UNRAR damage verdict, then requires rarz to
report damage. It failed against the campaign binary and passes against the
fixed binary under the filesystem isolation boundary.

The development checkout passed all 466 units and the isolated CLI replay.
Integrated acceptance passed all 471 units, every CLI suite, and the intact
and two damaged v70 controls. Peak runtime memory was 11,840,131,072 bytes
under the unchanged 16 GiB limit. Native macOS unit/package checks and the
native build passed. Shared runtime admission accounted for about 17 minutes
of queue wait before execution; no resource cap was bypassed.
The [campaign report](../COVERAGE_20261028_SEED44.md) retains its observed miss;
these fixed regression replays are not new statistical samples.
