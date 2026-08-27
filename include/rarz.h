#ifndef RARZ_H
#define RARZ_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ========================================================================== */
/* ABI version                                                                */
/* ========================================================================== */

uint32_t rarz_abi_version(void);

/* ========================================================================== */
/* Error reporting                                                            */
/* ========================================================================== */

/**
 * Get the last error message (thread-local).
 * Returns NULL if no error, or a static string describing the last error.
 * The returned pointer is valid until the next FFI call on the same thread.
 */
const char *rarz_last_error(void);

/** Clear the last error message (thread-local). */
void rarz_clear_error(void);

/* ========================================================================== */
/* Format detection                                                           */
/* ========================================================================== */

/**
 * Detect RAR format family from buffer.
 * Returns: 0=unknown, 14=RAR1.4, 15=RAR1.5-4.x, 50=RAR5+
 */
int32_t rarz_detect_format(const uint8_t *data, size_t len);

/**
 * Detect RAR format family with SFX prefix scanning.
 * Scans up to max_sfx_offset bytes for a RAR signature.
 * Returns: 0=unknown, 14=RAR1.4, 15=RAR1.5-4.x, 50=RAR5+
 */
int32_t rarz_detect_format_sfx(const uint8_t *data, size_t len, size_t max_sfx_offset);

/* ========================================================================== */
/* Archive handle management                                                  */
/* ========================================================================== */

/** Opaque archive handle. */
typedef struct rarz_archive rarz_archive;

/**
 * Open archive from memory buffer. Returns NULL on failure.
 * The data pointer must remain valid for the lifetime of the handle.
 * The archive handle does NOT take ownership of the data.
 */
rarz_archive *rarz_open(const uint8_t *data, size_t len);

/**
 * Open multi-volume archive from memory buffers. Returns NULL on failure.
 * All volume data pointers must remain valid for the lifetime of the handle.
 * Volumes must be in order (part1, part2, ...).
 */
rarz_archive *rarz_open_volumes(const uint8_t **volumes,
                                const size_t *lengths,
                                uint32_t volume_count);

/** Close archive and free handle. */
void rarz_close(rarz_archive *archive);

/** Get format family (0/14/15/50). */
int32_t rarz_archive_format(const rarz_archive *archive);

/** Get number of file entries. */
uint32_t rarz_file_count(const rarz_archive *archive);

/* ========================================================================== */
/* File listing                                                               */
/* ========================================================================== */

typedef struct {
	const char *name;       /* UTF-8, NOT null-terminated */
	uint32_t name_len;
	uint64_t unpacked_size;
	uint64_t packed_size;
	uint32_t crc32;
	uint32_t mtime;
	uint8_t method;         /* 0=store, 1-5=compressed */
	uint8_t is_directory;
	uint8_t is_encrypted;
	uint8_t host_os;
	uint8_t split_before;   /* 1 if file continues from previous volume */
	uint8_t split_after;    /* 1 if file continues to next volume */
} rarz_file_entry;

/**
 * Get file info by index.
 * Returns 0 on success, -1 on invalid index or null handle.
 */
int32_t rarz_file_info(const rarz_archive *archive, uint32_t index,
                       rarz_file_entry *out);

/* ========================================================================== */
/* Validation                                                                 */
/* ========================================================================== */

typedef struct {
	int32_t is_valid;       /* 1=valid, 0=invalid */
	int32_t family;         /* 0/14/15/50 */
	int32_t has_encrypted;  /* 1 if encrypted content found */
	uint32_t block_count;
	uint32_t file_count;
	const char *error_msg;  /* NULL or static string */
} rarz_validation_result;

/** Validate archive from buffer. */
rarz_validation_result rarz_validate(const uint8_t *data, size_t len);

/** Validate multi-volume archive from memory buffers.
 * All volume data pointers must remain valid for the duration of the call.
 * Volumes must be in order (part1, part2, ...).
 */
rarz_validation_result rarz_validate_volumes(const uint8_t **volumes,
                                             const size_t *lengths,
                                             uint32_t volume_count);

/* ========================================================================== */
/* Extraction                                                                 */
/* ========================================================================== */

/**
 * Extract file by index to caller-provided buffer.
 * Supports both stored and compressed files (all RAR versions: v15/v20/v26/v29/v50/v70).
 * Returns: bytes written on success, -1 on error, -2 if buffer too small,
 *          -3 on decompression error.
 */
int64_t rarz_extract_to_buffer(const rarz_archive *archive, uint32_t index,
                               uint8_t *out_buf, size_t out_len);

