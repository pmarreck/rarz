# RAR Compression Algorithms (Exhaustive English Spec from unRAR 7.2.4 Evaluation)

Status: Draft v1 (evaluation-derived, implementation-planning quality)
Date: 2026-02-20

## 0. Permission / clean-room framing
Yes: producing an exhaustive English technical specification from an evaluation of source is allowed for planning and clean-room coordination in this context.

This document is a behavioral specification, not copied implementation code. It is intended to be consumed by a separate implementation lane.

Not legal advice.

## 1. Source provenance used for this spec
Analyzed source snapshot:
- URL: `https://www.rarlab.com/rar/unrarsrc-7.2.4.tar.gz`
- Extracted under TMPDIR at: `/private/tmp/22469/unrarsrc_fetch/unrar`

All references below cite that extracted source using `file:line` anchors.

## 2. Exhaustive algorithm dispatch matrix
The decoder dispatch is driven by `UnpVer` (algorithm generation), not by the user-facing compression level/method byte alone.

Primary dispatch (`DoUnpack`):
- `15` -> `Unpack15` (RAR 1.5 family)
- `20`, `26` -> `Unpack20` (RAR 2.x family; `26` used for >2GB-era variant)
- `29` -> `Unpack29` (RAR 3.x family)
- `50`, `70` -> `Unpack5` (RAR5/RAR7 family; `70` enables extended distance mode)

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.cpp:160`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.cpp:165`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.cpp:168`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.cpp:172`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.cpp:177`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.cpp:182`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.cpp:184`
- `/private/tmp/22469/unrarsrc_fetch/unrar/headers.hpp:16`
- `/private/tmp/22469/unrarsrc_fetch/unrar/headers.hpp:17`
- `/private/tmp/22469/unrarsrc_fetch/unrar/headers.hpp:18`

Related extraction behavior:
- Legacy files with `UnpVer <= 15` are routed through `DoUnpack(15, ...)` for extraction compatibility.

Citation:
- `/private/tmp/22469/unrarsrc_fetch/unrar/extract.cpp:918`
- `/private/tmp/22469/unrarsrc_fetch/unrar/extract.cpp:919`

## 3. What the `Method` field means vs what `UnpVer` means
`Method` and `UnpVer` are distinct:
- `UnpVer`: selects decompression algorithm generation (15/20/26/29/50/70).
- `Method`: compression level/profile inside that generation; `method==0` means stored (no compression), otherwise compressed payload.

Evidence:
- Method parsing in legacy headers: subtracts `0x30` (`0`) to get internal 0..5 range.
- For RAR5+, method comes from `CompInfo` bits.
- Store path bypasses unpacker and copies bytes (`UnstoreFile`).

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/arcread.cpp:282`
- `/private/tmp/22469/unrarsrc_fetch/unrar/arcread.cpp:836`
- `/private/tmp/22469/unrarsrc_fetch/unrar/extract.cpp:900`
- `/private/tmp/22469/unrarsrc_fetch/unrar/extract.cpp:901`
- `/private/tmp/22469/unrarsrc_fetch/unrar/arccmt.cpp:58`
- `/private/tmp/22469/unrarsrc_fetch/unrar/arccmt.cpp:60`

## 4. RAR 1.4 / 1.5 family compression behavior

### 4.1 RAR 1.4 compatibility entry
RAR 1.4 headers set legacy unpack versions (10/13) and method byte, but extraction path normalizes to v1.5 decoder path (`DoUnpack(15,...)`) when needed.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/arcread.cpp:1258`
- `/private/tmp/22469/unrarsrc_fetch/unrar/arcread.cpp:1296`
- `/private/tmp/22469/unrarsrc_fetch/unrar/arcread.cpp:1298`
- `/private/tmp/22469/unrarsrc_fetch/unrar/extract.cpp:918`
- `/private/tmp/22469/unrarsrc_fetch/unrar/extract.cpp:919`

### 4.2 Core RAR1.5 decoding model (`Unpack15`)
RAR1.5 mixes three token modes under adaptive state:
- `HuffDecode` for literals / Huffman-driven symbols.
- `LongLZ` for long match distance/length forms.
- `ShortLZ` for short/repeat-oriented matches.

A flag buffer (`FlagBuf`, `FlagsCnt`) plus moving averages (`Nhfb`, `Nlzb`, `Avr*`) drives branch preference and model adaptation.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack15.cpp:40`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack15.cpp:70`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack15.cpp:82`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack15.cpp:120`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack15.cpp:232`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack15.cpp:324`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack15.cpp:402`

