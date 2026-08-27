# PLAN

## Work order: streaming verification, no size caps (2026-08-27, Peter ruling via validate)

Peter: "NOTHING is too large for deep validation, period. We figure out how to
do it efficiently and correctly with the minimum memory used." Witnessed gap:
a 1115.6 MB RAR made validate refuse deep validation at its 1 GiB cap.

- [x] unpack50: stream entries larger than the dictionary window. No look-back
  reserve needed: RAR5 filter starts are FORWARD deltas from their descriptor
  (reference unpack50.cpp:235), so the flush just never emits into an
  unapplied filter's region. Gates: text + x86-filter fixtures at ~28x/~16x
  the window verify and extract byte-identically; 15/15 mutations refused.
  (2026-08-27 12:35 EDT)
- [x] Multi-volume verify + validate_volumes: decode into the hashing sink
  (`decompressRar4ToSink`/`decompressRar5ToSink`); the unbounded decoded-side
  allocation is gone from every verification path. Packed-side reassembly
  stays (bounded by the entry's packed size). (2026-08-27 12:38 EDT)
- [x] `rarz_max_dictionary_size()` exported: max window from parsed headers
  alone, 0 = "cannot budget" (RAR 1.4). Expectations traced to `unrar lt`
  -md output, which also corrected a wrong guess (rar 6.21 sizes RAR4
  dictionaries to the file, not to the 4 MB maximum). (2026-08-27 12:40 EDT)
- [x] Witness: a 1.39 GB entry (43x its 32 MB window — the exact class of the
  1115.6 MB file that hit validate's cap) verifies in 2.04 s at 65.5 MB peak
  RSS = 33 MB archive buffer + 32 MB window + fixed state; 3/3 witness
  mutations refused. (2026-08-27 12:43 EDT)
- [ ] Reply to validate with the SHA + API notes.

## Coverage push: three false-positive classes closed (2026-08-05 10:50 EDT)

A differential sweep against unrar over content the committed corpus never
contained (executables, files past the RAR4 dictionary, RAR4 volume sets) found
three classes where rarz reported DAMAGE on archives unrar tests clean. All are
fixed; each was isolated causally before being touched, not guessed at.

- [x] **RAR4 encrypted entries reported as damaged.** `rarz_verify_file` checked
  for encryption on the RAR5 path only, so an encrypted RAR4 *store* entry had
  its ciphertext hashed against the plaintext CRC32 in its header. `rarz t` was
  already correct, so the two commands contradicted each other on one archive.
  (2026-08-05 10:10 EDT)
- [x] **x86 E8/E8E9 filter decoded to the wrong bytes.** The reference relocates
  against a fixed `0x1000000` wrap constant with offset
  `(position + cumulative file offset)`. rarz passed the file offset where the
  constant belonged and dropped it from the offset term. ARM had the same
  missing term. Proven causally: identical content with `-mc-` validated, with
  filters on it did not. Affects any archive containing a program.
  (2026-08-05 10:41 EDT)
- [x] **Any RAR4 file larger than the 4 MB dictionary failed to decode.** The
  decoder held the whole entry in the circular window and emitted once at the
  end, so a large entry overwrote its own opening bytes. Boundary measured
  exactly: 4096 KB validated, 4608 KB did not. unpack29 now streams as it
  decodes, as the reference does. (2026-08-05 10:41 EDT)
- [x] **RAR4 multi-volume sets reported INVALID.** `validate_volumes` handled
  RAR5 only. Both the `rarz t` verdict and the per-entry `rarz verify` path now
  support RAR4, including split-file reassembly across volumes.
  (2026-08-05 10:50 EDT)
- [x] **Three v20 defects behind entries larger than the dictionary.** The
  corpus was all small files, so nothing had decoded a v20 entry past its own
  window. (a) `readTables` opened with a byte alignment copied from v29 —
  `ReadTables30` aligns, `ReadTables20` does not, so up to 7 bits were discarded
  on every mid-stream table refresh. Invisible for single-block entries because
  the stream starts aligned. (b) The v20 dictionary was capped at 256 KB; the
  reference applies one uncapped formula to every RAR4 version, and RAR 2.90
  writes codes 3-4 for `-md512`/`-md1024`. (c) The same emit-once-at-the-end
  window overflow fixed in unpack29, but biting at 64 KB rather than 4 MB.
  36/36 agreement with unrar over 32 KB-900 KB afterwards.
  (2026-08-06 10:58 EDT)

Measured after the fixes, over a 6-content-type × method × solid × recovery ×
quick-open × volume matrix in both families:

| Sweep | Result |
|---|---|
| Agreement with unrar on intact archives | 21/21, 0 mismatches (was 2/18 before) |
| Sniper mutation (5 positions/archive) | 93/93 damaged refused, **0 missed** |
| Size sweep, 512 KB–8 MB, exe + text, both families | 20/20 |
| Extraction byte-identical to unrar | 4/4 new fixtures, incl. a 5.3 MB streamed entry |

Both directions matter: the agreement sweep alone would be passed by a
blanket-VALID implementation, and the mutation sweep alone by a
blanket-INVALID one.

### Remaining gaps, honestly stated

- **RAR 1.4** — signature recognised, no parser. `format_supported = 0`,
  reported INCOMPLETE. Out of scope per Peter ("except for the very earliest
  formats").
- **RAR 1.5 / UnpVer 15** — decoder code exists but no producer corpus does;
  rar 6.21 is the oldest obtainable writer and it emits v20+. Support must not
  be inferred from the code's presence.
- **RAR 2.x / UnpVer 26** — RESOLVED as a non-gap 2026-08-06. v26 is not
  multimedia: the reference comments it "Files larger than 2GB" and dispatches
  it to the same `Unpack20` routine (unpack.cpp:173), which rarz already
  mirrors. Multimedia is an inline mode *within* v20, covered since 2026-07-30
  by `rar2_v20_mm.rar`. Producing a distinct v26 stream needs a >2 GB member and
  would exercise no new decoder path.
- **RAR5 / UnpVer 70** — the flag that distinguishes it from v50 (`ExtraDist`,
  unpack.cpp:184) IS implemented as `is_rar7`. Every rar 7.20 option probed
  validates, but no stream positively identified as v70 was isolated, so
  end-to-end coverage stays unproven rather than claimed.

### Where old encoders can and cannot come from (measured 2026-08-06)

nixpkgs is a dead end for old formats: its oldest usable `rar` is the 6.x era,
and anything from RAR 2.9 onward emits v29. The encoder picks the unpack
version, so only a period-correct binary emits an older one.

rarlab still hosts two: `wrar290.exe` (RAR 2.90, already used for the v20
corpus, run under wine) and `rar250.exe` (RAR 2.50, unused so far). Probed and
absent: 2.80, 2.60, 2.00, and every 1.5x name. v15 therefore has no obtainable
producer — RAR 1.5 is a 16-bit DOS binary that wine cannot run anyway, so it
would need dosbox even if a copy surfaced.
- **Header encryption (`-hp`)** — headers cannot be enumerated without a
  password. Blocked on the password API below.
- **Extraction does not restore the POSIX exec bit** on RAR4 entries (content is
  byte-identical; mode is not). Extraction fidelity, not a validation defect.
- **RAR5 SERVICE block data areas** are not all consumed and hashed, so
  "every archive byte was checked" must not be claimed.
- **`./build` output does not run on the NixOS host.** `nix build` produces a
  musl-DYNAMIC binary (`interpreter /lib/ld-musl-x86_64.so.1`), and that loader
  is absent outside the nix store, so `./zig-out/bin/rarz` is unexecutable after
  `./build` even though the build exits 0. `nix develop -c zig build` gives a
  working binary, and `./test` is unaffected (it runs the nix `checks` inside
  the sandbox). Confirmed PRE-EXISTING, not caused by the 2026-08-05 work:
  building the parent commit `1ce99ef` in a clean worktree produces the same
  unrunnable binary. Either link musl statically or target the host libc.

## Password support and the mixed-encryption contract (design, deferred)

Peter, 2026-08-05: detect mixed-encrypted archives and report them truthfully
now; defer actually reading them. Detection **shipped** — see
`rarz_verify_archive_summary.encrypted_entry_count`. This section is the agreed
shape for the eventual support, so the API does not get invented under pressure.

### What shipped

`encrypted_entry_count` is a **property** count, deliberately outside the
accounting invariant. An encrypted entry is always ALSO counted in exactly one
outcome bucket (today `unsupported`). The archive's class is derived, not
stored:

```
content = entry_count - directory_count
encrypted == 0        -> no encryption
encrypted == content  -> wholly encrypted
otherwise             -> MIXED
```

This exists because `unsupported_entry_count` alone cannot say WHY an entry went
unverified — a failed decode and an encrypted entry land in the same bucket, so
a consumer reporting "unsupported due to encrypted content" was guessing.

### The success/error structure for eventual password support

The decision Peter asked for, so it is settled before code exists:

1. **A password is an input to `open`, not to `verify`.** RAR5 `-hp` encrypts
   the headers themselves, so the entry list does not exist until a password is
   supplied. A per-entry password argument cannot express that.
   `rarz_open_with_password(data, len, password, pw_len)`.

2. **A wrong password is NOT damage.** It must produce its own outcome, never
   `DAMAGED`. RAR5 stores a password check value, so "wrong password" is
   directly detectable rather than inferred from a failed CRC; RAR4 has no such
   value, so a RAR4 wrong password is indistinguishable from corruption and must
   report `RARZ_VERIFY_WRONG_PASSWORD` on the *evidence available*, never a
   damage claim. This asymmetry is the whole reason the code is separate.

3. **`encrypted_entry_count` does not change meaning.** With a correct password
   an encrypted entry moves from `unsupported` to `verified`; the property count
   stays put. That is exactly why it was kept out of the accounting invariant —
   the shipped field survives the feature without a semantic break.

4. **Mixed archives need no new status.** The counts already express
   "3 encrypted, 2 verified, 1 damaged". A dedicated MIXED status would have to
   lose to DAMAGED in the precedence ladder and would then say nothing the
   counts do not.

5. **Partial passwords are in scope.** One password may open some entries and
   not others (each `rar a -p` invocation is independent). The per-entry result
   already carries this; do not collapse it to an archive-level boolean.

Blockers before any of this is worth building: AES-256-CBC + the RAR5 KDF
(PBKDF2-HMAC-SHA256) and RAR4's older scheme, plus a decision on whether
passwords belong in a file-integrity tool at all given they must be supplied on
a command line or through an env var.

## Mecha Validate v1 RAR gate (2026-08-04 23:45 EDT)

- [x] Publish a consumer-facing result contract that distinguishes verified-good, verified-damaged, unverified, and unsupported evidence without breaking the existing C ABI. `rarz_verify_archive` keeps a lossless count rollup and accounting invariant. (2026-08-05 00:01 EDT)
- [x] Publish an evidence-backed version/feature matrix for RAR 1.4/1.5, 2.x, 3/4, 5/7; stored/compressed/solid/split/encrypted/recovery/filter/service/header/payload cases. See `docs/MECHA_VALIDATE_V1_RAR_GATE.md`. (2026-08-05 00:01 EDT)
- [x] Prove one remaining false-classification slice over sets of pristine and deterministically mutated fixtures (sniper/boltgun/shotgun), with UnRAR confined to the dev/test oracle role. The bounded first slice covers a 25-shot RAR5 store sniper set plus mixed encryption; larger guns remain below. (2026-08-05 00:01 EDT)
- [x] Run the full suite, build, applicable mutation/oracle gates, and exact Mechatron Prime targets before promoting a consumer SHA. `./test`, `./build`, `packages.x86_64-linux.default`, and `checks.x86_64-linux.default` all passed. (2026-08-05 00:12 EDT)
- Curiosity poke: a byte mutation may produce a different valid archive; classifier metrics must separate undetected corruption from legitimately surviving valid mutations.

## ACTIVE QUEUE (2026-07-29 — thelio-nixos, git-only, Mecha Validate release push)

Context: new main dev machine (thelio-nixos = mechatron-prime, our own CI); jj
retired, **git only**; Garnix dead. Downstream driver: **Mecha Validate**
(`../validate_gui` → `../validate` → rarz) is heading to release, so RAR
coverage must be *precise* (never forgiving) with *actionable* error detail.

### 0. Machine/branch reconciliation
- [x] Local was 11 commits behind `origin/yolo` with a stale duplicate of
  already-landed work in the tree. Verified every local source change was 100%
  present upstream, backed up the full diff, discarded the duplicates, and
  fast-forwarded to `6304b55`. Preserved the 2 genuinely-unique changes:
  Einstein's ReleaseSafe floor + the `ZIG_RECENT_API_CHANGES.md` symlink fix
  (origin still pointed at the dead `/Users/pmarreck/Documents-CloudManaged`
  Mac path). Backups: scratchpad `backup/`. (2026-07-29 EDT)

### 1. Get the suite honestly green (BLOCKS everything else) — DONE
- [x] True RED baseline established on this machine: **5 failing suites**
  (test_commands, test_directories, test_output_flag, test_volume_create,
  test_volume_validate). (2026-07-29 EDT)
- [x] **Root cause A — real product bug, C-hosted UB.** Everything rarz
  *created* with 2+ files was silently corrupt (`unrar t` = "checksum error",
  `rarz x` = "file has no data size", yet `rarz t` said VALID). Boundary was
  exactly `compressible_count >= 2` → the parallel-compression path.
  `std.Thread.spawn` was selecting Zig's raw-`clone` Linux impl, which reads
  `linux.tls.area_desc` — initialized only by `std.start`, which NEVER RUNS
  because `main()` is C (our dogfooding architecture). Alignment stayed 0 →
  ReleaseSafe panics at `assert(isValidAlignGeneric)`; ReleaseFast compiled the
  assert out → UB → all compression results null → `results[i].data.?`
  null-unwrap → `packed_size == 0`. Fix: `.link_libc = true` on the **library**
  module (exe already had it), selecting the pthread-backed impl that needs no
  Zig TLS bootstrap. Latent on macOS (always pthread-backed) — surfaced only on
  moving to Linux. (2026-07-29 EDT)
- [x] **Root cause B — environmental + rules violation.** The 2 volume suites
  shelled out to `python3`, absent from the devshell, silently writing EMPTY
  input files → nothing to split → "expected at least 2 volumes, got 1".
  Replaced with an `awk` `repeat_str` helper (byte-identical output). Peter's
  brief forbids Python; a test dep that isn't in the flake is invisible rot.
  (2026-07-29 EDT)
- [x] Master `./test` in-env: **ALL TESTS PASSED**, exit 0, ~59s. (2026-07-29 EDT)
- [x] ReleaseSafe floor committed (Einstein's ask; Peter item #7).

### 2. ReleaseSafe UB triage (Peter item #7) — DONE (this round)
- [x] Extended the floor beyond Einstein's `flake.nix`/CI change to the master
  `./test`, covering BOTH the Zig unit tests and **the C-hosted CLI binary** —
  the FFI boundary is exactly where the UB above lived, and ReleaseSafe turned
  silent archive corruption into a loud panic at the true fault site.
- [x] Full suite is green under ReleaseSafe with no further panics; the
  `link_libc` defect above was the one real UB finding. Re-triage whenever new
  parallel/FFI code lands.

### 3. Inbox: payload CRC32 false positive (2026-05-03, from validate) — RESOLVED
- [x] Already fixed. The note called it RAR4, but its own hex dump is the RAR5
  signature (`52 61 72 21 1A 07 01 00`; RAR4 is 7 bytes ending `07 00`). The
  fix shipped with committed fixture `rar5_decomp_regression.rar` and
  `tests/cli/test_regression_payload_crc.sh`, which passes. Note can be
  processed. (2026-07-29 EDT)

### 4. Mecha Validate release polish (Peter item #9) — precision + error detail
- [x] **Precision pass 1 — unverifiable payloads.** `validate_rar5_payload` had
  two paths where "nothing to check" silently became "nothing wrong":
  (a) an entry claiming `unpacked_size > 0` with no declared packed data size
  skipped every check and still returned VALID — the exact shape the
  Thread.spawn UB emitted, i.e. rarz blessed its own corrupt output while unrar
  reported "checksum error"; (b) a payload declared past the end of the archive
  was skipped, so a truncated file passed. Both now fail. (2026-07-29 EDT)
- [x] **Precision pass 2 — truncation.** Cutting 40 bytes off a committed
  fixture: rarz said VALID, unrar said "Unexpected end of archive". Whole
  trailing blocks vanishing leaves survivors well-formed, so the iterator's
  clean-EOF path could not tell "finished" from "data ran out". Now requires an
  end-of-archive block. rarz agrees with the oracle. (2026-07-29 EDT)
- [x] **Precision pass 3a — RAR4 truncation.** Same clean-EOF blind spot as
  RAR5; fixed in `00be71e`. Found by noticing a 30-truncation differential
  sweep was *vacuous for RAR4* — every fixture is RAR5. (2026-07-29 EDT)
- [x] **Precision pass 3b — silent-skip paths, all four closed** (2026-07-31 EDT).
  Each converted from a silent skip to an explicit failure:
  1. `parse_extra_records ... catch { continue; }` — a malformed extra record
     skipped BLAKE2sp verification and the entry still passed. Closed as a
     side-effect of 4g (streaming forces the expected hash to be resolved
     before decoding, and the non-allocating `_raw` form has no escape hatch).
  2. The multi-volume collector's `if (payload_end <= vol_data.len)` chunk-drop
     guard — a chunk declaring more payload than its volume holds was simply not
     appended, so the FILE left the verification set, the survivors checked out,
     and the archive read VALID.
  3. + 4. The second-walk `iter.next() catch break` in `validate_rar4_payload`
     and `validate_rar5_payload` — stopping there left every remaining entry
     unchecked while still returning the structural VALID. A fifth site, the
     volume chunk-collection walk, had the same shape and got the same fix.

  **Honest finding: 2-4 were unreachable.** Instrumented every site and measured
  0 hits across the whole fixture corpus, 8 byte-mutations and 8 truncations of
  each archive, and the unit suite's exhaustive single-byte-corruption and
  every-position-truncation sweeps. The structural walk runs first and rejects
  those inputs before the payload walk sees them. So this is hardening against
  future drift, not a live-bug fix — but the failure direction of a stale
  assumption here is a silent PASS, which is not a thing to leave lying around.
  The control that the change is safe is that the entire suite stays green: no
  legitimate archive relied on any of the skips.

  New `tests/cli/test_precision_volumes.sh` pins the reachable property
  differentially: 42 damaged volume sets, **0 reported VALID** (25 agreed with
  unrar, 17 rarz-stricter — all cases where bytes were genuinely removed and
  unrar tolerates it).

### 4a. 🔴 RAR 1.4 was blessed sight-unseen (found 2026-08-01, from Peter asking whether exit 65 applies to rar < 4)

`validate()`'s family switch returned `.is_valid = true` for `.rar14` with the
comment "No structural parser for RAR 1.4 yet". So **every RAR 1.4 archive was
reported VALID without a single byte being examined** — a signature followed by
200 bytes of random noise passed while unrar reported it damaged.

Of every silent-skip path in this file this was the worst: the others declined to
check one entry, this one blessed an entire format.

- [x] `.rar14` now refuses (2026-08-01 EDT). `rarz t` reports INVALID; `rarz
  verify` returns 69 (EX_UNAVAILABLE) via a new guard for "zero entries could be
  enumerated", which is how the archive reached "Verified 0 files, exit 0".
- [x] An existing unit test, "validate returns valid signature for RAR 1.4 data",
  asserted the bug and would have blocked the fix. Its NAME carried the defect:
  it conflated "the signature is recognised" with "the archive is intact".
  Rewritten to assert family detection AND refusal. This is the ~9th instance of
  the rule from `f3e45d5`: a test written from the same understanding that
  produced the code cannot falsify it.
- [ ] POST-1.0: actually parse RAR 1.4. It is genuinely different, not merely
  old — its file header has its own layout (`SIZEOF_FILEHEAD14`) and its checksum
  is a **16-bit `HASH_RAR14`**, not a CRC32: a distinct algorithm with no final
  XOR (unrar `hash.cpp`, `if (Type==HASH_RAR14) CurCRC32=0;` and a Result without
  `^0xffffffff`). Parsing it as RAR4 would read the wrong fields.

### 4h. Validation result shape — three dimensions (DESIGN DEFERRED, Peter 2026-08-02)

**Status: detect-and-report shipped; full compliance deferred.**

An independent adversarial review of the proposed three-dimension design
(`outcome` / `depth` / `reason`, drafted in `RAR_SPECIFICATION.md` §5.1) found it
could not express a real case, and that a richer per-entry vocabulary already
ships in this repo. Peter's call: report the situation truthfully now, defer full
compliance.

**Shipped (2026-08-02):**
- Encrypted entries are skipped INDIVIDUALLY; every other entry is verified
  (`04515ce`). This fixed a false pass on proven damage.
- `ValidationResult.unverified_entry_count` — how many entries could not be
  checked. Before it, "2 of 2 encrypted, nothing checked" and "1 of 2 encrypted,
  the other verified" produced identical results. Available to `validate` now
  (it imports the Zig module directly).
- CLI note reworded: "encrypted content not verified" read as "nothing was
  verified", false for a mixed archive.

**Deferred — what full compliance still requires:**
- [ ] A `could_not_verify` outcome distinct from valid/invalid. Four cases force
  it: `-p` mixed encryption, `-hp` encrypted headers, RAR 1.4, unsupported VM
  filters. Three of those currently render as **FAIL in validate on archives
  unrar tests clean**.
- [ ] Resolve the review's findings BEFORE implementing §5.1. It is drafted but
  **known-flawed**; do not build it as written:
  - The design forbids `verified_damaged` + a skip reason, so "one entry damaged,
    one unverifiable" — the exact mixed-encryption archive — is inexpressible.
  - The three dimensions are not orthogonal: ~83% of the 3×4×5 cross-product is
    illegal and `reason` alone determines the other two. It is a sum type spelled
    three times, with drift guarded only by prose across 32 assignment sites.
  - Wrong granularity. These are per-ENTRY facts. `rarz_verify_result`
    (`include/rarz.h`) already carries `NO_CHECKSUM` (inexpressible in the triple)
    and `bytes_verified` (coverage, which the triple has no dimension for).
  - Proposed alternative: per-entry evidence ledger + DERIVED archive rollup,
    `is_valid` as a method not a field, plus a coverage invariant
    (`sum(bytes_covered) + headers + service == archive_len`) as an oracle-free
    check that catches skipped regions nobody enumerated a reason for.
- [ ] `unverified_entry_count` is not exposed through the C FFI.
  `RarzValidationResult` is returned BY VALUE, so appending a field would have an
  old caller allocate a 32-byte return slot while the new library writes more —
  stack corruption, not a compatible expansion. If the C CLI needs it, add
  `rarz_validate_v2()` and bump `rarz_abi_version()`; never widen the existing
  return.
- [ ] Entries with NO stored checksum pass silently in `policy.zig`
  (`validate_rar5_payload`), while `rarz_verify_file` correctly returns
  `NO_CHECKSUM` for the same entry. Two contracts in one repo disagreeing about
  the same bytes.
- [ ] RAR5 SERVICE block data areas (recovery record, quick-open index, comment)
  are never read — only their header CRC is checked. Damage inside a recovery
  record goes undetected (unrar agrees, so not a differential failure), but
  validate documents `.full` as "every byte verified", which is then false.

**Mixed-encryption archives are uncommon in the wild** — `rar` will not produce
one in a single invocation; it takes two `rar a` calls with different `-p`
settings. That rarity is why deferring is reasonable, and also why our own audit
missed the bug: every archive it generated was uniformly encrypted or uniformly
not.

### 4b. 🔴 RELEASE BLOCKER — RAR4 support is materially broken (found 2026-07-30)

Evidence, against a real 12 KB RAR4 (`unrar l` = RAR 1.5, 3 entries), plus a
29 MB one; both `unrar t` = All OK:

- **0% corruption detection.** Flipped one byte at 5 offsets in the payload
  region: `unrar t` reported an error on all 5; **rarz reported VALID on all 5.**
  For an integrity tool this is the worst possible failure direction, on a
  format that is everywhere in the wild.
- **The parser produces garbage metadata** yet still says VALID:
  | unrar (truth) | rarz |
  |---|---|
  | `Data/ACES - Casino Data Extension.esm`, 72179 B | empty name, unpacked `2611447042` |
  | `Data/ACES - Readme.txt`, 20354 B | empty name, unpacked `4294739714` (≈2^32, smells like u32 underflow) |
  | dates 2008 / 2011 | `1980-00-04` (month 00 — invalid) |
  Packed sizes DO match, so block walking is roughly right; the file-header
  field layout (name, unpacked size, mtime) is being misread.
- **Root cause of the missed corruption:** `validate_rar4_payload` only verifies
  `f.method == 0` (store). Compressed RAR4 payloads are never checked at all —
  even though `unpack29/20/15` are real implementations (933/1160/821 lines,
  49 unit tests), so the decoders exist and are simply not wired into
  validation.

Why it went unnoticed: **there is not one RAR4 fixture in the corpus** — all 13
are RAR5 — and no CLI test touches RAR4. The decoders' 49 unit tests were
written against the same understanding that produced the decoders (no
independent oracle), so they cannot catch a misread field layout.

Work items, in order:
- [x] **RAR4 corpus built** (`tests/generate_rar4_fixtures.sh`). Peter's idea
  resolved the provenance problem cleanly: drive the *official* rar to produce
  the archives, but fill them with our OWN deterministic content — real
  producer, no third-party payload. RAR 7.x dropped `-ma4`, so the generator
  reaches back to nixpkgs `nixos-23.11` (rar 6.21) as a one-time offline step;
  the fixtures are committed so neither the suite nor CI depends on it.
  Payloads use `random --seed` at three entropy levels, incl. a
  `--normalized` one that is *partially* compressible. (2026-07-30 EDT)
- [x] **RAR4 header parsing fixed** (`06b6e86`): ADD_SIZE was double-read
  (ADD_SIZE *is* PACK_SIZE for file blocks) shifting every field by 4 bytes, and
  `header_offset` was always 0 (recorded relative to the block, used as an
  archive offset). Now matches `unrar l` exactly on names/sizes/dates/CRCs;
  extraction of the store fixture is byte-identical to unrar; store-method
  corruption detection went 0/5 → 5/5. (2026-07-30 EDT)
- [x] **RAR4 v29 decoder fixed** (`976d34b`) — six defects, all found by
  differential-testing tiny official-rar archives against unrar with
  `unpack30.cpp` as the reference: (1) readTables consumed 1 flag bit instead
  of 2, shifting the whole stream; (2) the BC length-15 escape was ignored;
  (3) the symbol loop lacked the delta-vs-old-table, had 16/17/18/19 shifted,
  read 2 bits instead of 3 for symbol 16, and left symbol 19 matching NO branch
  (index never advanced — a hang); (4) LENGTH tables grouped slots in pairs
  instead of fours; (5) the same LDecode table needs +3 for new matches and +2
  for rep matches, so the constant cannot be folded in; (6) short-match
  distances used {0..7} with no extra bits instead of SDDecode/SDBits, and the
  distance-dependent length bonus was missing. All five RAR4 fixtures now
  extract byte-identical to unrar. (2026-07-30 EDT)
- [x] **Compressed RAR4 payload verification wired** (`3c97623`). Corruption
  gate: unrar flagged 16 mutations, rarz catches **16/16, missed 0** (was 6/12,
  and 0/5 before any of this). Pristine archives stay VALID.
- [x] **MHD_PROTECT read as PASSWORD** (`02a4f4a`) — main-header flags were one
  bit low (AV 0x0020 / PROTECT 0x0040 / PASSWORD 0x0080), so any archive with a
  recovery record was called encrypted, which skipped ALL payload verification
  and returned VALID. It was also masking the filter gap below.
- [x] **RAR4 '\' path separators** translated to the host separator in the CLI
  (`02a4f4a`); a real third-party RAR4 now extracts with a tree and contents
  byte-identical to unrar.

- [x] **RAR4 directory entries misdetected on Unix-written archives**
  (2026-07-31 EDT). `is_directory` keyed on the DOS attribute bit `0x10`, which
  is only meaningful on DOS/Windows hosts. RAR4 stores the HOST OS's native
  attributes, so a Unix-created directory carries a mode word (0040755) whose
  bit 4 is a permission bit, clear for 0755 — directory entries were classified
  as regular FILES. Now uses the format's own marker,
  `(flags & LHD_WINDOWMASK) == LHD_DIRECTORY` (0x00e0), per unrar arcread.cpp,
  with the attribute check kept as a DOS/Windows-only fallback.

  Invisible until now because every RAR4 fixture was either wine-written
  (Windows host, so the attribute bit was set) or listed its directory entry
  BEFORE its contents, in which case the parent was created on demand and the
  misclassification had no visible effect. The new Unix-written v29 solid
  fixture lists `sub` LAST, so rarz tried to create a file over an existing
  directory: stderr error and exit 1 on a perfectly valid archive.

### 4d. ✅ RAR 2.x (v20) decoder — FIXED 2026-07-30

First-ever differential test of `unpack20` against real archives. Corpus built
with the ORIGINAL RAR 2.90 (2001) under wine — modern rar always emits v29, so
only a period-correct binary produces v20. See
`tests/generate_rar2_fixtures.sh` (6 archives: store/m1/m3/m5/mm/solid).

Results vs `unrar` (all six test "All OK" under unrar):

| fixture | files | missing | wrong |
|---|---|---|---|
| `rar2_v20_store` | 7 | 0 | 0 | ✅ (after the fix below) |
| `rar2_v20_m1/m3/m5/mm` | 7 | 3 | 1 | ❌ |
| `rar2_v20_solid` | 7 | 6 | 1 | ❌ |

So `unpack20` partially works — effectively-stored payloads survive — but real
compressed v20 data fails, and one file per archive comes back **silently
wrong**. Same shape as the unpack29 situation: ~1160 lines, 18 unit tests, and
never once decoded a real archive, so the tests agreed with the decoder.

- [x] **False positive fixed:** a missing end-of-archive block was treated as
  truncation. RAR5 mandates that terminator; **RAR 2.x frequently has none at
  all** and unrar reports such archives fine, so the rule rejected valid vintage
  archives — the worst direction for a tool that must be believed about old
  files. Narrowed to RAR5. RAR4 truncation is still caught by the
  payload-past-EOF and block-parse checks (verified: cutting a v20 fixture short
  still reports INVALID, matching unrar). The synthetic test that encoded the
  over-strict rule was replaced with one that truncates a real archive.
- [x] **`unpack20` fixed.** All six non-solid v20 archives now extract
  byte-identical to unrar (0 missing, 0 wrong) and validate VALID. Five
  defects, found by diffing against an instrumented build of the reference
  decoder rather than by reading code: (1) `BC20` was 20, but the format
  says **19** — a 20th 4-bit length was read on EVERY table load, costing
  4 bits and desynchronising the stream before a single symbol decoded;
  (2) all decode tables were derived, and wrong (pairs vs fours, short
  distances {0,1,2,3,4,8,16,32}, distances by formula where the real
  DBits saturates at 16); (3) both distance-dependent length bonuses
  missing, including v20's own three-tier rep cascade; (4) readTables
  consumed one flag bit instead of two and ignored the keep-old-table
  flag, so the 4-bit delta had no base; (5) old distances used v29's
  rotate-to-front instead of v20's CIRCULAR buffer, and two of the four
  match paths never pushed at all, so the cursor drifted out of step.
  Fixtures promoted out of known_gaps/ into the all-valid Interop Gate.
  Interop Gate A (which treats `tests/fixtures/` as "must be VALID") stays
  green. **Move them up into `tests/fixtures/` the moment the decoder works** —
  that is the acceptance test.
### 4e. Format coverage — the 1.0 line (Peter, 2026-07-30)

1.0 does not have to cover everything. The boundary:

| Format | Decoder | Corpus | 1.0? |
|---|---|---|---|
| RAR5 (v50) | ✅ verified | ✅ | **in** |
| RAR4 v29 + filters (delta/audio/e8) | ✅ verified byte-identical | ✅ | **in** |
| RAR4 v29 filters: itanium, rgb | ❌ unimplemented | — | **in** (small, same file) |
| RAR2 v20 | ❌ broken on real data | ✅ 6 archives | **in — last item** |
| RAR1.5 v15 | ❌ untested | ❌ none obtainable | **POST-1.0** |
| Encryption (RAR4/RAR5) | detection only | — | POST-1.0 |
| RAR2 v26 (multimedia) | untested | partial (`-mm` fixture is v20) | POST-1.0 |

**Stop after v20.** Anything not decodable must report *could-not-verify* rather
than a false verdict in either direction — that is what makes an incomplete 1.0
honest rather than untrustworthy.

### 4f. Solid archives — unsupported, separate from the v20 decoder work

Distinct defect, found 2026-07-30 while measuring v20. In a **solid** archive
every file is compressed as one continuous stream: the LZ window and the Huffman
tables carry over from one file to the next. rarz decodes each file
independently, so a solid archive fails wholesale.

Evidence — `rar2_v20_solid.rar` vs the same content non-solid:

| file | in `rar2_v20_m3` | in `rar2_v20_solid` |
|---|---|---|
| `noise.bin` (stored) | ok | **fails** |
| `sub/nested.txt` (stored) | ok | **fails** |
| everything else | fails/wrong | fails |

Files that decode fine when non-solid fail when solid, which is the signature:
it is not the v20 decoder, it is the missing cross-file continuation.

**RAR5 SOLID IS BROKEN TOO** (verified 2026-07-30). This is not a legacy-format
edge case — it is a live defect on our best-supported format:

| archive | unrar | rarz |
|---|---|---|
| RAR2 v20 solid | All OK | **INVALID** |
| **RAR5 solid** | valid | **INVALID**, 2 of 3 files wrong |

That is a FALSE POSITIVE on valid archives — the same class as the RAR 2.x
end-block bug fixed in `c9679d9`, and the exact trust failure this project
exists to prevent. **1.0 ship-blocker.**

#### Design: sequential decode with carried state (Peter's call, 2026-07-31)

Root cause is an API-shape mismatch, not a decoder bug.
`rarz_extract_to_buffer(handle, index, buf, len)` is index-based RANDOM ACCESS
with a fresh decoder per call; a solid archive is one continuous stream where
file N inherits the window and Huffman tables from N-1.

Rejected: decoding files `0..N` on every extraction. Correct but O(n^2) — on the
9710-file archive that is unusable.

**Chosen: a sequential decode path that carries decoder state across entries.**

Peter's key refinement — *validate never needs the bytes, only the verdict*:

> "since validate is just validating archives and not actually extracting them,
> only rarz's CLI needs to actually extract; both its Zig functions and its C FFI
> should permit an option of discarding all output and only returning a
> validation (or error) data structure. This would also greatly reduce any
> related memory requirements, since you're simply streaming into the void while
> watching for errors."

So the sequential path takes a **sink**: either write decoded bytes to a caller
buffer (CLI extraction) or discard them while still running CRC/BLAKE2sp
(validation). Consequences worth noting:

- Memory drops from "whole archive + whole decoded file" to "window + a
  streaming hash". Today `validate()` decompresses whole files into
  `page_allocator` buffers purely to checksum them and throw them away.
- This **also answers validate's 2026-07-10 streaming-verification request**
  (`inbox/2026-07-10-from-validate-archive-streaming-streaming-verifier.md`) —
  one design satisfies both. Tell them when it lands; they deprioritised it only
  because it looked separate.

**RED baseline captured 2026-07-31 13:00 EDT** (ReleaseSafe CLI, vs the unrar
oracle). Both fixtures test "All OK" under unrar:

| fixture | `rarz t` | extraction |
|---|---|---|
| `known_gaps/rar2_v20_solid.rar` | INVALID (false positive) | fails wholesale |
| `rar5_solid.rar` (new) | INVALID (false positive) | 1/6 ok, 4 missing, **1 silently WRONG** |

`sub/c_quotes_a_twice.txt` comes back at exactly the right size (48616 B) with
the wrong bytes — a size check would bless it. That is the confidently-wrong
outcome, not merely a refusal.

**RESOLVED 2026-07-31 15:00 EDT.** All three solid fixtures extract
byte-identically to unrar and validate VALID; all three promoted out of
`known_gaps/`, which is now empty. Full-corpus differential: **27 archives,
107 files, 0 mismatches**. Corruption gate: **36/36 mutations detected, 0
blessed-while-damaged, 0 over-strict**.

Three defects had to be fixed, only the first of which was the expected one:

1. **API shape (the known one).** A persistent `SolidSession` per format, plus a
   decoder cache on the archive handle keyed by *next expected index*. Sequential
   extraction (what the CLI does) is one pass; an out-of-order request replays
   predecessors into a `DiscardSink`. The FFI signature is unchanged — the cache
   is a memo, reached via `@constCast` on a handle that is only *declared* const.
2. **v29 dropped `TablesRead3`.** `ReadEndOfBlock`'s second bit says whether the
   NEXT entry starts with a fresh table; the reference records `TablesRead3 =
   !NewTable`. We discarded it. Invisible without solid archives, because a
   non-solid entry clears the flag during its own reset and re-reads regardless.
3. **The end-of-block marker was unreachable.** It costs a 16-bit PEEK to read
   and 1-2 bits to consume, so at an entry's tail our hard-bounded BitReader
   failed the peek and the marker — carrying defect 2's bit — was never seen.
   The reference has 30 bytes of slack (`ReadBorder = ReadTop - 30`); we now have
   opt-in padding, used by v29 only so truncation detection elsewhere is
   untouched. Relatedly, `decompressLoop` now runs to the marker rather than to
   `unpacked_size`, matching the reference, which has no size test in its loop at
   all and clips only when writing.

Only defect 1 was in the design. 2 and 3 were latent decoder bugs that solid
archives were simply the first thing to expose — more evidence for the rule that
a fixture the implementation authored cannot falsify that implementation.

Work items:
- [x] **RAR5 solid fixture built** — `tests/generate_rar5_solid_fixture.sh` →
  `tests/fixtures/rar5_solid.rar`. Additive and idempotent, unlike
  `generate_fixtures.sh` (which opens with `rm -rf tests/fixtures` and would
  destroy the wine-produced RAR2 and nixos-23.11-produced RAR4 corpora). Content
  is arranged so two files quote a third verbatim, forcing cross-file matches:
  an archive whose files share nothing round-trips even with a window that
  resets, so it could not falsify the bug. Generator asserts the archive really
  is solid — `rar a -s` silently emits a NON-solid archive when there is nothing
  to share. (2026-07-31 EDT)
- [x] Add a stateful/sequential decode entry to `decompress/dispatch.zig` that
  reuses an existing `Unpack20State`/`Unpack29State` (and the RAR5 equivalent)
  instead of constructing one per file. The reference gates on the solid flag:
  `if ((!Solid || !TablesRead3) && !ReadTables20())` — i.e. for a solid entry do
  NOT re-read tables, and do NOT reset the window.
- [x] Add the discard-output sink (`decompress/sink.zig`: Sink/BufferSink/DiscardSink,
  plus `Window.emitTo`). Used today by solid replay and extraction; wiring
  VALIDATION to hash straight from the window still needs incremental CRC32 +
  BLAKE2sp, tracked in 4g below. Was: streams without materialising
  decoded files; keep CRC32/BLAKE2sp verification intact.
- [x] Wire `policy.zig` validation to iterate entries through one shared decoder
  when the archive is solid.
- [x] Wire `root.zig` extraction: CLI extract-all uses the sequential path.
  Decide what index-based random access does on a solid archive (decode
  predecessors, or return a distinct "sequential access required" error).
- [x] Expose the discard/verify-only option through the C FFI too. (Was: deferred
  with 4g — the Zig-side sink exists, but there is nothing worth exposing until
  validation actually streams.)

#### 4g. Streaming verification — DONE 2026-07-31 19:45 EDT

Validation no longer materialises decoded entries. This is what Peter asked for
— "streaming into the void while watching for errors" — and it is the answer to
validate's 2026-07-10 request. They confirmed 2026-07-31 that the OUTPUT side is
their binding constraint: they mmap the archive, so holding it as `[]const u8` is
cheap, and their RAM cost was exactly the per-entry decoded buffer.

The obstacle was never the decoder. It was that `integrity.crc32` and
`integrity.blake2sp` were one-shot over a contiguous slice, while the LZ window
is circular and hands out a logically-contiguous run as one or TWO spans.

- [x] Incremental `integrity.Crc32` — the polynomial state IS the seed, so the
  one-shot and incremental paths now share `crc32_slice8_raw`. Two copies that
  agree only by inspection is how a chunked hash silently diverges.
- [x] Incremental `integrity.Blake2sp` — 512-byte staging buffer keeps the 8-way
  round-robin leaf assignment identical to the one-shot regardless of how the
  caller splits input. Differential tests sweep EVERY split point over >2 full
  rounds, plus one-byte-at-a-time; verified non-vacuous by corrupting the
  implementation and confirming all four tests fail.
- [x] `VerifySink` combining both; `policy.zig` now hashes straight from the
  window and never materialises a decoded entry.

  **Measured** (25 MB corpus, 6 x 4.3 MB entries, 3 runs each, peak RSS via
  /proc VmHWM):

  | archive | before | after | saved |
  |---|---|---|---|
  | non-solid | 16.5 MB | 12.3 MB | 4.2 MB (25%) |
  | solid | 40.9 MB | 36.7 MB | 4.2 MB (10%) |

  The saving is exactly one decoded entry (4308894 B = 4208 KB), reproducible
  to +/-10 KB. Verdicts unchanged and still agree with unrar.
- [x] **Bonus: retired a §3b silent-skip path.** The RAR5 BLAKE2sp check used
  `parse_extra_records(...) catch { continue; }`, so a malformed extra record
  skipped hash verification entirely and the entry still passed — "could not
  check" reading as "nothing wrong". Streaming forced the expected hash to be
  resolved BEFORE decoding (you cannot decide after the fact whether you wanted
  a hash you were supposed to compute as bytes flowed past), and the
  non-allocating `extract_blake2sp_hash_raw` has no such escape hatch.
#### Two defects in the first `rarz verify` (found 2026-08-01 while designing exit codes)

- [x] **`verify` ignored multi-volume sets.** `cmd_verify` called `rarz_open` on
  the single named file with no `discover_volumes`, unlike `cmd_test`. A
  compressed entry continuing into the next volume therefore held only its
  leading chunk, decoded as "failed", and `verify` contradicted both `rarz t` and
  unrar on an intact set. `rarz_verify_file` gained a `unified_files` branch, and
  that branch must come FIRST — a volume-set handle also has `rar5_files`
  populated for its own volume, which is precisely the wrong thing to read.
  Escaped review because the suite's target list contained no volume fixture,
  despite three sitting in the corpus.
- [x] **The short-decode check was documented but absent.**
  `rarz_verify_result.bytes_verified` carried a comment saying the caller
  compares it against the declared unpacked size. Nothing did. An entry whose
  decoder stopped early would report verified whenever no checksum existed to
  catch it. Now compared inside `rarz_verify_file`, before any checksum test.

#### Verify-only exit-code contract (Peter's call, 2026-08-01)

A bare non-zero cannot distinguish "this archive is damaged" from "I could not
form an opinion", and those call for different responses — restore-from-backup
versus a tooling gap. `rarz verify` therefore returns:

| code | meaning |
|---|---|
| 0 | every entry verified against a stored checksum, all matched |
| 1 | confirmed damage: checksum mismatch, or an unparseable archive |
| 64 | `EX_USAGE` — missing/bad arguments |
| 65 | `EX_DATAERR` — an entry carries NO checksum, so nothing could be verified |
| 66 | `EX_NOINPUT` — archive missing or unreadable |
| 69 | `EX_UNAVAILABLE` — an entry could not be decoded by this build |

Precedence when several apply: damage > cannot-decode > no-checksum.

Operational codes come from `sysexits.h` deliberately, so they cannot be
confused with unrar's own scheme if a script swaps one tool for the other
(measured: unrar returns 0 intact / 3 CRC error / 10 missing file).

Reachability, measured across the corpus × 12 mutations each: **69 fires 46
times** (corrupt archives that cannot be decoded — the distinction is live and
tested).

**65 never fires on our corpus, but the earlier claim that it is unreachable was
wrong** (corrected 2026-08-01 after Peter asked whether it applies to rar < 4).
"RAR4 and RAR5 always store a CRC32" is false for RAR5: the reference sets
`hd->FileHash.Type = HASH_NONE` and only upgrades it to `HASH_CRC32` when the
`FHFL_CRC32` file flag is present (unrar `arcread.cpp:826-831`). The checksum is
**optional in the format**; the `rar` encoder simply always writes it, which is
why no fixture reaches the branch. Our `f.has_crc32` already models this
correctly — only the reachability claim was wrong.

Worth noting: unrar's own `HashValue::operator==` **returns true when either side
is `HASH_NONE`** (`hash.cpp:31`), so unrar treats a missing hash as a pass. We
deliberately diverge and report 65. unrar does surface the distinction in its UI,
printing `?` instead of `OK` for such entries (`extract.cpp:955`).

Still no test for 65, because no producer we have emits such an archive; a
hand-built fixture would be asserting our own understanding of the flag rather
than a real producer's output.

- [x] Expose verify-only through the C FFI — `rarz_verify_file` + the `rarz verify`
  command (2026-07-31 EDT). Was: still open; nothing in-tree consumes
  it yet, since `validate` imports the Zig module directly.

---

- [x] Acceptance: `tests/fixtures/known_gaps/rar2_v20_solid.rar` extracts 7/7
  byte-identical and validates VALID, then gets promoted into
  `tests/fixtures/`; plus a RAR5 solid fixture added to the corpus (generate
  with `rar a -s`, which works with the modern devshell rar).

#### POST-1.0: older-format enhancement track
- [ ] **v15 (RAR 1.5).** No corpus and no coverage today. RARLAB no longer hosts
  a 1.5-era binary (`rar15.exe`, `rar200.exe` -> 404). `rar250.exe` (RAR 2.50,
  DOS) is still hosted and *might* emit v15 for some inputs, but it is a 16-bit
  DOS binary needing dosbox (not installed; wine cannot run 16-bit on x86-64).
  Other routes: an old Linux `rar` build, or sourcing genuine v15 archives from
  the wild and using them read-only as an oracle corpus. Until then v15 must
  report could-not-verify, never a guess.
- [ ] **v26 multimedia compression.** RAR 2.9's `-mm` produced v20 in our
  fixture; genuine v26 streams need a different producer/input to trigger.
- [ ] **Encryption** (AES + PBKDF2, `--password`) — already sketched in Phase 3.

### 4c. Remaining RAR4 gap: RarVM filter subsystem — RESOLVED for delta/audio/e8

On a real 29 MB third-party RAR4, 595 of 859 files still fail — every one of
them at `symbol == 257` -> `UnsupportedFilter`. Confirmed by instrumenting the
three failure sites: 595/595 were VM-code, zero PPM, zero decode errors. The
v29 LZ decoder itself is correct; RAR3's VM filter subsystem is simply not
implemented (already tracked as Phase 2E "v29 VM filter subsystem").

Current behaviour is at least honest: rarz reports INVALID ("decompression
failed during validation") rather than the previous false VALID. But INVALID is
the wrong verdict for "we cannot decode this filter" — the archive is fine.
This is the strongest argument yet for the **"unverified" state** in the
structured-result design pending with validate: three distinct outcomes
(verified-good / verified-bad / could-not-verify) rather than a boolean.

- [ ] Implement the RAR3 VM filter subsystem (standard filters by CRC
  recognition: delta, E8/E9, RGB, audio, x86 itanium).
- [ ] Until then, report filter-limited entries as unverified rather than
  invalid, once the result API supports it.
- [ ] **Structured error detail for the `validate` consumer.** ANSWERED by
  validate 2026-07-30 — design is unblocked, just needs implementing:
  - **No ABI constraint from validate.** It does NOT consume the C FFI; it
    imports the Zig module directly and reads `result.is_valid` /
    `result.error_message` by name, recompiling on each pin bump. So the Zig
    `ValidationResult` can be reshaped freely. Append-at-end in
    `include/rarz.h` is still the courteous choice for our own C CLI and any
    other C consumers, but that is our call alone.
  - **Keep the borrowed `error_entry_name` + `_len`** (not NUL-terminated).
    validate formats its verdict synchronously while the archive buffer is
    still mapped, then copies — so a slice into the caller's buffer is free.
  - **`error_code` is the stable contract**; `error_message` stays free-form
    English fallback. validate has a 50-locale i18n system and switches on the
    code. Proposed enum accepted (NO_SIGNATURE / BLOCK_PARSE / HEADER_CRC /
    PAYLOAD_CRC32 / PAYLOAD_BLAKE2SP / TRUNCATED / UNVERIFIABLE_PAYLOAD /
    DECOMPRESS_FAILED / ENCRYPTED / UNSUPPORTED), plus `error_offset` and
    `expected`/`actual` scalars.
  - Add a **could-not-verify** outcome alongside valid/invalid (see 4c) — the
    VM-filter case proves a boolean verdict is wrong.
  - Ping validate with the SHA when it lands; they bump the pin and reconcile
    fixtures (they expect previously-VALID-but-damaged archives to start
    failing, and will reclassify them as labeled-corrupt controls).
  - Streaming verification (2026-07-10) is explicitly LOWER priority than this
    for the current release — first release is media/photo/RAW focused.

### 5. Inbox: streaming verification API (2026-07-10, from validate-archive-streaming)
- [ ] `validate` wants a sibling to `policy.validate(data)` that does not
  require the whole archive as `[]const u8` (it has a seekable `FileSource`).
  Deliverable per the note: either a narrow implementation + tests, OR a
  concise design with the smallest first API and concrete blockers. Start by
  tracing which parse/decompress paths genuinely need random access.
  Keep `policy.validate(data)` compatible.

### 5b. `DEBUG BUILD` banner fires on every non-ReleaseFast build (Peter, 2026-07-31)

`src/cli/main.c` guards the yellow `DEBUG BUILD` banner with `#ifndef NDEBUG`.
Zig only defines `NDEBUG` for ReleaseFast and ReleaseSmall — **not** for
ReleaseSafe — so the banner prints on every ReleaseSafe build, which is the
fleet floor and what `./test` builds. The banner therefore says "debug" when the
build is not debug: it is noise where it should be a signal, and Peter's brief
has benchmark suites assert its absence.

- [ ] Gate the banner on the ACTUAL optimize mode passed to `build.zig`, not on
  the absence of `NDEBUG`. Failing test first: assert a ReleaseSafe CLI emits no
  `DEBUG BUILD`, and that a Debug CLI still does (an absence-only assertion
  passes vacuously if the banner is deleted outright).

### 6. Housekeeping
- [x] Mechatron Prime CI: committed exact package/check targets and installed
  the canonical dynamic badge; both targets passed locally. Webhook provisioning
  remains a host-level fleet operation, outside this code unit. (2026-08-05 00:12 EDT)
- [ ] Trash/process the 3 inbox notes once each is handled.

## CI migration off Garnix (2026-07-08 EST — Garnix shutting down 2026-07-15)
- [x] Garnix is shutting down 2026-07-15 (joining Shopify, open-sourcing; ALL user
  data + build artifacts deleted that day). The fleet-wide "All Garnix checks"
  aggregate wedge since ~07-01 was the wind-down degradation — not an account or
  repo bug. Confirmed via blog.garnix.io/blog/shutting-down/.
- [x] Replaced Garnix's nix-sandbox verification with a GitHub Actions `nix` job
  (DeterminateSystems/nix-installer-action; `nix build .#checks.x86_64-linux.default`
  + `.#packages.x86_64-linux.default`). Omitted magic-nix-cache (archived/deprecated).
  Native 4-platform zig CI unchanged; flake path is CI-verified again.
- [x] Removed the dead Garnix badge from README. (2026-07-08 EST)

## Recent Fixes (2026-07-02 EST — dedicated-owner onboarding)
- [x] Harness: `./test` now runs CLI suites in-env (`nix develop -c` for unrar/rar);
  stripped forbidden `set -euo pipefail` (→ `set -u`) and the `((errors++))` errexit
  footgun (→ `errors=$((errors + 1))`) across all suites. Revealed 2 hidden failures.
- [x] Fixtures: moved `fuzz_filter_type_invalid.rar` → `tests/fixtures/invalid/` (Interop
  Gate A treats `tests/fixtures/` as all-valid).
- [x] **Multi-volume verify bug**: `rarz t` reported false "payload CRC32 mismatch" on
  valid split-file archives. RAR5 stores the full-file CRC in the LAST volume part
  (split_after==false), not the first; `validate_volumes` + `collectRar5FilesUnified`
  now use the last part's CRC. Hermetic regression test embeds the official-rar m3
  fixtures. Master `./test` green in-env; agrees with unrar oracle.
- [x] `tests/diagnose_crc.zig` modernized for Zig 0.16 (Juicy Main + `std.Io`);
  its compilation is now gated on `zig build test` so CI enforces 0.16 compat
  and it can't silently rot again. (2026-07-03 EST)


## Phase 0: Specification and Design
- [x] Create initial RAR format specification draft (`RAR_SPECIFICATION.md`) (2026-02-19 EST)
- [x] Add architecture constraints: Zig in-memory core + C FFI + C drop-in CLI (`rarz`) (2026-02-19 EST)
- [x] Add required LLM cleanroom attestation header template with signed/date requirement (2026-02-19 EST)
- [x] Add exhaustive English compression-algorithm spec derived from unRAR eval (`RAR_COMPRESSION_ALGORITHMS_EXHAUSTIVE.md`) (2026-02-20 EST)

## Phase 1: Infrastructure + Structural Parser + Store-Method I/O
- [x] Define and freeze C ABI surface (versioning, opaque handles, memory-buffer-first APIs) (2026-02-20 EST)
- [x] Scaffold Zig core library crate with no direct filesystem/process I/O (2026-02-20 EST)
- [x] Implement signature scanner with SFX prefix support (`detect.zig`) (2026-02-20 EST)
- [x] Implement bounded reader primitives: LE, vint, checked seeks (`reader.zig`) (2026-02-20 EST)
- [x] Implement integrity primitives: CRC32, CRC16, BLAKE2sp (`integrity.zig`) (2026-02-20 EST)
- [x] Implement RAR 1.5-4.x structural parser + header CRC checks (`rar4_headers.zig`) (2026-02-20 EST)
- [x] Implement RAR5 structural parser + header CRC checks + extras parser (`rar5_headers.zig`) (2026-02-20 EST)
- [x] Implement validation policy mapping: signature/structural/full, encrypted-content handling (`policy.zig`) (2026-02-20 EST)
- [x] Add payload integrity verification for store-method files: CRC32 (`policy.zig`) (2026-02-20 EST)
- [x] Add writer MVP: RAR5 store-only archive creation (`writer.zig`) (2026-02-20 EST)
- [x] C FFI exports: open/close/detect/validate/file_info/extract/create (`root.zig`) (2026-02-20 EST)
- [x] C CLI: t/l/v/x/a commands with full-word aliases (`main.c`) (2026-02-20 EST)
- [x] Build binary fixture corpus + interop gates (official <-> rarz) (2026-02-20 EST)
- [x] Add project documentation: overview, code minimap (2026-02-20 EST)
- [x] Fix rarz_validate to delegate to policy.validate (2026-02-20 EST)
- [x] Consolidate encode_vint into reader.zig; remove dead CRC in writer (2026-02-20 EST)

## Phase 2: Decompression Engine
See: `docs/plans/2026-02-20-phase2-decompression.md`

### 2A: Cleanup & Foundation
- [ ] Fix RAR4 block iterator for >4GB files (data_size ?u32 → ?u64)
- [ ] Remove 64-file stack allocation limit in FFI archive creation
- [ ] Expose SFX detection through FFI (`rarz_detect_format_sfx`)
- [ ] Migrate from page_allocator to arena allocator for ArchiveHandle
- [ ] Add BLAKE2sp payload verification for RAR5 files

### 2B: Decompression Infrastructure
- [ ] BitReader for compressed streams (`decompress/bitreader.zig`)
- [ ] Canonical Huffman decoder (`decompress/huffman.zig`)
- [ ] LZ window buffer + match-copy primitive (`decompress/lz.zig`)

### 2C: RAR5/7 Decoder
- [ ] v50/v70 block reader + Huffman table loading (`decompress/unpack50.zig`)
- [ ] v50/v70 main decoder loop with LZ matches
- [ ] RAR5 filter subsystem: Delta, E8, E8E9, ARM (`decompress/filters.zig`)

### 2D: Wire Into FFI + Validation
- [ ] Dispatch by algo_version (`decompress/dispatch.zig`)
- [ ] Wire into rarz_extract_to_buffer (replace method!=0 rejection)
- [ ] Enable full-depth validation for compressed files in policy.zig

### 2E: RAR3 Decoder
- [ ] v29 LZ branch (`decompress/unpack29.zig`)
- [ ] PPMd model + range coder (`decompress/ppm.zig`)
- [ ] v29 PPM integration + block switching
- [ ] v29 VM filter subsystem (standard filters by CRC recognition)

### 2F: Legacy Decoders
- [ ] v20/v26 decoder + audio mode (`decompress/unpack20.zig`)
- [ ] v15 decoder + adaptive Huffman (`decompress/unpack15.zig`)

### 2G: Final Integration
- [ ] Compressed archive interop tests (rar → rarz → verify vs unrar)
- [ ] Full-depth validation for compressed archives
- [ ] Update PLAN.md, CODE_MINIMAP.md

## Phase 3: Polish + Advanced Features
- [x] Remove `circumvented_trivial_protection` from ValidationResult (PDF-specific, doesn't belong in rarz) (2026-02-24 EST)
- [ ] Multi-volume awareness and reconstruction
- [x] RAR5 compression for write path (2026-02-22 EST)
- [ ] RAR5 encryption (read + write)
  - [ ] AES-256-CBC decryption of encrypted file data (CRYPT block + per-file encryption)
  - [ ] PBKDF2-HMAC-SHA256 key derivation from password + salt
  - [ ] `--password` CLI flag for extraction and validation of encrypted archives
  - [ ] AES-256-CBC encryption for archive creation (`-p` flag)
  - [ ] Header encryption support (encrypted headers mode)
  - [ ] Interop tests: `rar -p` encrypted → `rarz --password` decrypts, and vice versa
  - [ ] Validation integration: full payload verification when password provided
- [ ] Build argument-compatibility matrix against official `rar` CLI grammar

## Phase 4: Distribution + CI
- [x] Add MIT License (`LICENSE`) (2026-02-20 EST)
- [x] Add `build.zig.zon` for Zig package manager consumption (2026-02-20 EST)
- [x] Create `rarz` repo on GitHub, set SSH remote, push (2026-02-20 EST)
- [x] Create README.md with project overview and usage (2026-02-20 EST)
- [x] Add Garnix CI configuration (`garnix.yaml` + `flake.nix` CI outputs) (2026-02-20 EST)
- [x] Add GitHub Actions CI across 4 platforms: macOS ARM, Linux Intel/ARM, Windows Intel (2026-02-20 EST)
- [x] Verify CI passes on all platforms (2026-02-20 EST)
- [x] Add CI badges to top of README.md (2026-02-20 EST)
- [x] Neutralize implementation-facing upstream-internal wording in source comments and README for legal-surface review (2026-02-22 EST)
- [x] Resolve `v` command surface collision by keeping `v`/`list-verbose` as listing aliases and adding explicit `vol`/`volumes` command; ensure `./test` rebuilds CLI before CLI tests (2026-02-22 EST)

## Fleet Code Review Follow-ups (2026-06-01)

Triaged 5 finding-notes from the fleet code review. Verified each against source before acting.

### Fixed (TDD: failing test first)
- [x] **CRITICAL** — `is_encrypted` hard-coded `0` for RAR5 + unified multi-volume files. Added non-allocating `rar5_headers.extra_has_encryption()` (detects file-encryption extra record, type `0x01`) and wired it into both `root.zig` FFI paths (RAR5 + unified) and the validation `has_encrypted_content` path in `policy.zig` (the `-p` per-file case the CRYPT-block check missed). (2026-06-02)
- [x] **WARN** — `vol_buf` leak on the error path of `writer.zig` `write_volumes_from_payloads`. Added per-iteration (block-scoped) `errdefer allocator.free(vol_buf)`. Regression covered by `checkAllAllocationFailures` test. (2026-06-02)
- [x] **WARN** — `page_allocator` per-file allocation in `validate_rar5_payload` hot loop. Replaced `parse_extra_records` + `extract_blake2sp_hash` with non-allocating `extract_blake2sp_hash_raw()` — zero allocation per file. (Decompression-branch `page_allocator` left as-is: large MB output, acceptable.) (2026-06-02)

### Declined (verified not applicable)
- microbench.zig `page_allocator`: the 1 MB buffer is one-time setup *outside* the timed loop, so it does not affect measured allocator overhead. Left unchanged to avoid perturbing the benchmark baseline.

### Deferred (non-bug refactors — record, do not churn blindly)
- [ ] **WARN** — Decompose large files: `root.zig` (~2173 lines) mixes FFI surface with collection helpers (`collectRar5FilesUnified`, `build_rar5_volume`); 220-line `rarz_extract_to_buffer` FFI export should be a thin shim over a Zig helper. `writer.zig`/`policy.zig` block-construction vs validation logic could split. Consider when next touching these files.
- [ ] **WARN** — `write_archive_compressed` / `write_archive_volumes` / `write_archive_volumes_compressed` likely share prelude/epilogue structure; factor shared helpers (unverified — flagged for confirmation).
- [ ] **INFO** — Duplicated trivial `write_u16_le`/`write_u32_le` wrappers in `rar4_headers.zig` and `policy.zig`; inline or move to a shared `endian.zig`. Cosmetic.
