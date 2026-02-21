#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <errno.h>
#ifndef _WIN32
#include <libgen.h>
#endif
#include "rarz.h"

#ifdef _WIN32
#define MKDIR(path) mkdir(path)
#else
#define MKDIR(path) mkdir(path, 0755)
#endif

/* ========================================================================== */
/* Command enum + parser                                                      */
/* ========================================================================== */

typedef enum {
	CMD_UNKNOWN = -1,
	CMD_HELP,
	CMD_TEST,
	CMD_LIST,
	CMD_EXTRACT,
	CMD_ADD,
} Command;

static Command parse_command(const char *arg) {
	if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) return CMD_HELP;
	if (strcmp(arg, "t") == 0 || strcmp(arg, "test") == 0) return CMD_TEST;
	if (strcmp(arg, "l") == 0 || strcmp(arg, "list") == 0) return CMD_LIST;
	if (strcmp(arg, "x") == 0 || strcmp(arg, "extract") == 0) return CMD_EXTRACT;
	if (strcmp(arg, "a") == 0 || strcmp(arg, "add") == 0) return CMD_ADD;
	return CMD_UNKNOWN;
}

/* ========================================================================== */
/* Usage / help                                                               */
/* ========================================================================== */

static void print_usage(void) {
	printf("rarz - clean-room RAR archive toolkit (2026 Peter Marreck)\n");
	printf("RAR format by Alexander L. Roshal\n\n");
	printf("Usage:\n");
	printf("  rarz t|test <archive>            Test archive integrity\n");
	printf("  rarz l|list <archive>            List archive contents\n");
	printf("  rarz x|extract <archive> [dest]  Extract with full paths\n");
	printf("  rarz a|add [-m0..-m5] <archive> <files...>\n");
	printf("                                   Add files to archive\n");
	printf("                                   -m0=store, -m1..-m5=compress (default -m3)\n");
	printf("  rarz --help                      Show this help\n");
}

/* ========================================================================== */
/* File I/O helpers                                                           */
/* ========================================================================== */

/**
 * Read an entire file into a malloc'd buffer. Caller must free().
 * Returns NULL on failure, sets *out_len to file size on success.
 */
static uint8_t *read_file(const char *path, size_t *out_len) {
	struct stat st;
	if (stat(path, &st) != 0) {
		fprintf(stderr, "error: cannot stat '%s': %s\n", path, strerror(errno));
		return NULL;
	}
	if (!S_ISREG(st.st_mode)) {
		fprintf(stderr, "error: '%s' is not a regular file\n", path);
		return NULL;
	}

	size_t size = (size_t)st.st_size;
	FILE *f = fopen(path, "rb");
	if (!f) {
		fprintf(stderr, "error: cannot open '%s': %s\n", path, strerror(errno));
		return NULL;
	}

	uint8_t *buf = (uint8_t *)malloc(size);
	if (!buf) {
		fprintf(stderr, "error: cannot allocate %zu bytes\n", size);
		fclose(f);
		return NULL;
	}

	size_t nread = fread(buf, 1, size, f);
	fclose(f);
	if (nread != size) {
		fprintf(stderr, "error: short read on '%s' (got %zu, expected %zu)\n",
		        path, nread, size);
		free(buf);
		return NULL;
	}

	*out_len = size;
	return buf;
}

/**
 * Recursive mkdir -p equivalent. Creates all components of path.
 * Returns 0 on success, -1 on failure.
 */
static int mkdirs(const char *path) {
	char tmp[4096];
	size_t len = strlen(path);
	if (len == 0 || len >= sizeof(tmp)) return -1;

	memcpy(tmp, path, len + 1);

	/* Strip trailing slash */
	if (tmp[len - 1] == '/') tmp[len - 1] = '\0';

	for (char *p = tmp + 1; *p; p++) {
		if (*p == '/') {
			*p = '\0';
			if (MKDIR(tmp) != 0 && errno != EEXIST) return -1;
			*p = '/';
		}
	}
	if (MKDIR(tmp) != 0 && errno != EEXIST) return -1;
	return 0;
}

/**
 * Ensure the parent directory of a file path exists.
 * Returns 0 on success, -1 on failure.
 */