### 4.3 Adaptive Huffman structures
RAR1.5 uses several adaptive symbol sets (`ChSet`, `ChSetA`, `ChSetB`, `ChSetC`) with placement arrays (`NToPl*`) and periodic correction (`CorrHuff`).

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.hpp:305`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.hpp:306`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack15.cpp:447`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack15.cpp:462`

### 4.4 Match-copy semantics and corruption hardening
Copy path decrements destination size and performs guarded copy; invalid distances can be zero-filled for deterministic continuation on corruption.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack15.cpp:474`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack15.cpp:478`

## 5. RAR 2.x compression behavior (`Unpack20`)

### 5.1 Token alphabets and Huffman table groups
RAR2.x builds multiple decode tables:
- Literal/main table `LD`.
- Distance table `DD`.
- Repetition-length table `RD`.
- Optional per-channel multimedia tables `MD[]` (audio mode).

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:69`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:85`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:117`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:174`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:251`
- `/private/tmp/22469/unrarsrc_fetch/unrar/compress.hpp:39`
- `/private/tmp/22469/unrarsrc_fetch/unrar/compress.hpp:40`
- `/private/tmp/22469/unrarsrc_fetch/unrar/compress.hpp:41`
- `/private/tmp/22469/unrarsrc_fetch/unrar/compress.hpp:43`

### 5.2 LZ branch
Main-symbol classes:
- `<256`: literal byte.
- `>269`: new length/distance match.
- `269`: table refresh marker.
- `256`: repeat last match.
- `257..260`: reuse one of recent distances + new length.
- `261..269`: 2-byte short-distance match class.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:69`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:76`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:103`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:109`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:114`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:137`

### 5.3 Dedicated audio mode
When `UnpAudioBlock` is set, symbols are interpreted as audio residuals and decoded via an adaptive linear predictor per channel.
Predictor uses `K1..K5`, `D1..D4`, previous channel delta, and periodic coefficient adaptation by minimum absolute-difference bucket.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:52`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:62`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:182`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:189`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:296`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:304`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack20.cpp:329`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.hpp:170`

## 6. RAR 3.x compression behavior (`Unpack29`)
RAR3 is dual-mode per block:
- `BLOCK_LZ` (Huffman/LZ family)
- `BLOCK_PPM` (PPMd + range coder)

Citation:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.hpp:331`

### 6.1 Block-mode selection and table load
`ReadTables30` chooses block mode:
- if top bit set: switch to PPM and call `PPM.DecodeInit(...)`.
- else: stay in LZ and load Huffman decode tables.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:631`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:640`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:642`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:643`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:645`

### 6.2 LZ branch details
LZ branch in RAR3 extends RAR2 style with:
- low-distance extra coding (`LDD`) and low-distance repetition state.
- token `256` end-of-block control (`ReadEndOfBlock`).
- token `257` VM filter command (`ReadVMCode`).
- token `258` full repeat of last match.
- token `259..262` old-distance repeats with new length.
- token `263..270` short-distance 2-byte matches.
- token `>=271` full length/distance matches.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:145`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:154`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:172`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:204`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:210`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:216`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:222`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:241`

### 6.3 PPM branch details
In PPM mode, decoded symbols are either literals or escape-control opcodes:
- `0`: end of current PPM block, read new tables.
- `2`: end-of-file marker.
- `3`: VM code block follows.
- `4`: embedded LZ match tuple in PPM stream.
- `5`: one-byte-distance RLE in PPM stream.
- `1`: escaped escape-byte literal.

Corruption path explicitly cleans PPM state and falls back to LZ mode for safety.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:72`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:84`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:87`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:95`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:97`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:103`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:124`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:1`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:7`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:9`

### 6.4 RAR3 VM/filter subsystem
RAR3 supports an embedded VM-driven filter stack:
- VM bytecode can be supplied from LZ or PPM stream (`ReadVMCode`, `ReadVMCodePPM`).
- `AddVMCode` manages filter identity, reuse, parameterization, and data block placement.
- Filters are queued and applied during window write-out.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:291`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:326`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:364`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:526`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack30.cpp:567`

