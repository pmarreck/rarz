# Mecha Validate v1 RAR gate

Measured 2026-08-05 EDT at commit `cd74e18`. The committed corpus holds 40+
independently produced archive sets that UnRAR tests clean with the fixture
password.

A differential sweep on 2026-08-05 over content the corpus never contained
(executables, files past the RAR4 dictionary, RAR4 volume sets, encrypted RAR4
entries) found FOUR classes where rarz claimed damage on archives UnRAR tests
clean — the worst error an integrity tool can make. All are fixed;
see PLAN.md for the isolation evidence. Post-fix measurements over a
6-content-type x method x solid x recovery x quick-open x volume matrix in both
families:

- agreement with UnRAR on intact archives: 21/21, 0 mismatches (was 2/18);
- sniper mutation, 5 positions per archive: 93/93 damaged refused, 0 missed;
- size sweep 512 KB-8 MB, executable and text, both families: 20/20;
- extraction byte-identical to UnRAR for all four new fixtures.

Both directions are reported because either alone is trivially passable: the
agreement sweep by a blanket-VALID implementation, the mutation sweep by a
blanket-INVALID one.

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

`encrypted_entry_count` (added 2026-08-05) sits DELIBERATELY OUTSIDE that
invariant. Encryption is a property of an entry, not an outcome, so an encrypted
entry is also counted in exactly one outcome bucket — today `unsupported`, and
`verified` if a password API ever lands, with no semantic break. It exists
because `unsupported_entry_count` alone cannot say WHY an entry went unverified:
a failed decode and an encrypted entry land in the same bucket. Derive the
archive's encryption class from it:

```text
content = entry_count - directory_count
encrypted == 0        -> no encryption
encrypted == content  -> wholly encrypted
otherwise             -> MIXED: some entries verified, some unverifiable
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
| RAR 1.5 / UnpVer 15 | Unsupported | Decoder code exists, but no independent corpus does; rar 6.21 is the oldest obtainable writer and emits v20+. Do not infer support from implementation presence. |
| RAR 2.x / UnpVer 20, store and methods 1/3/5 | Strict | Seven archive sets, including solid and the fixture named `mm`; extracted bytes match UnRAR. |
| RAR 2.x / UnpVer 26 multimedia | Unsupported | The attempted `-mm` producer emitted v20, so no v26 stream has been tested. |
| RAR 3/4 / UnpVer 29, store and compressed | Strict | Six archive sets; ordinary and solid payloads verify against CRC32 and extract byte-identically. |
| RAR 3/4 standard VM filters | Strict for x86; partial elsewhere | The x86 E8/E8E9 path was WRONG until 2026-08-05 (missing file-offset term, file size used where a fixed 0x1000000 constant belongs) and reported damage on clean archives. Now covered by producer-made `rar4_x86_filter`/`rar5_x86_filter` fixtures compiled from self-owned C. RGB/Itanium still lack producer fixtures. Unknown VM programs report unsupported. |
| RAR5 / UnpVer 50, store and methods 1-5 | Strict | Ten single-archive sets cover store, all five levels, large payloads, regression payloads, and solid streams. CRC32 and BLAKE2sp are checked when present. |
| RAR5 / UnpVer 70 | Unconfirmed | Every rar 7.20 option probed validates, including -md512m and -md1g, but no stream positively identified as v70 was isolated. Not claimed. |
| RAR5 split and multi-volume | Strict for committed cases | Three complete volume sets cover stored, compressed, and a large split payload. Missing/truncated volume mutations are rejected. |
| Solid archives | Strict for v20/v29/v50 corpus | Three generations extract byte-identically and retain decoder state across entries. |
| Per-file encryption (`-p`) | Partial/incomplete | RAR4 encrypted STORE entries were reported DAMAGED until 2026-08-05 (ciphertext hashed against the plaintext CRC32). Now a none/mixed/all classifier corpus covers both families. Encrypted entries report unsupported without a password and are counted in `encrypted_entry_count`; a clean mixed archive is `INCOMPLETE`, never damaged or verified. |
| Header encryption (`-hp`) | Unsupported | Headers cannot be enumerated without a password. No password-provider API or committed gate exists. |
| Recovery/service/quick-open payloads | Structural-only | Their headers are checked. Service data areas are not all consumed and hashed, so full-byte coverage must not be claimed. |
| SFX prefixes | Strict for recognition | Signature scanning is covered. Embedded executable bytes are outside RAR payload integrity claims. |
| RAR4 split volumes | Strict for committed cases | Was reported INVALID (false damage) until 2026-08-05. `rar4_vol_store` (5 volumes) and `rar4_vol_m3` (4 volumes) reconstruct split files across volumes for both `t` and `verify`; per-volume mutation gate refuses 9/9 damaged sets. |

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
- Header encryption (`-hp`) remains out of scope; it is blocked on the password
  API whose contract is settled in PLAN.md. RAR4 split volumes are now IN and
  gated.
- Hash or explicitly exclude RAR5 service payload areas before claiming every
  archive byte was checked.
- Replace the weak integration mutation loop with named sniper/boltgun/shotgun
  classifiers that record oracle-confirmed damage, surviving-valid mutations,
  false negatives, and false positives by generation and feature.
