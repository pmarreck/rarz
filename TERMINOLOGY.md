# RAR terminology

| Term | Meaning |
|------|---------|
| UnpVer | Decompression algorithm version (15/20/26/29/50/70), which selects a decoder. |
| Method | Compression level within an algorithm generation: 0 is stored, 1–5 are compression levels. |
| vint | RAR5 variable-length integer: seven value bits per byte, with the high bit indicating continuation. |
| SFX | Self-extracting archive with an executable prefix before the RAR signature. |
| Store | Method 0, with uncompressed payload bytes and equal packed/unpacked sizes. |
| Structural validation | Header checksums and block framing, without necessarily decoding payloads. |
| Full validation | Structural validation plus payload integrity checks after decoding, subject to the explicit coverage limits in the feature matrix. |
| BLAKE2sp | Parallelized BLAKE2s tree hash with eight leaves, used for RAR5 payload integrity. |
| Clean-room | The established project requirement to derive the implementation from specifications rather than proprietary source; see the provenance question in `INTENT.md`. |
| Solid archive | Entries share decoder history; later entries can depend on bytes and coding state from earlier entries. |
| Incomplete | Verification could not establish integrity for all relevant entries; this is distinct from proven damage. |

## Format families

| Family | Signature (hex) | Algorithm versions |
|--------|-----------------|--------------------|
| RAR 1.4 | `52 45 7E 5E` | Ancient pre-Windows format |
| RAR 1.5–4.x | `52 61 72 21 1A 07 00` | 15/20/26/29 |
| RAR5+ | `52 61 72 21 1A 07 01 00` | 50/70 |

Recognition of a signature does not establish decoder coverage. Consult
[the measured feature matrix](docs/MECHA_VALIDATE_V1_RAR_GATE.md).