### 6.5 Recognized standard VM filters in RAR3
Standard filter IDs include:
- E8
- E8E9
- Itanium
- RGB
- Audio
- Delta

They are recognized by known `(code length, CRC32)` pairs in `RarVM::Prepare`.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/rarvm.hpp:7`
- `/private/tmp/22469/unrarsrc_fetch/unrar/rarvm.cpp:49`
- `/private/tmp/22469/unrarsrc_fetch/unrar/rarvm.cpp:55`
- `/private/tmp/22469/unrarsrc_fetch/unrar/rarvm.cpp:56`
- `/private/tmp/22469/unrarsrc_fetch/unrar/rarvm.cpp:57`
- `/private/tmp/22469/unrarsrc_fetch/unrar/rarvm.cpp:58`
- `/private/tmp/22469/unrarsrc_fetch/unrar/rarvm.cpp:59`
- `/private/tmp/22469/unrarsrc_fetch/unrar/rarvm.cpp:60`

### 6.6 PPMd core model used by RAR3
RAR3 PPM is based on PPMd (public-domain lineage noted in source), with:
- context/state structures (`RARPPM_CONTEXT`, `RARPPM_STATE`).
- range coder arithmetic decoding (`RangeCoder`).
- memory suballocator (`SubAllocator`) with unit-list allocator.
- model reset/init from stream header (`DecodeInit`) with max-order translation.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/model.cpp:1`
- `/private/tmp/22469/unrarsrc_fetch/unrar/model.hpp:46`
- `/private/tmp/22469/unrarsrc_fetch/unrar/model.hpp:54`
- `/private/tmp/22469/unrarsrc_fetch/unrar/model.hpp:92`
- `/private/tmp/22469/unrarsrc_fetch/unrar/model.hpp:106`
- `/private/tmp/22469/unrarsrc_fetch/unrar/coder.cpp:9`
- `/private/tmp/22469/unrarsrc_fetch/unrar/coder.cpp:21`
- `/private/tmp/22469/unrarsrc_fetch/unrar/coder.cpp:44`
- `/private/tmp/22469/unrarsrc_fetch/unrar/model.cpp:571`
- `/private/tmp/22469/unrarsrc_fetch/unrar/model.cpp:602`
- `/private/tmp/22469/unrarsrc_fetch/unrar/suballoc.cpp:79`
- `/private/tmp/22469/unrarsrc_fetch/unrar/suballoc.cpp:106`

## 7. RAR 5 / RAR 7 compression behavior (`Unpack5`)
RAR5 and RAR7 share the same unpack engine (`Unpack5`) with a mode flag (`ExtraDist`) for extended distance tables in RAR7.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.cpp:182`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.cpp:183`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.cpp:184`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.hpp:401`

### 7.1 RAR5 block-level compressed stream
Compressed stream is chunked into blocks with:
- per-block flags/checksum/size metadata,
- optional new Huffman tables,
- last-block marker.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:558`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:567`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:589`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:605`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:606`

### 7.2 Huffman tables and symbol groups
RAR5 loads code-length Huffman descriptions, then builds decode tables for:
- literals/main slots `LD`
- distances `DD`
- low distance bits `LDD`
- repeat lengths `RD`

Distance alphabet size changes by mode:
- RAR5 base: `DCB=64`
- RAR7 extended: `DCX=80`

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:612`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:644`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:709`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:710`
- `/private/tmp/22469/unrarsrc_fetch/unrar/compress.hpp:24`
- `/private/tmp/22469/unrarsrc_fetch/unrar/compress.hpp:25`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:647`