/* ========================================================================== */
/* Archive creation                                                           */
/* ========================================================================== */

/** File entry for archive creation (input). */
typedef struct {
	const char *name;       /* UTF-8, NOT null-terminated */
	uint32_t name_len;
	const uint8_t *data;    /* file content */
	uint64_t data_len;
	uint32_t mtime;         /* DOS timestamp */
	uint8_t is_directory;
	uint8_t host_os;        /* 0=Windows, 3=Unix */
	uint8_t _pad[2];        /* alignment padding */
	uint32_t attributes;    /* OS-specific (Unix: st_mode, Windows: file attrs) */
} rarz_create_file_entry;

/**
 * Calculate required buffer size for a store-only RAR5 archive.
 * Returns size on success, -1 on error.
 */
int64_t rarz_calculate_archive_size(const rarz_create_file_entry *entries,
                                    uint32_t count);

/**
 * Create a store-only RAR5 archive from file entries.
 * Returns bytes written on success, -1 on error, -2 if buffer too small.
 */
int64_t rarz_create_archive(const rarz_create_file_entry *entries,
                            uint32_t count,
                            uint8_t *out_buf, size_t out_len);

/**
 * Create a compressed RAR5 archive from file entries.
 * method: 0=store, 1-5=compression levels (1=fastest, 5=best).
 * Returns bytes written on success, -1 on error, -2 if buffer too small,
 *         -3 on compression error.
 */
int64_t rarz_create_archive_compressed(const rarz_create_file_entry *entries,
                                       uint32_t count,
                                       uint8_t *out_buf, size_t out_len,
                                       uint8_t method);

/* ========================================================================== */
/* Volume creation                                                            */
/* ========================================================================== */

/** Opaque handle for volume creation result. */
typedef struct rarz_volumes rarz_volumes;

/**
 * Create a multi-volume archive from file entries.
 * method: 0=store, 1-5=compression levels.
 * volume_size: maximum bytes per volume (minimum 1024).
 * Returns NULL on error (check rarz_last_error()).
 */
rarz_volumes *rarz_create_volumes(const rarz_create_file_entry *entries,
                                   uint32_t count, uint64_t volume_size,
                                   uint8_t method);

/** Get the number of volumes in the result. */
uint32_t rarz_volume_count(const rarz_volumes *handle);

/**
 * Get volume data by index.
 * Sets *out_buf to point to the volume data and *out_len to its size.
 * Returns 0 on success, -1 on error.
 */
int32_t rarz_volume_data(const rarz_volumes *handle, uint32_t index,
                          const uint8_t **out_buf, size_t *out_len);

/** Free volume creation result. */
void rarz_volumes_free(rarz_volumes *handle);

/* ========================================================================== */
/* Verify-only entry verification                                             */
/* ========================================================================== */

/** Entry verified: every checksum it carries matched. */
#define RARZ_VERIFY_OK                0
/** Entry decoded, but a stored checksum did not match. */
#define RARZ_VERIFY_CHECKSUM_MISMATCH 1
/** Entry decoded, but carries no checksum — nothing could be verified.
 *  Deliberately NOT reported as OK: "nothing to check" is not "nothing wrong". */
#define RARZ_VERIFY_NO_CHECKSUM       2
/** Entry could not be decoded (unsupported filter, corrupt stream, ...).
 *  Distinct from MISMATCH: this is "cannot verify", not "verified bad". */
#define RARZ_VERIFY_UNSUPPORTED       3
/** Bad arguments, index out of range, or a truncated declaration. */
#define RARZ_VERIFY_ERROR             4

typedef struct {
	int32_t  status;           /* one of RARZ_VERIFY_*                        */
	uint64_t bytes_verified;   /* decoded bytes actually hashed               */
	uint32_t crc32_expected;   /* valid when has_crc32                        */
	uint32_t crc32_actual;     /* valid when has_crc32                        */
	uint8_t  has_crc32;
	uint8_t  checked_blake2sp; /* 1 when a BLAKE2sp was present AND matched   */
	uint8_t  is_directory;     /* directory entries have no payload to verify */
	/*
	 * 1 when this entry's content is encrypted. Reported beside the status
	 * rather than folded into it: an encrypted entry and a failed decode both
	 * return RARZ_VERIFY_UNSUPPORTED, and only this field separates them.
	 */
	uint8_t  is_encrypted;
} rarz_verify_result;