static int ensure_parent_dir(const char *filepath) {
	char tmp[4096];
	size_t len = strlen(filepath);
	if (len == 0 || len >= sizeof(tmp)) return -1;

	memcpy(tmp, filepath, len + 1);

	/* Find last slash */
	char *last_slash = strrchr(tmp, '/');
	if (!last_slash) return 0; /* No directory component */

	*last_slash = '\0';
	if (tmp[0] == '\0') return 0; /* Root directory */

	return mkdirs(tmp);
}

/* ========================================================================== */
/* Format helpers                                                             */
/* ========================================================================== */

static const char *format_name(int32_t family) {
	switch (family) {
	case 14: return "RAR1.4";
	case 15: return "RAR1.5-4.x";
	case 50: return "RAR5";
	default: return "unknown";
	}
}

static const char *depth_name(int32_t depth) {
	switch (depth) {
	case 0: return "signature";
	case 1: return "structural";
	case 2: return "full";
	default: return "unknown";
	}
}

static const char *method_name(uint8_t method) {
	switch (method) {
	case 0: return "Store";
	case 1: return "m1";
	case 2: return "m2";
	case 3: return "m3";
	case 4: return "m4";
	case 5: return "m5";
	default: return "?";
	}
}

static const char *host_os_name(uint8_t os) {
	switch (os) {
	case 0: return "Windows";
	case 1: return "Unix";
	default: return "unknown";
	}
}

/* ========================================================================== */
/* cmd_test                                                                   */
/* ========================================================================== */

static int cmd_test(const char *path) {
	size_t len = 0;
	uint8_t *data = read_file(path, &len);
	if (!data) return 1;

	printf("Testing archive: %s\n", path);

	rarz_validation_result result = rarz_validate(data, len);

	printf("Validation: %s\n", result.is_valid ? "VALID" : "INVALID");
	printf("Depth: %s\n", depth_name(result.depth));
	printf("Format: %s\n", format_name(result.family));
	printf("Blocks: %u, Files: %u\n", result.block_count, result.file_count);
	if (result.has_encrypted)
		printf("Encrypted: yes\n");
	if (result.error_msg)
		printf("Error: %s\n", result.error_msg);

	free(data);
	return result.is_valid ? 0 : 1;
}

/* ========================================================================== */
/* cmd_list                                                                   */
/* ========================================================================== */

static int cmd_list(const char *path) {
	size_t len = 0;
	uint8_t *data = read_file(path, &len);
	if (!data) return 1;

	rarz_archive *archive = rarz_open(data, len);
	if (!archive) {
		fprintf(stderr, "error: failed to open archive '%s'\n", path);
		free(data);
		return 1;
	}

	uint32_t count = rarz_file_count(archive);

	printf(" %8s  %8s  %5s  %-8s  %-10s  %-6s  %s\n",
	       "Unpacked", "Packed", "Ratio", "CRC32", "Date", "Method", "Name");
	printf(" %8s  %8s  %5s  %-8s  %-10s  %-6s  %s\n",
	       "--------", "--------", "-----", "--------", "----------", "------", "----");

	uint64_t total_unpacked = 0;
	uint64_t total_packed = 0;

	for (uint32_t i = 0; i < count; i++) {
		rarz_file_entry entry;
		if (rarz_file_info(archive, i, &entry) != 0) continue;

		/* Null-terminate the name */
		char name_buf[4096];
		uint32_t nlen = entry.name_len < sizeof(name_buf) - 1
		                ? entry.name_len : (uint32_t)(sizeof(name_buf) - 1);
		memcpy(name_buf, entry.name, nlen);
		name_buf[nlen] = '\0';

		/* Compute ratio */
		int ratio = 100;
		if (entry.unpacked_size > 0) {
			ratio = (int)((entry.packed_size * 100) / entry.unpacked_size);
		}

		/* Decode mtime (DOS format: bits 25-31=year+1980, 21-24=month, 16-20=day) */
		char date_buf[16];
		if (entry.mtime != 0) {
			int year = ((entry.mtime >> 25) & 0x7F) + 1980;
			int month = (entry.mtime >> 21) & 0x0F;
			int day = (entry.mtime >> 16) & 0x1F;
			snprintf(date_buf, sizeof(date_buf), "%04d-%02d-%02d", year, month, day);
		} else {
			snprintf(date_buf, sizeof(date_buf), "          ");
		}

		printf(" %8llu  %8llu  %3d%%  %08X  %s  %-6s  %s%s\n",
		       (unsigned long long)entry.unpacked_size,
		       (unsigned long long)entry.packed_size,
		       ratio,
		       entry.crc32,
		       date_buf,
		       method_name(entry.method),
		       name_buf,
		       entry.is_directory ? "/" : "");

		total_unpacked += entry.unpacked_size;
		total_packed += entry.packed_size;
	}

	printf(" %8s  %8s  %5s  %8s  %10s  %-6s  %s\n",
	       "--------", "--------", "", "", "", "----", "");
	printf(" %8llu  %8llu  %5s  %8s  %10s  %-6s  %u file%s\n",
	       (unsigned long long)total_unpacked,
	       (unsigned long long)total_packed,
	       "", "", "", "",
	       count, count == 1 ? "" : "s");

	rarz_close(archive);
	free(data);
	return 0;
}