### 7.3 Main-slot decoding classes
In `Unpack5`:
- `<256`: literal byte.
- `>=262`: new match (length slot + distance slot + optional low dist bits).
- `256`: filter descriptor command.
- `257`: repeat last length at most recent distance.
- `258..261`: prior-distance repeat with fresh length slot.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:63`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:72`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:74`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:77`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:139`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:146`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:155`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:163`

### 7.4 RAR5 filter types that are actually applied in this path
`ApplyFilter` handles:
- `FILTER_E8`
- `FILTER_E8E9`
- `FILTER_ARM`
- `FILTER_DELTA`

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:422`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:427`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:428`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:462`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack50.cpp:485`

Filter enum source of truth (broader than RAR5 apply set):
- Delta, E8, E8E9, ARM, Audio, RGB, Itanium, Text, ...

Citation:
- `/private/tmp/22469/unrarsrc_fetch/unrar/compress.hpp:51`
- `/private/tmp/22469/unrarsrc_fetch/unrar/compress.hpp:54`

### 7.5 Dictionary and distance ranges
RAR5/7 dictionary info comes from `CompInfo` bits. Source comments and logic indicate 128KB..1TB encoding support, with additional compatibility/limits.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/headers5.hpp:56`
- `/private/tmp/22469/unrarsrc_fetch/unrar/arcread.cpp:871`
- `/private/tmp/22469/unrarsrc_fetch/unrar/arcread.cpp:880`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.cpp:89`
- `/private/tmp/22469/unrarsrc_fetch/unrar/archive.cpp:348`
- `/private/tmp/22469/unrarsrc_fetch/unrar/archive.cpp:349`

## 8. Shared low-level decoding machinery across generations

### 8.1 Canonical Huffman decode builder
`MakeDecodeTables` is the common builder for decode tables from code-length arrays; `DecodeNumber` performs quick-path and full-path symbol resolution.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpack.cpp:246`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpackinline.cpp:115`

### 8.2 LZ match-copy primitive
Core string copy (`CopyString`) handles overlap, wrap, invalid-distance hardening, and deterministic zero-filling for malformed data before first window is established.

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpackinline.cpp:13`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpackinline.cpp:19`
- `/private/tmp/22469/unrarsrc_fetch/unrar/unpackinline.cpp:35`

## 9. Signature families tied to algorithm eras
Signatures recognized:
- RAR1.4: `52 45 7E 5E`
- RAR1.5-4.x: `52 61 72 21 1A 07 00`
- RAR5+: `52 61 72 21 1A 07 01 00`

Future marker handling exists (`D[6] > 1 && D[6] < 5`).

Citations:
- `/private/tmp/22469/unrarsrc_fetch/unrar/archive.cpp:100`
- `/private/tmp/22469/unrarsrc_fetch/unrar/archive.cpp:105`
- `/private/tmp/22469/unrarsrc_fetch/unrar/archive.cpp:109`
- `/private/tmp/22469/unrarsrc_fetch/unrar/archive.cpp:115`
- `/private/tmp/22469/unrarsrc_fetch/unrar/archive.cpp:119`
- `/private/tmp/22469/unrarsrc_fetch/unrar/archive.cpp:122`
- `/private/tmp/22469/unrarsrc_fetch/unrar/archive.cpp:181`
- `/private/tmp/22469/unrarsrc_fetch/unrar/archive.cpp:183`

## 10. Practical clean-room implementation notes for `rarz`
1. Implement algorithm-selection strictly by `UnpVer` dispatch classes (15/20/26/29/50/70).
2. Keep `Method` interpretation separate (store vs compressed level), with `method==0` short-circuit to unstore.
3. Treat RAR3 as two codecs in one stream (LZ + PPM), with full escape semantics.
4. Treat RAR3 VM filters and RAR5 filters as separate subsystems (they are not identical).
5. Keep corruption-hardening behavior explicit (distance bounds, deterministic fallback paths) for `validate`-style integrity classification.

## 11. Out-of-scope in this document
This document covers compression/decompression algorithms and transforms only.
It intentionally does not specify encryption internals, key derivation, password workflows, or recovery-volume math.
