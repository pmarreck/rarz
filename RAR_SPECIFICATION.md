# RAR Specification Draft For `rarz`

Status: Draft v0.1 (implementation-planning quality)

Date: 2026-02-19

See also: `RAR_COMPRESSION_ALGORITHMS_EXHAUSTIVE.md` for an exhaustive English algorithm inventory traced to unRAR 7.2.4 evaluation references.

## 1. Purpose
This document defines a practical, implementation-ready specification for a clean-room Zig project (`rarz`) that can:
- parse and validate RAR archives,
- decode RAR archives produced by official tools,
- eventually encode RAR archives that official tools can decode.

It targets interoperability and corruption discrimination (for `validate` integration), not bit-for-bit clone behavior.

## 2. Clean-Room Boundary For This Draft
This draft includes details gathered from:
- public RAR5 format documentation (`technote.htm`),
- public behavior/corpus observations,
- source-level evaluation of UnRAR/7-Zip/libarchive performed only for scoping and field discovery.

For strict legal clean-room implementation, use a two-lane workflow:
1. Spec lane (allowed to inspect source) emits this document + test vectors.
2. Implementation lane (no source exposure) implements only from this document + public docs + corpus.

### 2.1 Required LLM attestation in source header
For implementation sessions where an LLM contributes code, the main source file must contain a top-of-file header comment with a non-cryptographic self-attestation including:
- Exact model identifier/spec string used for that session.
- Model training cutoff date as declared by the runtime/environment.
- Explicit statement that the model does not currently contain original proprietary RAR implementation source in its active context window.
- Explicit statement that during that implementation session it will not attempt to retrieve original proprietary RAR implementation source from internet search or local disk search.
- Signed name/identifier and calendar date.

Required initial dated form for this project kickoff:
- Date value: `2026-02-19`.

Template (to be adapted by the active implementation agent):
```c
/*
LLM CLEANROOM ATTESTATION
Model: <exact model spec string>
Training cutoff: <YYYY-MM or YYYY-MM-DD>

I attest that:
1) I do not currently have original proprietary RAR implementation source code
   in my active context window.
2) For this implementation session, I will not attempt to retrieve original
   proprietary RAR implementation source code via internet lookup or local
   filesystem search.

Signed: <agent identifier>
Date: 2026-02-19
*/
```

## 3. Scope

### 3.1 Required
- Archive signature detection for RAR 1.4, RAR 1.5-4.x, RAR5+.
- Structural parsing of headers and blocks.
- Integrity checks that can be performed without user passwords.
- Deterministic corruption detection behavior suitable for `validate`.
- Multi-volume awareness (at least structural).

### 3.2 Stretch
- Full decompression for common methods.
- RAR writer (encoder) with official-tool interoperability.

### 3.3 Out Of Scope For First Delivery
- Password UX.
- Cracking/recovery.
- Legacy edge features not needed by current corpus.

### 3.4 Required architecture and boundaries
- Core implementation must be a Zig library operating on in-memory data only.
- Core library must expose a stable C FFI surface that is the only integration boundary for non-Zig callers.
- All file system, terminal, and process I/O must live outside the Zig core (hexagonal boundary).
- CLI implementation must be in C, must dogfood the same C FFI used by external consumers, and must not call Zig internals directly.
- CLI binary name must be `rarz`.
- CLI goal is drop-in compatibility with official `rar` command arguments and behavior for supported commands/options.
- All dependencies required to build and test must be procured through a project `flake.nix` (reproducible Nix-based toolchain).

## 4. Version Families And Signatures

### 4.1 RAR 1.4 (legacy)
Signature: `52 45 7E 5E` (`R E ~ ^`)

### 4.2 RAR 1.5-4.x
Signature: `52 61 72 21 1A 07 00`

### 4.3 RAR5+
Signature: `52 61 72 21 1A 07 01 00`

### 4.4 Future marker handling
If signature byte 6 is greater than `1` but less than `5`, treat as future/unsupported format (not invalid bytes, but unsupported variant).

## 5. Common Container Rules
- Optional SFX data may exist before signature; parser must scan forward up to configured max prefix.
- All multibyte fixed-width integers are little-endian unless explicitly varint (`vint`).
- Unknown block handling depends on flags (`skip if unknown` semantics).
- Validation must report what it could NOT check, never silently omit it. A
  three-dimension model is drafted in §5.1 but is not implemented; see PLAN.md §4h.

## 5.1 Validation contract — three orthogonal dimensions

