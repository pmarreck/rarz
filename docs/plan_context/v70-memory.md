# Large-dictionary memory investigation

The retained corpus has 4,733,345,812 compressed bytes and 7,071,596,544
uncompressed bytes. Its declared dictionary is 8,589,934,592 bytes. The CLI
`read_file` allocates and reads the whole input. `rarz_validate` borrows that
buffer; the single-volume policy path borrows the packed payload and hashes
decoded output through a sink, without allocating a second input or a complete
output buffer. Filter staging is a separate allocation when filters occur.

Before the change, `Window.init` zeroed the entire dictionary. Input plus that
dictionary alone requires 13,323,280,404 bytes (12.41 GiB), explaining the earlier
12 GiB throttling threshold. The observed cgroup peak was 13,356,277,760 bytes.
These are different measurements: requested buffers versus whole-cgroup memory.

Removing only the explicit zero-fill is insufficient in ReleaseSafe. The pinned
Zig allocator's `alloc` and `free` wrappers also write `undefined` over the entire
buffer. The window now pairs `rawAlloc` with `rawFree`, preserving the allocator
and its ownership tracking while avoiding those wrapper writes. Only produced
history may be read. Both output methods now reject history that was never
written, including after reset. Existing match/get-byte guards prevent reads
before the beginning of history.

The full virtual dictionary remains reserved. For this corpus, input plus
produced history is 11,804,942,356 bytes (10.99 GiB), before allocator, filter,
runtime, and filesystem overhead. This is a prediction, not a measured new peak
or an admission guarantee. An allocator may itself initialize storage; the
production page allocator does not require that. The change does not make
arbitrary large dictionaries cheap or change the public resource contract.

Read-only input mapping was considered. It could remove the private input copy,
but requires OS-specific ownership and concurrent-truncation handling. A chunked
input API would change the existing contiguous-buffer boundary and is deferred.
The current change targets unnecessary dictionary writes first. SIMD work is
deferred: faster full-buffer writes still make unused pages resident.

## Regression evidence

Two persistent tests failed before implementation: initialization changed a
prefilled allocator buffer, and output accepted unwritten history. The Nix
ReleaseSafe check then passed all 450 unit tests. The lifecycle test also checks
that teardown leaves untouched backing bytes unchanged and releases ownership.
Compilation and execution were combined in this check; its approximately
100-second build phase is not a test-execution timing claim.

The large-corpus driver formerly mutated the source in place and counted process
errors as successful damage detection. Seven tiny real-driver controls now
require private copies, both pristine validators, two confirmed damage verdicts,
and failure for missing inputs or inconclusive outcomes. They failed against the
old driver and passed after correction in a Nix sandbox. These controls do not
execute the large corpus or prove its revised peak memory.

Large mutation scratch must be disk-backed; set `RARZ_CORPUS_TMPDIR` to a
disposable disk-backed scratch parent. The driver refuses multi-GiB copies on
tmpfs, where the copy would consume the decoder's memory budget. The corpus is
read-only input, and per-run scratch is removed without restoring over it.

The prepared ReleaseSafe artifact passed one pristine-corpus probe on October
27, returning VALID with exit 0 within a 180-second execution bound. The last
sampled cgroup memory was 9,221,152,768 bytes; final peak telemetry disappeared
when the scope closed and the receipt contains null. This is a lower-bound
sample, not a peak measurement. The installed admission wrapper now enforces a
16 GiB hard limit with no separate 12 GiB throttle; the investigation did not
change that configuration. Full-suite acceptance and a retained final peak
remain outstanding.

## Complete gate and runner findings

The subsequent complete test invocation passed all 450 units and the full v70
gate: both validators accepted the pristine archive, and both designated
mutations were reference-confirmed damaged and rejected by rarz. The runtime
captured `memory.peak` before its scope closed: 11,840,827,392 bytes (11.03 GiB).
That peak covers the runtime test scope, not just decoder allocations. No memory
limit was raised by this change. The large gate takes minutes; it does not meet
the shared five-second test-execution budget. Fixture minimization or an explicit
long-campaign policy remains necessary before making a latency-conformance claim.

Six other suites failed because an exported interactive `find` function tried
to use a command beneath the newly private HOME. A persistent regression first
reproduced the inherited-function defect, then passed after the runner removed
exported shell functions before invoking adapters. A separate red-first control
ensures package-smoke failure does not suppress required runtime suites.
The first invocation's exit 1 remains failure evidence.

A subsequent review preserved the legacy circular-indexing contract of
`copyToOutput`: older callers can request more than one ring of repeated output
and ignore its returned count. The stricter resident-history bound belongs to
`emitTo`; both methods reject unwritten history. A new regression failed before
that correction and passed afterward, bringing the unit count to 451.

The corrected complete `./test` finished successfully on October 27 at
22:12 EDT: all 451 units, every CLI suite, and the pristine/two-mutation v70
gate passed. The retained runtime peak was 11,841,957,888 bytes (11.03 GiB).
Source files were frozen during this acceptance run. Later build-layout changes
require their own final acceptance and do not alter this historical result.

After correcting assessment selection for the new build layout, the complete
migration candidate also passed all 451 units and every CLI suite, including
the full v70 gate. Its retained runtime cgroup peak was 11,837,341,696 bytes
(11.02 GiB). An earlier migration attempt was interrupted to correct the stale
assessment path and is not counted as complete acceptance. Correctness passed;
the multi-minute corpus gate remains a test-latency finding.