/**
 * Verify one entry by decoding it and checking the checksums stored in its
 * header, WITHOUT materialising the decoded bytes.
 *
 * Use this instead of rarz_extract_to_buffer when you want a verdict rather
 * than the contents: extraction forces you to allocate unpacked_size bytes for
 * data you intend to discard, whereas this streams the decoder's output into a
 * hash. Peak memory is the LZ window plus the hash state, whatever the size of
 * the entry.
 *
 * On a SOLID archive, verifying entries in ascending index order costs a single
 * pass over the shared stream. Verifying out of order still returns correct
 * results, but may replay predecessors to rebuild the window.
 *
 * Returns the same value written to out_result->status.
 */
int32_t rarz_verify_file(const rarz_archive *archive, uint32_t index,
                          rarz_verify_result *out_result);

/** Every enumerated entry was verified against stored integrity evidence. */
#define RARZ_ARCHIVE_VERIFY_VERIFIED   0
/** At least one entry was proven damaged. Other incomplete counts still apply. */
#define RARZ_ARCHIVE_VERIFY_DAMAGED    1
/** No damage was proven, but at least one entry or the format was unverifiable. */
#define RARZ_ARCHIVE_VERIFY_INCOMPLETE 2
/** The call itself was invalid; no archive verdict was produced. */
#define RARZ_ARCHIVE_VERIFY_ERROR      3

/**
 * Lossless archive rollup of `rarz_verify_file` evidence.
 *
 * Accounting invariant:
 *   verified + damaged + unsupported + no_checksum + error + directories
 *     == entry_count
 *
 * Counts remain separate even when the overall status is DAMAGED, so a mixed
 * archive such as "one damaged entry, one encrypted entry" is expressible.
 */
typedef struct {
	int32_t  status; /* one of RARZ_ARCHIVE_VERIFY_* */
	uint32_t entry_count;
	uint32_t verified_entry_count;
	uint32_t damaged_entry_count;
	uint32_t unsupported_entry_count;
	uint32_t no_checksum_entry_count;
	uint32_t error_entry_count;
	uint32_t directory_count;
	uint8_t  format_supported;
	uint8_t  _pad[3];
	/**
	 * Entries whose CONTENT is encrypted. Deliberately NOT part of the
	 * accounting invariant above: encryption is a property of an entry, not an
	 * outcome, so an encrypted entry is ALSO counted in exactly one outcome
	 * bucket (today `unsupported`; `verified` if a password API ever lands).
	 *
	 * Without this, `unsupported_entry_count` cannot say WHY an entry went
	 * unverified — a failed decode and an encrypted entry land in the same
	 * bucket. Derive the archive's encryption class from it:
	 *
	 *   content = entry_count - directory_count
	 *   encrypted == 0        -> no encryption
	 *   encrypted == content  -> wholly encrypted
	 *   otherwise             -> MIXED: some entries were verified, some
	 *                            cannot be without a password
	 */
	uint32_t encrypted_entry_count;
} rarz_verify_archive_summary;

/**
 * Verify all entries without materialising decoded payloads.
 *
 * Returns the same value written to out_summary->status. Damage takes
 * precedence over incomplete evidence, while every count remains available.
 * RAR 1.4 is currently reported INCOMPLETE with format_supported=0.
 */
int32_t rarz_verify_archive(const rarz_archive *archive,
							rarz_verify_archive_summary *out_summary);

/**
 * Largest dictionary window this library will allocate to decode any entry of
 * this archive, in bytes — computed from the parsed headers alone, no decode.
 *
 * Verification's peak anonymous memory is this window plus fixed decoder and
 * hash state, INDEPENDENT of archive or entry size: entries larger than the
 * window stream through it (multi-volume verification additionally reassembles
 * the entry's PACKED bytes contiguously). An admission estimator enforcing a
 * memory ceiling should budget against this instead of any archive-size cap.
 *
 * RAR5 declares up to 1 GiB (spec); RAR4 up to 4 MiB; RAR7 archives may
 * declare more. Returns 0 when no window is known (an unparsed format such as
 * RAR 1.4, or an archive with no entries) — treat 0 as "cannot budget", never
 * as "free".
 */
uint64_t rarz_max_dictionary_size(const rarz_archive *archive);

/**
 * 1 when the archive uses -hp header encryption: the headers themselves are
 * ciphertext, so entries cannot be enumerated without a password. Treat as
 * NOT COVERED (INFO/WARN in a consumer's vocabulary), never as damage.
 */
uint8_t rarz_header_encrypted(const rarz_archive *archive);

#ifdef __cplusplus
}
#endif

#endif /* RARZ_H */