> **STATUS: DRAFT, NOT IMPLEMENTED, AND KNOWN-FLAWED. Do not build as written.**
> An independent review found this design cannot express a real case (an archive
> both damaged AND partly unverifiable), that the three dimensions are not actually
> orthogonal, and that the granularity is wrong — these are per-ENTRY facts and a
> richer per-entry vocabulary already ships in `include/rarz.h`. See PLAN.md §4h for
> the full findings and the proposed alternative. Retained here as the record of
> intent, not as a specification to implement.

It exists because a single boolean cannot express the difference between "I
checked and it is good" and "I did not check", and every wrong verdict rarz has
shipped came from that conflation.

Governing rule, from the fleet-wide *VALIDATION CATEGORY RULES* (2026-01-25):

> If a code path decides "I can't run this deep check here" — for any reason —
> the verdict surface MUST tell the user. OK is reserved for "every applicable
> check ran and passed." Never use OK as a fall-through for "we didn't run the
> check."

The three dimensions are independent. Do not collapse them.

### Dimension 1 — `outcome`: what we concluded

| value | meaning |
|---|---|
| `verified_intact` | Every applicable check ran and passed. |
| `verified_damaged` | A check ran and failed. Real damage. |
| `could_not_verify` | A decisive check did not run. Says nothing about whether the archive is good. |

### Dimension 2 — `depth`: how far checking actually reached

| value | meaning |
|---|---|
| `none` | Nothing examined. |
| `signature` | RAR magic recognised, nothing beyond. |
| `structural` | Blocks walked, header checksums verified. |
| `payload` | Payload decoded, stored checksums verified. |

`depth` is a statement about work performed, not a quality tier. It stays
meaningful when `outcome` is `could_not_verify`: an encrypted archive whose
headers all check out is `could_not_verify` at `structural` depth, and that
structural result is genuinely useful.

### Dimension 3 — `reason`: why checking stopped short of `payload`

`none` when it did not. Otherwise:

| value | trigger |
|---|---|
| `encrypted_no_password` | `-p`: data encrypted, headers readable and checked |
| `encrypted_headers` | `-hp`: headers encrypted, blocks cannot be walked |
| `unsupported_format` | Format recognised but unparsed here (RAR 1.4) |
| `unsupported_filter` | Entry uses a filter this build cannot reproduce |

### Legal combinations

- `verified_intact` ⇒ `depth = payload`, `reason = none`.
  An archive is only intact if the decisive check ran.
  (Exception: an archive with zero file entries reaches `structural` and is
  `verified_intact` at that depth, because no payload check is *applicable*.)
- `verified_damaged` ⇒ `reason = none`. Damage is a finding, not a skip.
  `depth` records where the failure was found.
- `could_not_verify` ⇒ `reason != none`, always. A skip without a stated reason
  is the silent skip the governing rule forbids.

### Mapping to `validate`'s four verdict tiers

rarz reports facts; `validate` owns the tier vocabulary (OK / INFO / WARN /
FAIL). The mapping is:

| rarz `outcome` | validate tier |
|---|---|
| `verified_intact` | **OK** |
| `verified_damaged` | **FAIL** |
| `could_not_verify` | **WARN**, carrying `reason` as the warning text and `depth` as the reported depth |

`could_not_verify` is never OK and never FAIL. Not OK because no decisive check
ran; not FAIL because nothing was proven damaged.

### Legacy fields

`is_valid` and `has_encrypted_content` predate this model and are retained with
**unchanged semantics** so consumers migrate on their own schedule. Note that
`is_valid` means "not proven damaged", not "verified good" — precisely the
ambiguity `outcome` retires. New code reads `outcome`.

### 5.1.1 Migration ledger — what each path must start reporting

The three dimensions are only worth having if every path sets them honestly. A
path that leaves `outcome` at a default is the silent skip wearing a new
costume. This table is the checklist; it is not done until every row is.

Legend: **set** = already reports all three correctly · **TODO** = still
inferring from `is_valid` alone.

