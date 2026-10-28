# Split-volume packed checksums

Before the final part of a split file, its CRC32 describes the packed bytes in
that volume. The final part stores the checksum of the complete decoded file.
This distinction is explicit in the [RAR5 format specification](https://www.rarlab.com/technote.htm)
and matches independent RAR4/RAR5 producer fixtures for stored and compressed
files. Earlier validation checked the final content checksum while ignoring
the preceding packed-part checksums. The writer also put the whole-file CRC
in every part, allowing its validator to overlook its own format error.

The writer now records packed-part CRCs before the final part. Validation
checks them both across a complete volume set and when inspecting a single
leading or intermediate volume. Multi-volume opening checks them before
collecting file entries, so extraction and the file verifier cannot bypass
the same inconsistency. A packed-CRC failure prevents opening that volume set;
it does not produce a partial per-entry report. Encrypted entries remain outside
plain-CRC checks because their checksum representation can depend on the key.

## Independent checks and reference limit

A mutation adapter changes only a leading part's packed CRC and recomputes its
header CRC. The payload and final whole-file CRC remain untouched. It checks
the original checksum against the packed bytes before mutation, and a second
check rejects the altered value while accepting the corrected header CRC.
The adapter uses an independent CRC implementation with the standard
`123456789` control value, 0xcbf43926.

UNRAR 7.20 still returns zero for all four altered fixture sets, even with
quick-open disabled. Its final-file check cannot establish that these earlier
checksum fields are consistent. This is a measured reference limitation; it
does not change the assessment classifier or rewrite historical campaigns.
The stricter rarz result follows the specified field meaning and independently
checked bytes. Such a case remains a reference disagreement in a generic
campaign until it is adjudicated using this evidence.

Tests cover both writer modes, every generated part's CRC role, all four
independent producer families/modes, complete-set validation, single-part
validation, and file verification. A legacy synthetic split-file test was
corrected to carry the first chunk's CRC instead of the whole-file CRC. The
new regression preserves an intact final checksum so the old behavior fails.

This work does not establish whole-file integrity from an isolated part, add
password support, or finish the separate BLAKE2sp/service-payload audit.

Complete acceptance passed 477 unit tests, every CLI suite, and the pristine
plus two corrupted v70 large-archive controls. Native macOS ARM64 unit/package
checks and the optimized build passed. Runtime cgroup peak was
11,838,271,488 bytes; shared-queue waiting preceded execution.
