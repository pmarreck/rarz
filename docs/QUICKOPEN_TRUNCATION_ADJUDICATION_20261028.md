# Seventeen quick-open truncation disagreements

All 17 stricter cases in the legacy RAR5 volume truncation sweep remove bytes
from a declared quick-open (`QO`) service payload. Their complete service
headers remain present, including the data lengths. The file payloads precede
the cut. UNRAR with quick-open disabled returns success; rarz's structural
validator rejects the missing declared service bytes.

This establishes ancillary structural truncation. It does not establish
damaged extracted file contents or turn reference success into a general
damage oracle. The existing `stricter` classifications and historical counts
remain intact. These are fixed adjudicated regressions, not new statistical
samples.

## Exact boundaries

Offsets are zero-based; intervals end at an exclusive byte offset.

| Fixture volume | Suffix removed | QO header start | Data start | Declared data end | Bytes missing from QO |
| --- | ---: | ---: | ---: | ---: | ---: |
| `rar5_vol_store.part1.rar` | 24 / 128 | 511842 | 511861 | 511978 | 2 / 106 |
| `rar5_vol_store.part2.rar` through `part5.rar` | 24 each | 511905 | 511924 | 511984 | 8 each |
| `rar5_vol_m3.part01.rar` | 24 | 51105 | 51124 | 51184 | 8 |
| `rar5_vol_large.part1.rar` through `part5.rar` | 24 / 128 each | 511850 | 511869 | 511984 | 8 / 112 each |

The [RAR5 format specification](https://www.rarlab.com/technote.htm) defines
separate header and data lengths. These records have a four-byte CRC,
one-byte header-size field of 14, and a 14-byte body, totaling 19 bytes.
Their type is 3, flags are 6, and the name is `QO`. Their packed-size VINTs
are `f5 00`, `bc 00`, or `f3 00`, declaring 117, 60, or 115 payload bytes.
The complete header survives each cut, but its declared payload does not.
Quick-open is an optional cache; tolerating its loss while reading files
does not make the surviving size declaration accurate.

## Persistent control

`tests/cli/test_quickopen_truncation.sh` checks the source hashes against the
committed fixture manifest and compares each entire QO header with literal
independent fixture bytes. It calculates the declared range without invoking
rarz's parser, checks the shortfall, reproduces the exact suffix deletion
through corruption-reader, and verifies that the mutant is precisely the
original prefix. Both validators must accept each pristine set. The 17
specific reference-valid/rarz-damaged outcomes must remain accounted for.

Each mutation emits a versioned replay record and input/mutant hashes. No
generic allowance for unrelated stricter results is justified by this table.
Service-payload verification coverage remains a separate consumer-contract
issue.

Focused replay passed all 17 cases. The complete 505-unit/CLI/v70 suite and
optimized build then passed with this control included. The admitted Linux
runtime peaked at 11,838,824,448 bytes. No decoder code changed in this
adjudication.