| path | current verdict | must become | status |
|---|---|---|---|
| RAR5 payload, all checks pass | `is_valid=true` | `verified_intact` / `payload` / `none` | TODO |
| RAR5 payload CRC32 or BLAKE2sp mismatch | `is_valid=false` | `verified_damaged` / `payload` / `none` | TODO |
| RAR5 header CRC mismatch | `is_valid=false` | `verified_damaged` / `structural` / `none` | TODO |
| RAR5 truncated (no end-of-archive block) | `is_valid=false` | `verified_damaged` / `structural` / `none` | TODO |
| RAR5 `-p` encrypted data | `is_valid=true` + `has_encrypted_content` | `could_not_verify` / `structural` / `encrypted_no_password` | TODO |
| RAR5 `-hp` encrypted headers | `is_valid=false` ← **wrong today** | `could_not_verify` / `signature` / `encrypted_headers` | TODO |
| RAR4 payload, all checks pass | `is_valid=true` | `verified_intact` / `payload` / `none` | TODO |
| RAR4 payload CRC32 mismatch | `is_valid=false` | `verified_damaged` / `payload` / `none` | TODO |
| RAR4 store-method entry verified | `is_valid=true` | `verified_intact` / `payload` / `none` | TODO |
| RAR4/v29 unsupported VM filter | `is_valid=false` ← **wrong today** | `could_not_verify` / `structural` / `unsupported_filter` | TODO |
| RAR4 `-p` encrypted data | `is_valid=true` + `has_encrypted_content` | `could_not_verify` / `structural` / `encrypted_no_password` | TODO |
| RAR 1.4 (no parser) | `is_valid=false` ← **over-strict today** | `could_not_verify` / `signature` / `unsupported_format` | TODO |
| RAR 1.5 / v15 decoder (untested) | decodes; CRC decides | `verified_intact`/`verified_damaged` / `payload` | TODO |
| RAR2 / v20, v26 multimedia | decodes; CRC decides | `verified_intact`/`verified_damaged` / `payload` | TODO |
| Multi-volume, all volumes present | `is_valid=true` | `verified_intact` / `payload` / `none` | TODO |
| Multi-volume, a volume truncated | `is_valid=false` | `verified_damaged` / `structural` / `none` | TODO |
| No recognised signature | `is_valid=false` | `verified_damaged` / `none` / `none` | TODO |

Three rows are marked **wrong today** because the current two-state result has
nowhere to put "could not check", so they fall into `is_valid=false` and
`validate` renders them FAIL — a damage claim about archives that unrar tests
clean. Those are the rows that make this migration a correctness fix rather than
a refactor.

Decoders themselves (`unpack15/20/29/50`) do not set these dimensions; they
report success or a typed error, and `policy.zig` maps that to the dimensions.
The one thing a decoder must do is distinguish "this stream is corrupt" from
"this build cannot handle this stream" — `error.UnsupportedFilter` versus
`error.CorruptData` — because that distinction is what picks `verified_damaged`
over `could_not_verify`. Any decoder that collapses the two forces a wrong
verdict no amount of policy mapping can repair.

## 6. RAR 1.5-4.x Binary Layout

## 6.1 Base short block header (`SIZEOF_SHORTBLOCKHEAD = 7`)
- `head_crc16` : u16
- `header_type` : u8
- `flags` : u16
- `head_size` : u16

If `LONG_BLOCK` flag is set, `data_size` u32 is present in long block header path.

## 6.2 Header types (legacy)
- `0x72` MARK
- `0x73` MAIN
- `0x74` FILE
- `0x75` CMT
- `0x76` AV
- `0x77` OLDSERVICE
- `0x78` PROTECT
- `0x79` SIGN
- `0x7A` SERVICE
- `0x7B` ENDARC

## 6.3 Important legacy flags
Main flags:
- `MHD_VOLUME`
- `MHD_COMMENT`
- `MHD_LOCK`
- `MHD_SOLID`
- `MHD_PROTECT`
- `MHD_PASSWORD`
- `MHD_FIRSTVOLUME`

File flags:
- `LHD_SPLIT_BEFORE`
- `LHD_SPLIT_AFTER`
- `LHD_PASSWORD`
- `LHD_SOLID`
- `LHD_LARGE`
- `LHD_UNICODE`
- `LHD_SALT`
- `LHD_VERSION`
- `LHD_EXTTIME`

## 6.4 Legacy file/service core fields
Following short header, file/service records contain:
- packed size low u32
- unpacked size low u32
- host OS u8
- file CRC32 u32
- DOS time u32
- unpack version u8
- method byte (stored as ASCII-like offset, normalize by subtracting `0x30` in reader model)
- name size u16
- file attributes u32
- optional 64-bit size highs if `LHD_LARGE`
- file name bytes (OEM/Unicode split rules for old format)
- optional subdata, salt, extended times depending on flags

## 6.5 Legacy checksum semantics
- Header CRC16 validates header region.
- File CRC32 validates decoded file payload (where decoding is feasible).

## 7. RAR5+ Binary Layout

## 7.1 General block structure
Physical order:
- `header_crc32` : u32
- `header_size` : vint (size of header data beginning at `header_type`)
- `header_type` : vint
- `header_flags` : vint
- optional `extra_size` : vint (`HFL_EXTRA`)
- optional `data_size` : vint (`HFL_DATA`)
- type-specific header body
- optional extra area
- optional data area

