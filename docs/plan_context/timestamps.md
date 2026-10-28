# Timestamp interoperability

Current status, 2026-10-28: the additive metadata API now distinguishes absent
time, Unix seconds, and local DOS calendar fields without changing the existing
file-info ABI. Whole-second extraction timestamps and POSIX permissions are
restored, including directories after their children. RAR5 Unix host value and
directory naming were also corrected. See [extraction metadata](extraction-metadata.md)
for current acceptance; the sections below retain the earlier milestone and
interruption evidence.

Issue #31 identifies two epoch errors: the CLI packed filesystem times as DOS
dates before passing them to the RAR5 writer, and listing interpreted RAR5
Unix seconds as DOS bit fields. Existing payload comparisons did not compare
metadata. The independent regression is `tests/cli/test_mtime.sh`.

The [RAR5 format specification](https://www.rarlab.com/technote.htm) defines
the base-header mtime as unsigned 32-bit Unix seconds. The writer must preserve
that value regardless of the current time zone. Dates before the Unix epoch
or after `UINT32_MAX` require an extended representation; until the writer
supports it, creation must reject them before replacing an output archive.
Recursive input failures must reach the top-level command as well.

Foreign archives can omit base-header mtime and supply the type-3 file-time
extra record instead. That record may contain Unix seconds or Windows
FILETIME. Listing uses the available whole-second mtime in the current local
time zone. Subsecond precision and creation/access times are outside the
existing file-entry API.

The C file-info struct continues to expose format-native mtime: RAR4 DOS
calendar fields or RAR5 Unix seconds. `rarz_archive_format()` identifies the
encoding. RAR4's local calendar value has no source-zone offset, so converting
it to an absolute Unix instant would require an explicit interpretation.
The existing zero value also conflates missing time with Unix epoch zero.
An eventual richer metadata API should represent presence and time basis
explicitly; this milestone does not change the struct ABI or invent that
missing information. The create-entry input, which writes RAR5, takes Unix
seconds.

UnRAR's metadata listing provides the directory timestamp oracle. In the
observed fixture, extraction leaves directories with the time their children
were created, even when the stored directory times are correct. Directory
restoration and the incorrect RAR5 Unix host-OS value remain separate queue
items. The specification assigns Unix host OS value 1; creation currently
uses the legacy-family value 3.

The legacy timestamp trace and full issue discussion remain in the historical
development context and issue #31. Broader normalization of the C metadata
contract remains outside this fix.

## Acceptance checkpoint, 2026-10-14

The independent CLI regression failed before the change. A separate parser
regression then failed on a missing extra-record timestamp and passed after
the bounded parser fix. Focused ReleaseSafe timestamp checks, the installed
ReleaseFast smoke check, the unit suite, and the first 13 CLI suites passed.

Complete acceptance remains incomplete. The pristine v70 archive check was
gracefully interrupted after sustained throttling above a 12 GiB soft memory
limit; the hard limit remained 16 GiB with swap disabled. Peak memory was
13,356,277,760 bytes, with no OOM event. The process had spent about 19 minutes
in that check with 44 seconds of CPU time when the stop evidence was captured.
This is a resource-limited interruption, not an archive correctness finding.
The corpus still matched its retained backup byte for byte after termination.

The `./build` step, remaining CLI checks, Nix checks, and cross builds were
not reached in this packet. No automatic retry is authorized. Trace input and
dictionary allocations and evaluate bounded buffering before scheduling a
new complete acceptance run; retain the existing coverage and corpus.

## Acceptance receipt control

The interrupted private wrapper's EXIT trap recorded zero despite supervisor
exit 143. That original artifact is retained as incident evidence. Future
packets source `tests/support/packet-status.bash`, call `packet_status_begin`
with an unused receipt directory before work, and call `packet_status_complete`
only after every required step and identity check succeeds. The helper owns
the script's EXIT, TERM, and INT traps. Launch Bash with default INT/TERM
dispositions; initialization refuses inherited ignored signals. GNU `env
--default-signal=INT --default-signal=TERM bash SCRIPT` provides that launch
contract when an asynchronous parent would otherwise ignore SIGINT.

Success requires both a zero process/receipt exit and the completion marker
from that run. An early zero exit, missing marker, or reused receipt directory
cannot establish success. Signals remain 143/130 even after a completion
marker was written or during final receipt writing; ordinary nonzero exits
retain their status. Receipt write failure also fails the process. The master `./test` discovers
`tests/cli/test_packet_status.sh`, whose small real-child signal and exit cases
run without the archive corpus or a native build.
