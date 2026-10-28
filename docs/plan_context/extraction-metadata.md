# Extraction metadata

The additive `rarz_file_metadata()` function exposes raw attributes, whether
they represent POSIX mode bits, and an explicitly tagged modification time.
`rarz_file_entry` and its ABI remain unchanged. The time tag distinguishes
absence, unsigned Unix seconds, and local DOS calendar fields. Epoch zero is
a present Unix timestamp. Both single-archive and volume APIs preserve these
fields; callers receive the original format's time basis.

The CLI restores whole-second modification times after writing contents.
On POSIX systems it also restores the nine ordinary permission bits for Unix
entries, without installing setuid/setgid bits. It applies metadata to children
before parents, so directory times survive child creation and restrictive parent
modes cannot block restoration below them. Equal-length paths retain archive
order, making the last repeated directory entry authoritative. Failed writes
are excluded from the restoration list. Metadata errors make extraction fail
with a diagnostic; integrity validation remains a separate operation.

RAR4 DOS calendar values are interpreted in the extraction process's local time
zone, matching the existing listing convention. The archive does not provide a
source-zone offset. RAR4 extended timestamps, subseconds, creation/access times,
ACLs, ownership, and other metadata remain outside this API. The existing
extended-time parser task remains open. POSIX access time is left unchanged;
the Windows adapter changes only mtime through `SetFileTime`, opening directory
handles with `FILE_FLAG_BACKUP_SEMANTICS`. Microsoft's documentation specifies
that [`_utime64` rejects directories](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/utime-utime32-utime64-wutime-wutime32-wutime64?view=msvc-170);
the Wine regression reproduced that failure before the adapter correction.
Native Windows metadata behavior still requires runtime qualification.

The independent producer regression covers stored and compressed RAR5 archives,
file and directory modes, directories after children, and a file at Unix epoch
zero. An existing RAR4 Unix executable fixture is extracted by both UNRAR and
rarz and compared for bytes and executable mode. API tests distinguish absent
time from zero, retain raw attributes through both open paths, verify the RAR4
DOS basis, and classify the complete byte-sized host set for each format.

A fixture assembled from unchanged producer records puts a read-only parent
before its child, testing that permission restoration waits until content exists.
The AMD64 Windows executable also runs against store/compressed producer archives
under pinned Wine WoW64 in a Nix sandbox. That check covers directory, epoch-zero,
and maximum unsigned RAR5 times. The complete `./test` entry point requires this
check on Linux AMD64; the CI target manifest requires it too. Test-driver controls
classify all three declared native Nix systems and propagate its failure. Wine
initialization is dependency/runtime setup, separate from archive test execution;
the emulation check is not evidence of native Windows behavior.

## Integrated acceptance, 2026-10-28

The complete `./test` passed all 492 units and every CLI suite, including the
large-dictionary pristine archive and both corruption controls. Native macOS
ARM64 unit/package checks and the optimized `./build` passed. The required
Windows emulation check passed against the integrated executable. Runtime
cgroup peak was 11,838,402,560 bytes within the existing 16 GiB limit.
Build preparation, Wine initialization, and queue admission preceded runtime;
the large-corpus regression remains the documented extended check.
