# Mecha Validate v1 RAR gate

Measured 2026-08-04 EDT at commit `2e400a5` plus the pending archive-summary
change. The corpus contains 31 independently produced archive sets that UnRAR
tests clean with the fixture password. `rarz verify` fully verified 121 files,
reported one encrypted file as unverifiable, and accounted for 27 directories.

## Consumer contract

Use `rarz_verify_archive()` for the archive verdict and counts. It rolls up the
existing `rarz_verify_file()` evidence without materialising decoded payloads.

The archive status is one of:

| Status | Meaning |
|---|---|
| `RARZ_ARCHIVE_VERIFY_VERIFIED` | Every non-directory entry matched stored integrity evidence. |
| `RARZ_ARCHIVE_VERIFY_DAMAGED` | At least one entry was proven damaged or failed an internal consistency check. |
| `RARZ_ARCHIVE_VERIFY_INCOMPLETE` | No damage was proven, but at least one entry or the format could not be verified. |
| `RARZ_ARCHIVE_VERIFY_ERROR` | The API call was invalid; no archive verdict exists. |

The summary keeps verified, damaged, unsupported, checksum-less, error, and
directory counts separate. Mixed evidence is therefore representable. One
damaged entry plus one encrypted entry returns `DAMAGED`, with both counts still
present. Consumers must enforce this accounting invariant:

```text
verified + damaged + unsupported + no_checksum + error + directories
    == entry_count
```

The original `rarz_validate()` ABI remains available. Its Boolean cannot express
incomplete evidence and must not be used for a new Mecha Validate integration.

External RAR implementations are fixture producers and dev/test oracles only.
The production library and CLI do not invoke or link UnRAR, `rar`, libarchive,
or another decoder.

## Evidence-backed feature matrix

`Strict` means producer-made pristine fixtures pass, payloads are decoded and
checked, and deterministic corruption tests exist. `Partial` means some layers
or variants are checked, with gaps named. `Unsupported` means the result must be
`INCOMPLETE`; it must never be presented as verified or damaged without new
evidence.

| Generation or feature | v1 gate | Evidence and limitation |
|---|---|---|
| RAR 1.4 | Unsupported | Signature is recognised. No parser or producer-made fixture exists; `format_supported=0`. |
| RAR 1.5 / UnpVer 15 | Unsupported | Decoder code exists, but no independent corpus exists. Do not infer support from implementation presence. |
| RAR 2.x / UnpVer 20, store and methods 1/3/5 | Strict | Seven archive sets, including solid and the fixture named `mm`; extracted bytes match UnRAR. |
| RAR 2.x / UnpVer 26 multimedia | Unsupported | The attempted `-mm` producer emitted v20, so no v26 stream has been tested. |
| RAR 3/4 / UnpVer 29, store and compressed | Strict | Six archive sets; ordinary and solid payloads verify against CRC32 and extract byte-identically. |
| RAR 3/4 standard VM filters | Partial | Delta/audio/E8 have prior differential evidence. E8E9/RGB/Itanium code has unit coverage but lacks producer-made fixtures in the committed corpus. Unknown VM programs report unsupported. |
| RAR5 / UnpVer 50, store and methods 1-5 | Strict | Ten single-archive sets cover store, all five levels, large payloads, regression payloads, and solid streams. CRC32 and BLAKE2sp are checked when present. |
| RAR5 / UnpVer 70 | Partial | Dispatch support exists, but the committed corpus does not identify a distinct v70 stream. |
| RAR5 split and multi-volume | Strict for committed cases | Three complete volume sets cover stored, compressed, and a large split payload. Missing/truncated volume mutations are rejected. |
| Solid archives | Strict for v20/v29/v50 corpus | Three generations extract byte-identically and retain decoder state across entries. |
| Per-file encryption (`-p`) | Partial/incomplete | Mixed fixture proves readable entries still verify. Encrypted entries report unsupported without a password; one clean mixed archive is `INCOMPLETE`, not damaged or verified. |
| Header encryption (`-hp`) | Unsupported | Headers cannot be enumerated without a password. No password-provider API or committed gate exists. |
| Recovery/service/quick-open payloads | Structural-only | Their headers are checked. Service data areas are not all consumed and hashed, so full-byte coverage must not be claimed. |
| SFX prefixes | Strict for recognition | Signature scanning is covered. Embedded executable bytes are outside RAR payload integrity claims. |
| RAR4 split volumes | Unsupported | No committed producer corpus or end-to-end reconstruction gate exists. |

## Deterministic classifier evidence

The archive-summary unit classifier uses a producer-generated RAR5 store
fixture as a set:

- pristine archive: every one of its six entries is accounted for, with five
  checksum-verified files and one directory;
- sniper set: five deterministic payload positions per non-empty file, at the
  start, quartiles, midpoint, and final byte; every mutation must return
  `DAMAGED` with exactly one damaged entry;
- mixed encryption: one readable file verifies and one encrypted file reports
  unsupported; archive status is `INCOMPLETE` and the accounting invariant
  still holds.

The existing CLI gates add 36 mutations across v20/v29/v50 solid archives and
42 damaged multi-volume sets. All 36 solid mutations were handled without a
damaged archive being blessed; all 42 damaged volume sets were refused as
valid. `tests/cli/test_integration.sh` has a weaker five-mutation loop that logs
survivors without classifying them and is not release evidence by itself.

## Remaining v1 blockers

- Integrate this exact API in `validate` and preserve all counts in its finding
  model. Do not map `INCOMPLETE` to either OK or FAIL.
- Add independent producer fixtures for RAR3 E8E9, RGB, and Itanium filters, or
  leave those variants incomplete in launch claims.
- Decide whether RAR4 split volumes and header encryption are launch scope. If
  they are, both need corpora and red-to-green gates.
- Hash or explicitly exclude RAR5 service payload areas before claiming every
  archive byte was checked.
- Replace the weak integration mutation loop with named sniper/boltgun/shotgun
  classifiers that record oracle-confirmed damage, surviving-valid mutations,
  false negatives, and false positives by generation and feature.
