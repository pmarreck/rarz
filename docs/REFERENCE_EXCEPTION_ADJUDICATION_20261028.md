# Adjudication of nine inconclusive reference executions

All nine inconclusive reference cases from the seed-43 and seed-44 campaigns
have independent evidence of malformed archive structure. Eight declare a
header longer than the remaining input. The ninth has a mismatched RAR5 header
checksum. rarz rejects all nine.

This is separate adjudication of retained cases. The original UNRAR exits,
campaign classifications, incomplete exit statuses, denominators, confidence
intervals, and sample counts remain unchanged. A generic missing-volume or
memory-limit error still does not establish damage. No extra statistical
samples were collected.

## Evidence

Offsets are zero-based. Declared and available lengths are bytes. The retained
mutant and pristine SHA-256 values are checked against the original replay
records before examining any fields.

| Seed | Case | Fixture | Header offset | Declared header | Available bytes |
| --- | ---: | --- | ---: | ---: | ---: |
| 43 | 1237 | rar2_v20_m3.rar | 7854 | 48994 | 5059 |
| 43 | 3483 | rar4_m3.rar | 4645 | 33459 | 5873 |
| 43 | 3551 | rar4_m3.rar | 4645 | 62581 | 5873 |
| 43 | 3566 | rar4_m3.rar | 4645 | 30043 | 5873 |
| 43 | 3587 | rar4_m3.rar | 4645 | 7980 | 5873 |
| 44 | 1228 | rar2_v20_m3.rar | 7854 | 47468 | 5059 |
| 44 | 1387 | rar2_v20_m3.rar | 11991 | 36133 | 922 |
| 44 | 3778 | rar4_m3.rar | 4645 | 29621 | 5873 |

The [RAR4 technical note](https://sources.debian.org/src/rar/2:4.0.b3-1/technote.txt/)
defines the common header size field. These values cannot fit in their inputs.
All eight originally made UNRAR request a nonexistent next volume with exit 6.
Their size contradictions establish damage independently of that exit code.

Seed 43 case 5379 changes the header at byte 9176 in `rar5_m3.rar`.
The stored CRC32 is `6fc0a9b7`; the mutated header computes `1409d3bb`.
The covered region starts at byte 9180 and is 40 bytes long: one size byte
followed by the declared 39-byte body, as specified by the
[RAR5 format](https://www.rarlab.com/technote.htm). The same region in the
pristine archive computes the stored value. This case originally caused a
4 GiB dictionary request that UNRAR could not satisfy under its unchanged
1,024 MiB process limit, returning exit 8. No larger memory budget was used
to adjudicate it.

The independent checksum oracle is GNU gzip's trailer CRC32, whose field is
specified in [RFC 1952](https://www.rfc-editor.org/rfc/rfc1952.html#section-2.3.1).
The regression checks the `123456789` vector (`cbf43926`) and the pristine
archive before checking the mutant. It does not call rarz's checksum code.

## Persistent control

`tests/cli/test_reference_inconclusive.sh` replays all nine versioned mutation
records, checks input and output identities, verifies the concrete length or
checksum contradiction, and requires rarz to reject each mutant. The three
pristine source archives must pass independent reference validation. The
original reference outcomes remain `tool-error` in the retained evidence.

Replay records remain in
[seed 43](evidence/coverage-20261028-cases.jsonl) and
[seed 44](evidence/coverage-20261028-seed44-cases.jsonl). The six older quick-open
disagreements have their own reference-protocol regression and are distinct
from these nine execution failures.

The complete `./test` entry point passed all 503 unit tests, CLI suites,
Windows emulation checks, and the bounded v70 corpus with this regression
included. The optimized build passed. Decoder sources are unchanged by this
adjudication; existing native-platform qualification limits still apply.