/* ========================================================================== */
/* cmd_extract                                                                */
/* ========================================================================== */

static int cmd_extract(const char *archive_path, const char *dest_dir) {
	size_t len = 0;
	uint8_t *data = read_file(archive_path, &len);
	if (!data) return 1;

	rarz_archive *archive = rarz_open(data, len);
	if (!archive) {
		fprintf(stderr, "error: failed to open archive '%s'\n", archive_path);
		free(data);
		return 1;
	}

	uint32_t count = rarz_file_count(archive);
	int errors = 0;

	for (uint32_t i = 0; i < count; i++) {
		rarz_file_entry entry;
		if (rarz_file_info(archive, i, &entry) != 0) {
			fprintf(stderr, "error: cannot read file info for index %u\n", i);
			errors++;
			continue;
		}

		/* Null-terminate the name */
		char name_buf[4096];
		uint32_t nlen = entry.name_len < sizeof(name_buf) - 1
		                ? entry.name_len : (uint32_t)(sizeof(name_buf) - 1);
		memcpy(name_buf, entry.name, nlen);
		name_buf[nlen] = '\0';

		/* Build full output path */
		char out_path[8192];
		if (dest_dir) {
			snprintf(out_path, sizeof(out_path), "%s/%s", dest_dir, name_buf);
		} else {
			snprintf(out_path, sizeof(out_path), "%s", name_buf);
		}

		/* Handle directories */
		if (entry.is_directory) {
			if (mkdirs(out_path) != 0) {
				fprintf(stderr, "error: cannot create directory '%s': %s\n",
				        out_path, strerror(errno));
				errors++;
			}
			continue;
		}

		/* Ensure parent directory exists */
		if (ensure_parent_dir(out_path) != 0) {
			fprintf(stderr, "error: cannot create parent directory for '%s': %s\n",
			        out_path, strerror(errno));
			errors++;
			continue;
		}

		/* Allocate buffer and extract */
		uint8_t *file_buf = (uint8_t *)malloc((size_t)entry.unpacked_size);
		if (!file_buf && entry.unpacked_size > 0) {
			fprintf(stderr, "error: cannot allocate %llu bytes for '%s'\n",
			        (unsigned long long)entry.unpacked_size, name_buf);
			errors++;
			continue;
		}

		int64_t extracted = rarz_extract_to_buffer(archive, i, file_buf,
		                                           (size_t)entry.unpacked_size);
		if (extracted < 0) {
			fprintf(stderr, "error: extraction failed for '%s' (code %lld)\n",
			        name_buf, (long long)extracted);
			free(file_buf);
			errors++;
			continue;
		}

		/* Write to disk */
		FILE *out = fopen(out_path, "wb");
		if (!out) {
			fprintf(stderr, "error: cannot create '%s': %s\n",
			        out_path, strerror(errno));
			free(file_buf);
			errors++;
			continue;
		}

		size_t written = fwrite(file_buf, 1, (size_t)extracted, out);
		fclose(out);
		free(file_buf);

		if (written != (size_t)extracted) {
			fprintf(stderr, "error: short write for '%s'\n", name_buf);
			errors++;
			continue;
		}

		printf("  %s\n", name_buf);
	}

	printf("\nExtracted %u file%s", count, count == 1 ? "" : "s");
	if (errors > 0) {
		printf(" (%d error%s)", errors, errors == 1 ? "" : "s");
	}
	printf("\n");

	rarz_close(archive);
	free(data);
	return errors > 0 ? 1 : 0;
}

