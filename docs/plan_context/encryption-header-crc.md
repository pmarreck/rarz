# Plaintext checks before header encryption

The October 15 corruption campaign recorded six reference-confirmed damaged
inputs that rarz classified as unverifiable because their headers resembled
encryption. All six replay byte hashes match the original evidence. UNRAR with
the campaign's noninteractive flags confirms damage; the old rarz binary
returns unverifiable for each.

The encryption probe now verifies each available plaintext RAR5 header CRC
before trusting an encryption block, and verifies the RAR4 main-header CRC
before trusting its password flag. The [RAR5 format specification](https://www.rarlab.com/technote.htm)
places the encryption header before ciphertext and defines its ordinary header
CRC. An invalid checksum here proves damage without a password.

Three new unit regressions failed first. They cover every stored CRC bit in
genuine RAR4 and RAR5 encrypted fixtures, both bare and with an SFX prefix, plus
a forged RAR4 password flag. Genuine encrypted inputs remain unverifiable.
All six exact historical replays now report damage in the focused CLI control.
The original statistical report and its counts remain unchanged; these are
targeted regression results, not a new coverage estimate.

The independent development checkout passed 455 unit tests. Complete acceptance
with the FFI collection fix passed all 460 units, every CLI suite, and the
pristine/two-mutation v70 gate on October 28, 2026. Runtime cgroup peak was
11,837,571,072 bytes. Native macOS ARM64 passed 460 units and package smoke.