Practical limit: reject oversized headers (2 MiB max used by existing tooling behavior).

## 7.2 RAR5 common flags
- `HFL_EXTRA`
- `HFL_DATA`
- `HFL_SKIPIFUNKNOWN`
- `HFL_SPLITBEFORE`
- `HFL_SPLITAFTER`
- `HFL_CHILD`
- `HFL_INHERITED`

## 7.3 RAR5 block types
- `1` MAIN
- `2` FILE
- `3` SERVICE
- `4` CRYPT
- `5` ENDARC

## 7.4 MAIN block
- archive flags vint (`MHFL_*`)
- optional volume number vint if `MHFL_VOLNUMBER`
- optional extra records (locator/metadata)

Main extras:
- `MHEXTRA_LOCATOR`
  - quick-open offset
  - recovery-record offset
- `MHEXTRA_METADATA`
  - archive name/time metadata

## 7.5 FILE/SERVICE block core
- `file_flags` vint (`FHFL_*`)
- `unpacked_size` vint (or unknown marker via flag)
- `file_attributes` vint
- optional unix mtime (u32) if flag
- optional CRC32 (u32) if flag
- `compression_info` vint
- `host_os` vint
- `name_size` vint
- `name` bytes (UTF-8)
- optional extra area
- optional data area size already known from `HFL_DATA`

Compression info bits:
- algo version bits (0..5 bits)
- solid bit
- method bits (currently 0..5 used)
- dictionary bits/fraction bits
- compatibility bit for RAR5/RAR7 interop metadata

## 7.6 FILE/SERVICE extras
Field framing for each extra record:
- `field_size` vint
- `field_type` vint
- `field_data` (`field_size` minus bytes consumed by `field_type` payload)

Known extra record IDs:
- `FHEXTRA_CRYPT` (encryption params)
- `FHEXTRA_HASH` (BLAKE2sp)
- `FHEXTRA_HTIME` (high precision times)
- `FHEXTRA_VERSION`
- `FHEXTRA_REDIR` (links/junctions)
- `FHEXTRA_UOWNER`
- `FHEXTRA_SUBDATA`

## 7.7 ENDARC block
Contains archive-end flags such as next-volume indication.

## 8. Encryption Model

## 8.1 RAR5 key points
- Dedicated archive encryption header (`HEAD_CRYPT`) can encrypt subsequent headers.
- File-level encryption is conveyed via extra records.
- KDF behavior in ecosystem implementations uses PBKDF2-HMAC-SHA256 with log2 work factor (`Lg2Count`) and salt.
- Password-check fields are present optionally and checksummed.

## 8.2 Implementation policy for `validate` integration

Expressed in the §5.1 dimensions:

- Data encrypted, headers readable (`-p`), structure sound:
  `outcome = could_not_verify`, `depth = structural`,
  `reason = encrypted_no_password`. → validate: **WARN**.
- Headers encrypted (`-hp`), so blocks cannot be walked:
  `outcome = could_not_verify`, `depth = signature`,
  `reason = encrypted_headers`. → validate: **WARN**.
  This must NOT be reported as damage: an `-hp` archive that unrar tests clean
  is a good archive we cannot read.
- Encryption metadata malformed, or header checksums fail:
  `outcome = verified_damaged`. A failed check is a finding, not a skip.
- Structure damaged in a way visible without decryption (truncation, payload
  declared past end of file): `verified_damaged` even when encrypted. Encryption
  blocks the payload check, not the structural ones.

Empty-password decryption is not implemented; if added it would produce
`verified_intact` at `payload` depth plus an INFO-tier annotation, matching how
validate treats a PDF whose /Encrypt uses an empty user password.

## 9. Integrity Semantics And Corruption Detection

## 9.1 Structural integrity
Must verify:
- signature and block framing,
- header checksum correctness (CRC16 for legacy headers, CRC32 for RAR5 headers),
- declared sizes and offsets do not overflow file bounds,
- split/continuation flags are structurally coherent.

## 9.2 Payload integrity
When unencrypted and algorithm support exists:
- verify per-file integrity marker (CRC32 and/or BLAKE2sp depending on version/flags),
- verify decode pipeline for compressed entries.

When an unsupported compression path exists:
- `outcome = could_not_verify`, `depth = structural`, `reason = unsupported_filter`.
  Never `verified_intact` (no decisive check ran) and never `verified_damaged`
  (nothing was proven wrong) — see §5.1.

