# Encryption evidence through the volume C API

`rarz_verify_file` handled encrypted content for ordinary archive handles but
omitted that check in its unified multi-volume branch. The CLI's separate
file-info guard hid the omission from its intact-encryption tests.

A direct C API regression over both independently validated mixed-volume
orders failed because `is_encrypted` was zero for the encrypted entry. The
old path attempted to decode ciphertext and returned unsupported without
retaining the encryption property. No claim of reproduced stored-ciphertext
false damage is needed to establish this accounting defect.

The unified path now reports unsupported with `is_encrypted=1` and zero
verified bytes before touching ciphertext. The archive rollup still verifies
readable entries and retains its complete accounting sum. Tests cover both
two-volume orders and the full RAR4/RAR5 none/mixed/all corpus through
`rarz_open_volumes`. The existing CLI behavior remains covered.

This preserves the published ABI and deferred password support. It does not
add decryption, service-payload verification, or a new result model.

The direct regression failed before the fix and passed afterward. Final
acceptance passed 505 unit tests, the complete CLI suite and v70 corruption
gate, native macOS unit/package checks, and the optimized build. The admitted
Linux runtime peaked at 11,837,865,984 bytes. These checks do not extend the
outstanding native platform qualification claims.
