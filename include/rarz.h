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
	int32_t depth;          /* 0=signature, 1=structural, 2=full */
	int32_t family;         /* 0/14/15/50 */
	int32_t has_encrypted;  /* 1 if encrypted content found */
	uint32_t block_count;
	uint32_t file_count;
	const char *error_msg;  /* NULL or static string */
} rarz_validation_result;

/** Validate archive from buffer. */
rarz_validation_result rarz_validate(const uint8_t *data, size_t len);

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
/* Archive creation (store method only)                                       */
/* ========================================================================== */

/** File entry for archive creation (input). */
typedef struct {
	const char *name;       /* UTF-8, NOT null-terminated */
	uint32_t name_len;
	const uint8_t *data;    /* file content */
	uint64_t data_len;
	uint32_t mtime;         /* DOS timestamp */
	uint8_t is_directory;
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

#ifdef __cplusplus
}
#endif

#endif /* RARZ_H */
