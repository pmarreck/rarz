# Code Minimap

## Source: `src/lib/`

### `root.zig`
Main library entry point and C FFI exports.
- `rarz_abi_version()` — ABI version (currently 1)
- `rarz_detect_format()` — detect RAR family from buffer (returns 14/15/50 or 0)
- `rarz_open()` / `rarz_close()` — archive handle lifecycle (opaque `ArchiveHandle`)
- `rarz_archive_format()` — query format family of an open archive
- `rarz_file_count()` / `rarz_file_info()` — file listing and metadata via `RarzFileEntry`
- `rarz_validate()` — structural/full validation, returns `RarzValidationResult`
- `rarz_extract_to_buffer()` — store-method extraction to caller buffer
- `rarz_create_archive()` / `rarz_calculate_archive_size()` — RAR5 store-only archive creation

Internal helpers:
- `ArchiveHandle` — opaque struct holding parsed archive state (data slice, family, file lists)
- `RarzFileEntry` — extern struct for C-compatible file metadata
- `RarzValidationResult` — extern struct for C-compatible validation outcome
- `RarzCreateFileEntry` — extern struct for C-compatible archive creation input
- `collectRar5Files()` / `collectRar4Files()` — walk blocks and collect file entries
- `validateRar5Blocks()` / `validateRar4Blocks()` — structural validation with CRC checks
- `build_minimal_rar5()` / `build_rar5_with_file()` — test helpers for synthetic archives

### `detect.zig`
RAR format family detection from raw bytes with SFX prefix scanning.
- `RarFamily` — enum: `rar14`, `rar15`, `rar50`
- `FormatResult` — struct: `family`, `signature_offset`, `signature_len`
- `RAR14_SIG` / `RAR15_SIG` / `RAR50_SIG` — signature byte constants
- `detect_format(data, max_sfx_offset)` — detect RAR family, with optional SFX scan
- `try_match_at(data, offset)` — match signatures at a specific offset (most specific first)

### `reader.zig`
Bounded reader primitives for little-endian and vint decoding.
- `Reader` — struct with position-tracked byte stream
  - `init(data)` — create reader over a byte slice
  - `read_u8()` — read single byte
  - `read_u16_le()` — read u16 little-endian
  - `read_u32_le()` — read u32 little-endian
  - `read_vint()` — read RAR5 variable-length integer (up to 10 bytes)
  - `read_bytes(len)` — read a slice of `len` bytes
  - `skip(len)` — advance position without returning data
  - `remaining()` — bytes left in stream
  - `position()` — current read offset

### `integrity.zig`
Integrity primitives: CRC32, CRC16, and BLAKE2sp.
- `crc32(data)` — CRC-32/ISO-HDLC (standard Ethernet/zlib/PNG CRC32)
- `crc16(data)` — CRC-16/ARC (IBM variant used by RAR legacy headers)
- `blake2sp(data, out)` — BLAKE2sp 8-way parallel tree hash (32-byte output, used by RAR5)

Internal types:
- `Blake2sState` — low-level BLAKE2s state with tree mode parameter support
  - `initFromParams()` — initialize from raw 32-byte parameter block
  - `makeParamBlock()` — build parameter block for tree mode
  - `update()` / `final()` / `compress()` — standard hash state machine
- `initLeaf(leaf_index)` — create leaf-level BLAKE2s for BLAKE2sp
- `initRoot()` — create root-level BLAKE2s for BLAKE2sp
- `g()` — BLAKE2s G mixing function

### `rar4_headers.zig`
RAR 1.5-4.x (legacy) archive header parser.
- `HeaderType` — enum: `mark`, `main`, `file`, `comment`, `av`, `old_service`, `protect`, `sign`, `service`, `end_archive`
- `MainFlags` — struct: `volume`, `comment`, `lock`, `solid`, `protect`, `password`, `first_volume`
- `FileFlags` — struct: `split_before`, `split_after`, `password`, `solid`, `large`, `unicode`, `long_block`
- `BlockHeader` — struct: `head_crc`, `header_type`, `flags`, `head_size`, `data_size`, `header_offset`
- `FileHeader` — struct: block + `packed_size`, `unpacked_size`, `host_os`, `file_crc`, `mtime`, `unpack_version`, `method`, `attributes`, `file_name`
- `ArchiveBlock` — tagged union: `mark`, `main`, `file`, `end_archive`, `other`
- `parse_block_header(reader)` — parse 7-byte base block header (+ optional data_size)
- `parse_main_flags(raw)` — extract main archive flag bits
- `parse_file_flags(raw)` — extract file flag bits
- `parse_file_header(reader, block)` — parse file-specific fields after base header
- `validate_header_crc(data, header)` — verify CRC-16/ARC over header bytes
- `BlockIterator` — iterator struct with `next()` method
- `walk_blocks(data)` — create a block iterator over archive data

