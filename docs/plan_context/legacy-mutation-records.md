# Replayable legacy mutation gates

The older mutation loops now use the pinned corruption-reader consumer API.
Their original positions, byte values, and suffix lengths remain unchanged.
They are fixed regressions, not additional statistical samples or replacements
for the six assessment profiles.

`tests/support/legacy-mutation.bash` defines three explicit profile names:

| Operator version | Exact effect |
| --- | --- |
| `overwrite-byte-v1` | Replace one byte at the recorded zero-based offset with the recorded value; an unchanged overwrite is permitted and labeled. |
| `xor-byte-v1` | XOR one byte at the recorded zero-based offset with the recorded mask. |
| `drop-suffix-v1` | Delete the recorded positive number of trailing bytes, retaining at least one byte. |

The helper emits JSON with schema `rarz-legacy-mutation/v1`, input and mutant
SHA-256 values, an `unchanged` flag, and the complete corruption-reader case
record. Custom profiles use master seed zero and round zero; every location
and action is explicit, so these profiles make no random choices. The record
retains the mutator's own profile, derivation, and RNG version fields.
Extract `.record` and use `corruption-reader apply --case` with the matching
input to replay it. The complete test runner retains each suite's output log.
Generated writer-smoke inputs still require their generating fixture recipe;
a hash alone does not preserve the original input bytes.

The migration covers solid, compressed, stored, verification, RAR4/RAR5
volume, and v70 legacy loops. V70 retains XOR `0xa5` at 41% and 83% of input
length, correctly labeled as a four-bit byte mutation. It is not the canonical
single-bit sniper profile. Large inputs stream into private disk-backed
outputs; hashes add complete input/output reads. This remains part of the
existing bounded large-corpus exception, not a fast unit-test claim.

## Outcome controls

The common reference adapter disables password prompts and quick-open cached
headers. Archive classifications remain separate from execution evidence.
The adapter retains exit status, stdout, stderr, and an execution category:
completed, timeout, crash, killed, launch-error, signaled, or reference
memory-error. These categories follow shell exit conventions, with remaining
signals kept in a generic category rather than assuming an exhaustive crash
taxonomy. Exit 137 cannot establish an OOM kill without an external resource
receipt. A completed process
can still have an inconclusive archive verdict. No execution failure counts as
detected damage.

Persistent tests sweep all 256 shell statuses for both tools, inspect the real
reference adapter's arguments, and retain its memory-error observation even
with misleading success text. Exact-byte controls independently assert all
three transformations, replay their emitted records, label an unchanged
overwrite, refuse invalid bounds and source aliases, and preserve the source.

Focused execution initially exposed an inherited interactive `find` function
that referenced the old HOME after isolation. Removing exported functions,
as the complete runner already does, restored the focused harness. All eleven
affected focused suites and the Nix classifier/v70-driver checks then passed.
This was a harness setup failure, not a decoder regression.

The complete integrated run passed 503 unit tests, all CLI suites, and both
real v70 mutations. Native macOS ARM64 classifier and v70-driver checks passed,
as did the optimized build. The v70 log's creation-to-final-write interval was
424 seconds versus 386 seconds in the preceding run; the added streaming
mutation and SHA-256 passes cost additional I/O. These single observations
are not a performance regression estimate. Queue wait and Nix preparation
preceded the admitted runtime and are separate from this measured gate time.
The complete log interval was 852 seconds: 370 seconds of preparation and
admission wait combined, then 482 seconds of admitted execution. These values
come from the log creation/final-write timestamps; preparation and queue wait
were not separately timestamped in this run.