## 9.3 Corruption opacity classification
For this project’s test taxonomy:
- `corruption_transparent`: any random payload mutation is expected to fail validation.
- `corruption_opaque`: some random mutations can remain syntactically and semantically acceptable.
- `mixed`: outcome depends on location/method.

RAR should target `corruption_transparent` once decode/hash validation is in place for supported methods.

## 10. Two-Way Interoperability Requirements

## 10.1 Direction A (official -> rarz)
Any archive produced by official `rar`/`winrar` in supported profile must be parseable and, for supported methods, fully verifiable by `rarz`.

## 10.2 Direction B (rarz -> official)
Any archive produced by `rarz` writer profile must be accepted by:
- official `unrar`/`rar` test/extract,
- `7zz` RAR reader path.

## 10.3 Compatibility matrix
Profiles to cover at minimum:
- RAR5 store + file CRC,
- RAR5 compressed method subset used by common defaults,
- solid/non-solid,
- single-volume and split-volume,
- unicode names,
- symlink/junction metadata where supported.

### 10.4 CLI drop-in compatibility requirements
- `rarz` must accept the same command grammar as official RAR tooling for the supported command subset.
- For supported commands/options, outputs and exit semantics should be behaviorally compatible (not necessarily byte-identical text).
- For unsupported commands/options, return explicit non-zero error and actionable message naming the unsupported token.
- Compatibility must be tested using scripted argument corpus comparing:
  - exit code class,
  - archive side effects,
  - extraction/test outcomes.

## 11. Conformance Test Plan (Normative)

## 11.1 Corpus classes
- Real-world archives from internet corpus.
- Official-tool generated fixtures (scripted).
- Edge-case synthetic fixtures only when generated by known-good tools.

## 11.2 Required tests per profile
1. `official_encode -> rarz_decode` pass.
2. `rarz_encode -> official_decode` pass.
3. `rarz_roundtrip` metadata checks.
4. 5 deterministic corruption injections outside signature region:
  - mutate random offset from seeded DPRNG,
  - assert invalid for corruption-transparent profile.

## 11.3 Deterministic mutation algorithm
- Seeded PRNG initialized at test start.
- Exclude signature/header magic window and fixed no-touch metadata windows.
- Perform 5 independent mutations on independent copies.

## 12. Core Architecture (Normative)
### 12.1 Zig core library
- `detect.zig`: signature/SFX scan and family dispatch.
- `reader.zig`: bounded little-endian + vint reader with overflow guards.
- `rar3_headers.zig`: legacy header parsing/checking.
- `rar5_headers.zig`: RAR5 block parser + extras parser.
- `integrity.zig`: CRC16/CRC32/BLAKE2sp adapters.
- `policy.zig`: maps parser outcomes to the three dimensions of §5.1
  (`outcome`, `depth`, `reason`).

No dynamic allocation from untrusted lengths without max clamps.

### 12.2 C FFI contract
- Provide opaque handles and plain C structs only.
- Input should support memory buffer APIs first (pointer + length) to preserve in-memory purity.
- Optional adapter APIs may accept callbacks for streaming input/output, but core logic remains buffer/stream abstraction without direct file I/O.
- Version the ABI (`rarz_abi_version()`) and keep backward-compatible expansion rules.

### 12.3 C CLI wrapper (`rarz`)
- Implemented in C and linked only through the public C FFI.
- Owns all I/O concerns: argument parsing, file enumeration, open/read/write, stderr/stdout formatting, and process exit codes.
- Must not bypass FFI by importing Zig internal symbols.
- Acts as both end-user binary and integration-test dogfood for ABI correctness.

## 13. Encoder Profile (Future)
When writer work begins, start with a constrained profile:
- RAR5 single-volume,
- store method only,
- UTF-8 names,
- CRC32 integrity,
- no encryption.

Then expand by method and metadata features.

## 14. Known Unknowns / Open Questions
- Exact RAR7 deltas vs RAR5 for public-spec-quality docs.
- Legacy oddities in RAR2.x comment/service records.
- Complete VM/filter behavior requirements for high-compression methods.
- Official expectations around recovery-record corner cases.

These should be resolved by corpus-first black-box testing against official tools.

## 15. Immediate Next Steps
1. Freeze this spec as `v0.1` and derive binary test vectors.
2. Build parser-only Zig skeleton (no payload decode) and achieve robust structural validation.
3. Add corruption harness and classify `corruption_opacity` by profile.
4. Add decode/integrity paths for top corpus methods.
5. Add constrained writer profile and run two-way interoperability gates.
