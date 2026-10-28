# Mixed encryption across volumes

The RAR5 multi-volume validator returned immediately when any volume contained
an encrypted file. That returned the structural result for just that volume
and skipped every payload check, including readable files in other volumes.
Single-archive mixed-encryption checks did not exercise this path.

The regression places the encrypted file before and after the readable file in
two volume sets. UNRAR 7.20 verifies both with the fixture password. Changing
only the first readable payload byte by XOR `0xa5` makes UNRAR report damage;
the old candidate still returned success for both orders. Policy tests also
showed a file count of one instead of two and missing unverified accounting.

Validation now completes the structural pass over all volumes, records encryption
per file, and skips only ciphertext while continuing readable payload checks.
It retains the archive's encryption property on payload failure and counts the
skipped encrypted entries. The existing C ABI and partial-validation semantics
are unchanged. This does not add password support, decrypt ciphertext, or
complete the deferred verdict redesign.

## Independent fixtures

The four `tests/fixtures/rar5_mixed_*.part*.rar` fixtures contain unchanged FILE
headers and packed bytes from the committed `rar5_encrypted_mixed.rar`, produced
by the external RAR tool. `tests/support/make-mixed-volumes.lua` adds minimal
numbered MAIN and ENDARC records according to the
[RAR5 format specification](https://www.rarlab.com/technote.htm). They are
assembled producer records, not whole archives emitted by RAR.

The CLI regression reproduces each fixture byte for byte in private scratch,
checks both intact sets using `unrar t -pSECRET -qo-`, and requires independently
confirmed damage before asserting candidate rejection. `SECRET` is the public
fixture password. No checksum/header mutation is used to create the payload
failure. Existing historical campaign reports and sample counts are unchanged.

## Acceptance

The complete `./test` entry point passed 503 unit tests, all CLI suites,
the required Windows emulation check, and the bounded large-archive corpus.
Native macOS ARM64 unit/package checks and the optimized build also passed.
Native Windows and Linux ARM64 runtime qualification remain separate work.