### `rar5_headers.zig`
RAR5+ header/block parser with CRC32 validation and block iterator.
- `BlockType` — enum: `main`, `file`, `service`, `crypt`, `end_archive`
- `HeaderFlags` — struct: `extra`, `data`, `skip_if_unknown`, `split_before`, `split_after`, `child`, `inherited`
- `BlockHeader` — struct: `header_crc`, `header_size`, `header_start`, `body_start`, `crc_data_len`, `block_type`, `flags`, `extra_size`, `data_size`
- `MainBlock` — struct: header + `volume`, `volume_number`, `solid`
- `CompressionInfo` — struct: `algo_version`, `solid`, `method`, `dict_bits`, `dict_frac_bits`
- `FileBlock` — struct: header + `is_directory`, `has_mtime`, `has_crc32`, `unpacked_unknown`, `unpacked_size`, `attributes`, `mtime`, `data_crc32`, `compression`, `host_os`, `name`, `extra_data`
- `ExtraRecord` — struct: `field_type`, `data`
- `EndBlock` — struct: header + `next_volume`
- `ArchiveBlock` — tagged union: `main`, `file`, `service`, `crypt`, `end_archive`, `unknown`
- `parse_header_flags(raw)` — extract header flag bits from vint
- `parse_compression_info(raw)` — extract compression bit fields from vint
- `parse_block_header(reader)` — read CRC32 + vint fields, enforce 2 MiB max
- `parse_main_block(reader, header)` — parse MAIN block body
- `parse_file_block(reader, header)` — parse FILE/SERVICE block body
- `parse_end_block(reader, header)` — parse END_ARCHIVE block body
- `parse_extra_records(data, allocator)` — parse extra area into ExtraRecord slice
- `validate_header_crc(archive_data, header)` — verify CRC32 over header bytes
- `BlockIterator` — iterator struct with `next()` method
- `walk_blocks(data)` — create a block iterator over archive data

### `policy.zig`
Validation policy: maps parser outcomes to validation depth levels.
- `ValidationDepth` — enum: `signature`, `structural`, `full`
- `ValidationResult` — struct: `is_valid`, `depth`, `family`, `has_encrypted_content`, `circumvented_trivial_protection`, `error_message`, `block_count`, `file_count`
- `validate(data)` — main entry point: detect format, then structural + payload validation
- `validate_rar4_structural(data, sig_offset)` — walk RAR4 blocks, check CRC16, detect encryption
- `validate_rar4_payload(data, sig_offset)` — structural + store-method CRC32 verification
- `validate_rar5_structural(data, sig_offset, sig_len)` — walk RAR5 blocks, check CRC32, detect encryption
- `validate_rar5_payload(data, sig_offset, sig_len)` — structural + store-method CRC32 verification

### `writer.zig`
RAR5 store-only archive writer.
- `FileEntry` — struct: `name`, `data`, `mtime`, `is_directory`
- `WriteError` — error set: `BufferTooSmall`, `NameTooLong`, `TooManyFiles`
- `encode_vint(value, out)` — encode u64 as RAR5 vint
- `vint_size(value)` — calculate vint encoding length without writing
- `calculate_archive_size(entries)` — predict total archive size for pre-allocation
- `write_archive(entries, output)` — write complete RAR5 store-only archive to buffer

Internal block writers:
- `write_signature(out, pos)` — write 8-byte RAR5 signature
- `write_main_block(out, pos)` — write minimal main block
- `write_file_block(out, pos, entry)` — write file header + store data
- `write_end_block(out, pos)` — write end-of-archive block
- `main_block_size()` / `file_block_size(entry)` / `end_block_size()` — size calculators
