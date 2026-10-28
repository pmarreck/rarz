# Recovery-volume recognition

RAR5 recovery volumes begin with the eight bytes `52 61 72 21 1a 52 65 76`
(`Rar!` followed by byte 0x1a and `Rev`). An official RAR 7.20 producer control
establishes this signature independently. Recognition now prevents a pristine
recovery volume from being reported as a damaged archive merely because its
signature differs from the ordinary archive signatures.

The C format identifier is 51, a rarz API value for this container type, not a
claim about a RAR version 5.1. Existing identifiers and structure layouts are
unchanged. Detection and an open handle identify the format; they do not verify
the recovery header, checksums, or parity data. The aggregate verifier reports
INCOMPLETE with `format_supported=0` and zero encrypted entries. The older
boolean validation API returns zero with family 51 and an unsupported message.
Consumers must inspect those facts rather than treating every zero as damage.

Both `rarz t` and `rarz verify` exit 69 and explain that recovery-data verification
is unsupported. They never claim VALID or INVALID for an opaque recovery
container. Complete signatures with truncated or arbitrary bodies remain
unverified. Near signatures do not acquire recovery classification. Existing
prefix scanning recognizes this signature before looking inside its body for
ordinary archive signatures. Older recovery-volume formats remain unqualified.

## Independent producer control

The fixture `tests/fixtures/rar5_recovery.rev` is the first recovery volume from
an official RAR 7.20 invocation, using a private directory and no personal input:

```bash
printf 'Recovery volume producer control\n%.0s' {1..200} > payload.txt
TZ=UTC touch -t 202601010000.00 payload.txt
rar a -m0 -v2048b -rv2 -idq archive.rar payload.txt
unrar t -p- -idq archive.part1.rev
```

The producer and reference test both returned zero. The fixture SHA-256 is
`ee84c5495032d3791bbe900fe6eb5879a2fcf70ebc597dcf20842e356494c9a8`.
This is a recorded fixture identity; producer metadata can prevent byte-for-byte
reproduction on another filesystem. Unit tests classify all 256 values at each
signature byte and all signature truncations. CLI tests retain the independent
reference check, rename the fixture to a neutral extension, and test opaque and
signature-only inputs without making integrity claims.

Complete acceptance passed 475 unit tests, all CLI suites, and the pristine
plus two corrupted v70 controls. Native macOS ARM64 unit/package checks and
the optimized build passed. Peak runtime cgroup usage was 11,836,825,600 bytes.
An initial complete run exposed the separate directory-name problem described
in [Unix metadata](rar5-unix-metadata.md); acceptance was repeated after fixing
it. The successful repeat is the acceptance result for this change.
