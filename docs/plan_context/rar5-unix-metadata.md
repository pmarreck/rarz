# RAR5 Unix creation metadata

The CLI wrote the older RAR family's Unix host value, 3, into RAR5 file and
directory records. RAR5 defines Unix as 1. UNRAR therefore listed an unknown
host and failed to restore Unix permissions from these archives. Both CLI
creation paths now emit 1; Windows remains 0. The C and Zig creation-input
documentation uses the same RAR5 values. Callers previously supplying 3 must
supply 1 for Unix RAR5 records; the field layout is unchanged.

The host correction alone restored executable-file permissions, but directory
modes still changed during reference extraction. The original producer writes
directory records after their children. The CLI now follows that order for
top-level and nested directories, so directory permissions and times are
restored after descendant creation. Empty directories retain their records.

A subsequent complete run exposed a traversal-order-dependent UNRAR failure
when an empty directory appeared first: names ending in `/` could produce
"Cannot create directory" with "File exists". Directory names now omit that
suffix, matching the producer; the directory flag retains their type. The
attribute-set test compares exact names without normalizing away this defect.
Failure diagnostics and fixtures are retained for investigation.
The corrected names passed 64 isolated disk-backed repetitions in both store
and compressed modes, followed by complete 475-unit/CLI/v70 acceptance with
the recovery-volume changes.

An independent CLI regression first failed for store and compressed archives,
then isolated the remaining directory failure after the host-value correction.
The checks require UNRAR to identify all entries as Unix and restore nonempty
directory modes, executable and non-executable file modes, and explicitly fixed
directory timestamps. Archived permission records are compared as a complete
set against source filesystem modes. Extracted bytes also match.
The regression runs in the filesystem isolation boundary with private inputs
and extraction destinations.

UNRAR 7.20 restores an empty directory as mode 700 under the private test umask
even when the official producer records mode 750. The same result occurs for
rarz output. The test therefore checks the stored empty-directory mode and
compares extraction with an independently produced archive; it does not claim
that this reference restores empty-directory permissions correctly.

This evidence covers creation interoperability with UNRAR. It does not close
the separate task of restoring all metadata in rarz's own extraction command.

Complete acceptance passed 473 unit tests, all CLI suites, and the pristine and
two corrupted v70 large-archive controls. Runtime cgroup peak was
11,837,181,952 bytes. Native macOS ARM64 unit and package checks and the normal
optimized build also passed. The complete CLI/isolation suite remains qualified
on Linux only.