/* ========================================================================== */
/* cmd_add — create RAR5 archive with optional compression                    */
/* ========================================================================== */

static int cmd_add(int argc, char **argv) {
	/* Parse optional -mN flag before archive path */
	uint8_t method = 3; /* default compression level */
	int arg_start = 2;  /* index of archive path in argv */

	if (argc > 2 && argv[2][0] == '-' && argv[2][1] == 'm') {
		char level_ch = argv[2][2];
		if (level_ch >= '0' && level_ch <= '5' && argv[2][3] == '\0') {
			method = (uint8_t)(level_ch - '0');
			arg_start = 3;
		} else {
			fprintf(stderr, "error: invalid compression level '%s' (use -m0 through -m5)\n",
			        argv[2]);
			return 1;
		}
	}

	if (argc <= arg_start) {
		fprintf(stderr, "error: 'add' requires an archive path\n");
		return 1;
	}

	const char *archive_path = argv[arg_start];
	int file_count = argc - arg_start - 1;
	int max_files = 64;

	if (file_count > max_files) {
		fprintf(stderr, "error: too many files (max %d)\n", max_files);
		return 1;
	}

	if (file_count == 0) {
		fprintf(stderr, "error: no files specified\n");
		return 1;
	}

	/* Read all input files */
	rarz_create_file_entry entries[64];
	uint8_t *file_buffers[64];
	memset(file_buffers, 0, sizeof(file_buffers));

	for (int i = 0; i < file_count; i++) {
		const char *path = argv[arg_start + 1 + i];
		struct stat st;

		if (stat(path, &st) != 0) {
			fprintf(stderr, "error: cannot stat '%s': %s\n", path, strerror(errno));
			goto cleanup_add;
		}

		/* Get just the filename (strip directory) */
		const char *name = strrchr(path, '/');
		name = name ? name + 1 : path;

		if (S_ISDIR(st.st_mode)) {
			entries[i].name = name;
			entries[i].name_len = (uint32_t)strlen(name);
			entries[i].data = NULL;
			entries[i].data_len = 0;
			entries[i].mtime = 0;
			entries[i].is_directory = 1;
			file_buffers[i] = NULL;
		} else {
			size_t fsize = 0;
			uint8_t *fdata = read_file(path, &fsize);
			if (!fdata) goto cleanup_add;

			file_buffers[i] = fdata;
			entries[i].name = name;
			entries[i].name_len = (uint32_t)strlen(name);
			entries[i].data = fdata;
			entries[i].data_len = fsize;
			entries[i].mtime = 0;
			entries[i].is_directory = 0;
		}
	}

	/* For store mode, use the simpler path with exact size calculation */
	if (method == 0) {
		int64_t needed = rarz_calculate_archive_size(entries, (uint32_t)file_count);
		if (needed <= 0) {
			fprintf(stderr, "error: cannot calculate archive size\n");
			goto cleanup_add;
		}

		uint8_t *archive_buf = (uint8_t *)malloc((size_t)needed);
		if (!archive_buf) {
			fprintf(stderr, "error: cannot allocate %lld bytes\n", (long long)needed);
			goto cleanup_add;
		}

		int64_t written = rarz_create_archive(entries, (uint32_t)file_count,
		                                       archive_buf, (size_t)needed);
		if (written <= 0) {
			fprintf(stderr, "error: archive creation failed (code %lld)\n",
			        (long long)written);
			free(archive_buf);
			goto cleanup_add;
		}

		FILE *out = fopen(archive_path, "wb");
		if (!out) {
			fprintf(stderr, "error: cannot create '%s': %s\n",
			        archive_path, strerror(errno));
			free(archive_buf);
			goto cleanup_add;
		}

		size_t nwritten = fwrite(archive_buf, 1, (size_t)written, out);
		fclose(out);
		free(archive_buf);

		if (nwritten != (size_t)written) {
			fprintf(stderr, "error: short write to '%s'\n", archive_path);
			goto cleanup_add;
		}

		printf("Created %s (%lld bytes, %d file%s, store)\n",
		       archive_path, (long long)written,
		       file_count, file_count == 1 ? "" : "s");
	} else {
		/* Compressed mode: allocate generous buffer (input size + overhead) */
		uint64_t total_input = 0;
		for (int i = 0; i < file_count; i++) {
			total_input += entries[i].data_len;
		}
		/* Compressed output can be larger than input for incompressible data,
		 * plus we need space for headers. Use 2x input + 64KB per file. */
		size_t buf_size = (size_t)(total_input * 2 + (uint64_t)file_count * 65536 + 4096);

		uint8_t *archive_buf = (uint8_t *)malloc(buf_size);
		if (!archive_buf) {
			fprintf(stderr, "error: cannot allocate %zu bytes\n", buf_size);
			goto cleanup_add;
		}

		int64_t written = rarz_create_archive_compressed(
			entries, (uint32_t)file_count,
			archive_buf, buf_size, method);

		if (written == -3) {
			fprintf(stderr, "error: compression failed\n");
			free(archive_buf);
			goto cleanup_add;
		}
		if (written <= 0) {
			fprintf(stderr, "error: archive creation failed (code %lld)\n",
			        (long long)written);
			free(archive_buf);
			goto cleanup_add;
		}

		FILE *out = fopen(archive_path, "wb");
		if (!out) {
			fprintf(stderr, "error: cannot create '%s': %s\n",
			        archive_path, strerror(errno));
			free(archive_buf);
			goto cleanup_add;
		}

		size_t nwritten = fwrite(archive_buf, 1, (size_t)written, out);
		fclose(out);
		free(archive_buf);

		if (nwritten != (size_t)written) {
			fprintf(stderr, "error: short write to '%s'\n", archive_path);
			goto cleanup_add;
		}

		printf("Created %s (%lld bytes, %d file%s, -m%d)\n",
		       archive_path, (long long)written,
		       file_count, file_count == 1 ? "" : "s", method);
	}

	/* Cleanup file buffers */
	for (int i = 0; i < file_count; i++) {
		free(file_buffers[i]);
	}
	return 0;

cleanup_add:
	for (int i = 0; i < file_count; i++) {
		free(file_buffers[i]);
	}
	return 1;
}

