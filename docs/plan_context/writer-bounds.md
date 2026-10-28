# Writer buffer and volume bounds

The writer accepted 4,096-byte names but stored names and metadata together in
4,096-byte scratch buffers. A new boundary matrix crashed before the fix. It
now covers 4,070, 4,080, 4,095, and 4,096-byte names across stored/compressed
files, directories, and both volume APIs, checking returned names and CRCs.
Scratch capacity includes the maximum encoded metadata size. Volume APIs also
enforce the existing filename limit; their oversized-name regression crashed
before the new guard.

An impossible volume size could repeatedly emit empty volumes. An injected
allocation limit made that failure finite and reproducible: the old code
returned OutOfMemory instead of VolumeTooSmall. Zero capacity also crashed on
division. Both now return VolumeTooSmall, as do capacities below archive
framing overhead. Allocation cleanup remains checked by the test allocator.

The compressed writer also omitted the caller-buffer capacity check. Its new
regression crashed before the fix. It now computes the actual archive size
after compression and rejects insufficient space before changing output bytes.
Tests cover empty archives, directories, and compressed files, several small
capacities, one byte below the required size, and exact-size success.

Five new regressions passed with the 455-test development baseline. Complete
acceptance after integration passed all 465 units, every CLI suite, and the
pristine/two-mutation v70 gate on October 28, 2026. Runtime cgroup peak was
11,837,964,288 bytes.
