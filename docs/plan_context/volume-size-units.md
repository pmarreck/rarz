# Volume-size units

Volume-size parsing now matches the producer's decimal and binary unit syntax.
Direct RAR 7.20 creation controls produced these first-volume sizes:

| Argument | Bytes |
|---|---:|
| `-v2k` | 2048 |
| `-v2K` | 2000 |
| `-v2048b` or `-v2048B` | 2048 |
| `-v2` | 2000 |

Lowercase `k/m/g/t` uses powers of 1024; uppercase `K/M/G/T` uses powers of
1000. Both `b` and `B` mean bytes. No suffix means decimal kilobytes. Earlier
rarz versions used binary units for both letter cases and treated a bare
number as bytes. Callers needing the old byte interpretation must append `b`.
The existing minimum volume size remains 1024 bytes.

The RAR 7.20 distribution's `rar.txt`, under `-v<size>`, independently
documents these units and the default of thousands of bytes. Its fractional
sizes, size autodetection, and per-volume lists are outside this integer-size
change; the broader argument-compatibility matrix remains open.

Parsing rejects signs, whitespace, noninteger notation, unknown or repeated
suffixes, zero, conversion overflow, and unit multiplication overflow. Tests
exercise the largest representable input and its successor for every unit.
Those boundary tests use a deliberately missing source file, proving numeric
acceptance or rejection without allocating a huge volume buffer.

Independent producer and candidate controls check actual volume sizes. The
large-unit arithmetic boundaries are checked separately from those small
filesystem cases. These are CLI interpretation rules; the C library's volume
configuration continues to accept an explicit byte count.

Acceptance on 2026-10-28 passed the complete `./test` entry point, including
479 unit tests, every CLI suite, and the large v70 corpus/mutation gate.
Native macOS unit/package checks and the optimized `./build` also passed.