/* ========================================================================== */
/* main                                                                       */
/* ========================================================================== */

int main(int argc, char **argv) {
#ifndef NDEBUG
	fprintf(stderr, "\033[33mDEBUG BUILD\033[0m\n");
#endif

	/* No args or --help: show usage */
	if (argc < 2) {
		print_usage();
		return 0;
	}

	Command cmd = parse_command(argv[1]);

	switch (cmd) {
	case CMD_HELP:
		print_usage();
		return 0;

	case CMD_TEST:
		if (argc < 3) {
			fprintf(stderr, "error: 'test' requires an archive path\n");
			return 1;
		}
		return cmd_test(argv[2]);

	case CMD_LIST:
		if (argc < 3) {
			fprintf(stderr, "error: 'list' requires an archive path\n");
			return 1;
		}
		return cmd_list(argv[2]);

	case CMD_EXTRACT:
		if (argc < 3) {
			fprintf(stderr, "error: 'extract' requires an archive path\n");
			return 1;
		}
		return cmd_extract(argv[2], argc >= 4 ? argv[3] : NULL);

	case CMD_ADD: {
		/* Minimum: rarz add archive file (4 args), or rarz add -mN archive file (5 args) */
		int min_args = 4;
		if (argc > 2 && argv[2][0] == '-' && argv[2][1] == 'm') min_args = 5;
		if (argc < min_args) {
			fprintf(stderr, "error: 'add' requires an archive path and at least one file\n");
			return 1;
		}
		return cmd_add(argc, argv);
	}

	case CMD_UNKNOWN:
	default:
		fprintf(stderr, "unsupported command: %s\n", argv[1]);
		return 1;
	}
}
