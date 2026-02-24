#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <errno.h>
#include <time.h>
#ifndef _WIN32
#include <unistd.h>
#include <libgen.h>
#include <dirent.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#else
#include <io.h>
#define isatty _isatty
#define fileno _fileno
#endif
#include "rarz.h"

#ifdef _WIN32
#define MKDIR(path) mkdir(path)
#else
#define MKDIR(path) mkdir(path, 0755)
#endif

/* ========================================================================== */
/* Progress display                                                           */
/* ========================================================================== */

static int g_is_tty = 0;  /* set once in main() */

static double get_time_sec(void) {
#ifndef _WIN32
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
#else
	return (double)clock() / CLOCKS_PER_SEC;
#endif
}

static int get_term_width(void) {
#ifndef _WIN32
	struct winsize ws;
	if (ioctl(STDERR_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0)
		return ws.ws_col;
#endif
	return 80;
}

/** Format bytes as human-readable string into buf (e.g., "1.2 MB") */
static void format_bytes(char *buf, size_t buflen, uint64_t bytes) {
	if (bytes >= 1073741824ULL)
		snprintf(buf, buflen, "%.1f GB", (double)bytes / 1073741824.0);
	else if (bytes >= 1048576ULL)
		snprintf(buf, buflen, "%.1f MB", (double)bytes / 1048576.0);
	else if (bytes >= 1024ULL)
		snprintf(buf, buflen, "%.1f KB", (double)bytes / 1024.0);
	else
		snprintf(buf, buflen, "%llu B", (unsigned long long)bytes);
}

/** Format seconds as M:SS or H:MM:SS */
static void format_eta(char *buf, size_t buflen, double seconds) {
	if (seconds < 0 || seconds > 86400) {
		snprintf(buf, buflen, "--:--");
		return;
	}
	int s = (int)(seconds + 0.5);
	if (s >= 3600)
		snprintf(buf, buflen, "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60);
	else
		snprintf(buf, buflen, "%d:%02d", s / 60, s % 60);
}

/** Format throughput as "XX.X MB/s" */
static void format_throughput(char *buf, size_t buflen, uint64_t bytes, double elapsed) {
	if (elapsed <= 0.001) {
		snprintf(buf, buflen, "-- MB/s");
		return;
	}
	double mbps = ((double)bytes / 1048576.0) / elapsed;
	if (mbps >= 1000.0)
		snprintf(buf, buflen, "%.1f GB/s", mbps / 1024.0);
	else
		snprintf(buf, buflen, "%.1f MB/s", mbps);
}

/**
 * Show a progress line on stderr (TTY only). Overwrites previous line with \r.
 * pass -1 for pct to show indeterminate progress.
 */
static void progress_show(const char *verb, const char *filename,
                           int file_idx, int file_total,
                           int pct, const char *rate, const char *eta) {
	if (!g_is_tty) return;

	int width = get_term_width();
	char line[512];
	int pos = 0;

	if (pct >= 0) {
		/* Draw a mini progress bar */
		int bar_width = 20;
		int filled = (pct * bar_width) / 100;
		char bar[32];
		for (int i = 0; i < bar_width; i++)
			bar[i] = (i < filled) ? '#' : '-';
		bar[bar_width] = '\0';

		pos = snprintf(line, sizeof(line), "\r  %s: %s (%d/%d) [%s] %3d%%",
		               verb, filename, file_idx, file_total, bar, pct);
	} else {
		pos = snprintf(line, sizeof(line), "\r  %s: %s (%d/%d)",
		               verb, filename, file_idx, file_total);
	}

	if (rate && rate[0]) {
		pos += snprintf(line + pos, sizeof(line) - (size_t)pos, " | %s", rate);
	}
	if (eta && eta[0]) {
		pos += snprintf(line + pos, sizeof(line) - (size_t)pos, " | ETA %s", eta);
	}

	/* Pad with spaces to clear previous longer line */
	while (pos < width - 1 && pos < (int)sizeof(line) - 1)
		line[pos++] = ' ';
	line[pos] = '\0';

	fprintf(stderr, "%s", line);
	fflush(stderr);
}

/** Clear the progress line */
static void progress_clear(void) {
	if (!g_is_tty) return;
	int width = get_term_width();
	fprintf(stderr, "\r%*s\r", width - 1, "");
	fflush(stderr);
}

/* ========================================================================== */
/* Command enum + parser                                                      */
/* ========================================================================== */

typedef enum {
	CMD_UNKNOWN = -1,
	CMD_HELP,
	CMD_TEST,
	CMD_LIST,
	CMD_VOLUMES,
	CMD_EXTRACT,
	CMD_ADD,
} Command;

static Command parse_command(const char *arg) {
	if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) return CMD_HELP;
	if (strcmp(arg, "t") == 0 || strcmp(arg, "test") == 0) return CMD_TEST;
	if (strcmp(arg, "l") == 0 || strcmp(arg, "list") == 0 ||
	    strcmp(arg, "v") == 0 || strcmp(arg, "list-verbose") == 0) return CMD_LIST;
	if (strcmp(arg, "vol") == 0 || strcmp(arg, "volumes") == 0) return CMD_VOLUMES;
	if (strcmp(arg, "x") == 0 || strcmp(arg, "extract") == 0) return CMD_EXTRACT;
	if (strcmp(arg, "a") == 0 || strcmp(arg, "add") == 0) return CMD_ADD;
	return CMD_UNKNOWN;
}

/* ========================================================================== */
/* Usage / help                                                               */
/* ========================================================================== */

static void print_usage(void) {
	printf("rarz - clean-room reimplementation RAR archive toolkit and CLI (Peter Marreck, 2026-02-21)\n");
	printf("RAR format and original/primary implementation by Alexander Roshal\n\n");
	printf("Usage:\n");
	printf("  rarz t|test <archive>            Test archive integrity\n");
	printf("  rarz l|list|v|list-verbose <archive>\n");
	printf("                                   List archive contents\n");
	printf("  rarz vol|volumes <archive>       Show detected archive volume set\n");
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
/* DOS timestamp conversion                                                   */
/* ========================================================================== */

/**
 * Convert Unix time_t to DOS timestamp format.
 * DOS format: bits 25-31=year-1980, 21-24=month, 16-20=day, 11-15=hour, 5-10=min, 0-4=sec/2
 */
static uint32_t unix_to_dos_time(time_t t) {
	struct tm *tm = localtime(&t);
	if (!tm) return 0;
	uint32_t dos = 0;
	dos |= (uint32_t)((tm->tm_year + 1900 - 1980) & 0x7F) << 25;
	dos |= (uint32_t)((tm->tm_mon + 1) & 0x0F) << 21;
	dos |= (uint32_t)(tm->tm_mday & 0x1F) << 16;
	dos |= (uint32_t)(tm->tm_hour & 0x1F) << 11;
	dos |= (uint32_t)(tm->tm_min & 0x3F) << 5;
	dos |= (uint32_t)((tm->tm_sec / 2) & 0x1F);
	return dos;
}

/* ========================================================================== */
/* Dynamic entry list for archive creation                                    */
/* ========================================================================== */

typedef struct {
	rarz_create_file_entry *entries;
	uint8_t **buffers;  /* file data buffers (caller must free) */
	char **names;       /* allocated name strings (caller must free) */
	int count;
	int capacity;
} entry_list;

static int entry_list_init(entry_list *list, int initial_cap) {
	list->entries = (rarz_create_file_entry *)calloc((size_t)initial_cap, sizeof(rarz_create_file_entry));
	list->buffers = (uint8_t **)calloc((size_t)initial_cap, sizeof(uint8_t *));
	list->names = (char **)calloc((size_t)initial_cap, sizeof(char *));
	if (!list->entries || !list->buffers || !list->names) {
		free(list->entries); free(list->buffers); free(list->names);
		memset(list, 0, sizeof(*list));
		return -1;
	}
	list->count = 0;
	list->capacity = initial_cap;
	return 0;
}

static int entry_list_grow(entry_list *list) {
	int new_cap = list->capacity * 2;
	rarz_create_file_entry *ne = (rarz_create_file_entry *)realloc(list->entries,
	                              (size_t)new_cap * sizeof(rarz_create_file_entry));
	uint8_t **nb = (uint8_t **)realloc(list->buffers, (size_t)new_cap * sizeof(uint8_t *));
	char **nn = (char **)realloc(list->names, (size_t)new_cap * sizeof(char *));
	if (!ne || !nb || !nn) {
		/* If only some reallocs succeeded, they're still valid at old size */
		if (ne) list->entries = ne;
		if (nb) list->buffers = nb;
		if (nn) list->names = nn;
		return -1;
	}
	list->entries = ne;
	list->buffers = nb;
	list->names = nn;
	/* Zero out new slots */
	memset(list->buffers + list->capacity, 0, (size_t)(new_cap - list->capacity) * sizeof(uint8_t *));
	memset(list->names + list->capacity, 0, (size_t)(new_cap - list->capacity) * sizeof(char *));
	list->capacity = new_cap;
	return 0;
}

static void entry_list_free(entry_list *list) {
	for (int i = 0; i < list->count; i++) {
		free(list->buffers[i]);
		free(list->names[i]);
	}
	free(list->entries);
	free(list->buffers);
	free(list->names);
	memset(list, 0, sizeof(*list));
}

/**
 * Add a file entry to the list.
 * Takes ownership of fdata (will be freed by entry_list_free).
 * archive_name is copied (strdup'd).
 */
static int entry_list_add_file(entry_list *list, const char *archive_name,
                                uint8_t *fdata, size_t fsize, struct stat *st) {
	if (list->count >= list->capacity) {
		if (entry_list_grow(list) != 0) return -1;
	}

	char *name_copy = strdup(archive_name);
	if (!name_copy) return -1;

	int idx = list->count;
	list->names[idx] = name_copy;
	list->buffers[idx] = fdata;
	list->entries[idx].name = name_copy;
	list->entries[idx].name_len = (uint32_t)strlen(name_copy);
	list->entries[idx].data = fdata;
	list->entries[idx].data_len = fsize;
	list->entries[idx].mtime = unix_to_dos_time(st->st_mtime);
	list->entries[idx].is_directory = 0;
#ifndef _WIN32
	list->entries[idx].host_os = 3; /* Unix */
	list->entries[idx].attributes = (uint32_t)st->st_mode;
#else
	list->entries[idx].host_os = 0; /* Windows */
	list->entries[idx].attributes = 0x20; /* FILE_ATTRIBUTE_ARCHIVE */
#endif
	list->count++;
	return 0;
}

/**
 * Add a directory entry to the list.
 * archive_name should include trailing '/'.
 */
static int entry_list_add_dir(entry_list *list, const char *archive_name, struct stat *st) {
	if (list->count >= list->capacity) {
		if (entry_list_grow(list) != 0) return -1;
	}

	char *name_copy = strdup(archive_name);
	if (!name_copy) return -1;

	int idx = list->count;
	list->names[idx] = name_copy;
	list->buffers[idx] = NULL;
	list->entries[idx].name = name_copy;
	list->entries[idx].name_len = (uint32_t)strlen(name_copy);
	list->entries[idx].data = NULL;
	list->entries[idx].data_len = 0;
	list->entries[idx].mtime = unix_to_dos_time(st->st_mtime);
	list->entries[idx].is_directory = 1;
#ifndef _WIN32
	list->entries[idx].host_os = 3; /* Unix */
	list->entries[idx].attributes = (uint32_t)st->st_mode;
#else
	list->entries[idx].host_os = 0; /* Windows */
	list->entries[idx].attributes = 0x10; /* FILE_ATTRIBUTE_DIRECTORY */
#endif
	list->count++;
	return 0;
}

/* ========================================================================== */
/* Recursive directory walking                                                */
/* ========================================================================== */

#ifndef _WIN32
/**
 * Recursively walk a directory, adding all files and subdirectories to the list.
 * fs_path: filesystem path to the directory (no trailing slash)
 * archive_prefix: path prefix in the archive (e.g., "mydir/sub/")
 * Returns 0 on success, -1 on error.
 */
static int walk_directory(entry_list *list, const char *fs_path, const char *archive_prefix) {
	DIR *dir = opendir(fs_path);
	if (!dir) {
		fprintf(stderr, "warning: cannot open directory '%s': %s\n", fs_path, strerror(errno));
		return -1;
	}

	struct dirent *ent;
	while ((ent = readdir(dir)) != NULL) {
		/* Skip . and .. */
		if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
			continue;

		/* Build full filesystem path */
		char child_path[4096];
		snprintf(child_path, sizeof(child_path), "%s/%s", fs_path, ent->d_name);

		/* Build archive path */
		char child_archive[4096];
		snprintf(child_archive, sizeof(child_archive), "%s%s", archive_prefix, ent->d_name);

		struct stat st;
		if (lstat(child_path, &st) != 0) {
			fprintf(stderr, "warning: cannot stat '%s': %s\n", child_path, strerror(errno));
			continue;
		}

		if (S_ISLNK(st.st_mode)) {
			fprintf(stderr, "warning: skipping symlink '%s'\n", child_path);
			continue;
		}

		if (S_ISDIR(st.st_mode)) {
			/* Add directory entry with trailing slash */
			char dir_archive[4096];
			snprintf(dir_archive, sizeof(dir_archive), "%s/", child_archive);
			entry_list_add_dir(list, dir_archive, &st);
			/* Recurse into subdirectory */
			walk_directory(list, child_path, dir_archive);
		} else if (S_ISREG(st.st_mode)) {
			/* Read file and add to list */
			size_t fsize = 0;
			uint8_t *fdata = read_file(child_path, &fsize);
			if (!fdata) continue;
			if (entry_list_add_file(list, child_archive, fdata, fsize, &st) != 0) {
				free(fdata);
				fprintf(stderr, "warning: cannot add '%s': out of memory\n", child_path);
			}
		}
		/* Skip other file types (devices, sockets, etc.) */
	}

	closedir(dir);
	return 0;
}
#endif

/* ========================================================================== */
/* Volume discovery                                                           */
/* ========================================================================== */

#define MAX_VOLUMES 1024

typedef struct {
	char **paths;
	int count;
} volume_set;

/**
 * Find the base name and detect the naming pattern for multi-volume archives.
 * Supports two patterns:
 *   RAR5 new style: archive.partNN.rar, archive.partNNN.rar, etc.
 *   RAR4 old style: archive.rar, archive.r00, archive.r01, ...
 *
 * Returns a volume_set with paths array (caller must free each path + the array).
 * If not a multi-volume archive, returns count=1 with the original path.
 */
static volume_set discover_volumes(const char *path) {
	volume_set result = { NULL, 0 };

	/* Check for RAR5 new-style naming: .partN.rar or .partNN.rar or .partNNN.rar */
	const char *dot_rar = strstr(path, ".rar");
	if (dot_rar && dot_rar[4] == '\0') {
		/* Look backwards from .rar for .partNNN */
		const char *scan = dot_rar;
		while (scan > path && scan[-1] >= '0' && scan[-1] <= '9') scan--;
		if (scan > path + 5 && strncmp(scan - 5, ".part", 5) == 0) {
			/* Found .partNNN.rar pattern */
			int num_digits = (int)(dot_rar - scan);
			if (num_digits >= 1 && num_digits <= 4) {
				/* Extract the base: everything before .partNNN.rar */
				size_t base_len = (size_t)(scan - 5 - path);
				char base[4096];
				if (base_len >= sizeof(base)) goto single;
				memcpy(base, path, base_len);
				base[base_len] = '\0';

				/* Scan for all volumes */
				result.paths = (char **)calloc(MAX_VOLUMES, sizeof(char *));
				if (!result.paths) goto single;

				for (int i = 1; i <= MAX_VOLUMES; i++) {
					char vol_path[4096];
					snprintf(vol_path, sizeof(vol_path), "%s.part%0*d.rar",
					         base, num_digits, i);

					struct stat st;
					if (stat(vol_path, &st) != 0) break;

					result.paths[result.count] = strdup(vol_path);
					if (!result.paths[result.count]) break;
					result.count++;
				}

				if (result.count > 1) return result;

				/* Only found 1 or none — clean up and fall through */
				for (int i = 0; i < result.count; i++) free(result.paths[i]);
				free(result.paths);
				result.paths = NULL;
				result.count = 0;
			}
		}
	}

	/* Check for RAR4 old-style: .rar + .r00, .r01, ... */
	{
		size_t plen = strlen(path);
		if (plen > 4 && strcmp(path + plen - 4, ".rar") == 0) {
			char base[4096];
			size_t base_len = plen - 4;
			if (base_len < sizeof(base)) {
				memcpy(base, path, base_len);
				base[base_len] = '\0';

				char r00_path[4096];
				snprintf(r00_path, sizeof(r00_path), "%s.r00", base);

				struct stat st;
				if (stat(r00_path, &st) == 0) {
					/* RAR4 multi-volume detected */
					result.paths = (char **)calloc(MAX_VOLUMES, sizeof(char *));
					if (!result.paths) goto single;

					/* First volume is the .rar file itself */
					result.paths[0] = strdup(path);
					if (!result.paths[0]) { free(result.paths); goto single; }
					result.count = 1;

					for (int i = 0; i < MAX_VOLUMES - 1; i++) {
						char vol_path[4096];
						snprintf(vol_path, sizeof(vol_path), "%s.r%02d", base, i);
						if (stat(vol_path, &st) != 0) break;
						result.paths[result.count] = strdup(vol_path);
						if (!result.paths[result.count]) break;
						result.count++;
					}

					if (result.count > 1) return result;

					for (int i = 0; i < result.count; i++) free(result.paths[i]);
					free(result.paths);
					result.paths = NULL;
					result.count = 0;
				}
			}
		}
	}

single:
	/* Single volume — just return the original path */
	result.paths = (char **)malloc(sizeof(char *));
	if (!result.paths) { result.count = 0; return result; }
	result.paths[0] = strdup(path);
	if (!result.paths[0]) { free(result.paths); result.paths = NULL; result.count = 0; return result; }
	result.count = 1;
	return result;
}

static void free_volume_set(volume_set *vs) {
	if (vs->paths) {
		for (int i = 0; i < vs->count; i++) free(vs->paths[i]);
		free(vs->paths);
		vs->paths = NULL;
		vs->count = 0;
	}
}

/**
 * Open an archive, automatically detecting and loading multiple volumes.
 * Returns the archive handle and sets *volume_bufs, *volume_lens, *vol_count
 * for the caller to free later. Caller must free each buffer in volume_bufs.
 */
static rarz_archive *open_with_volumes(const char *path,
                                        uint8_t ***volume_bufs_out,
                                        size_t **volume_lens_out,
                                        int *vol_count_out) {
	*volume_bufs_out = NULL;
	*volume_lens_out = NULL;
	*vol_count_out = 0;

	volume_set vs = discover_volumes(path);
	if (vs.count == 0) {
		free_volume_set(&vs);
		return NULL;
	}

	if (vs.count == 1) {
		/* Single volume — use existing rarz_open */
		size_t len = 0;
		uint8_t *data = read_file(vs.paths[0], &len);
		free_volume_set(&vs);
		if (!data) return NULL;

		rarz_archive *archive = rarz_open(data, len);
		if (!archive) {
			free(data);
			return NULL;
		}

		/* Store the buffer for cleanup */
		*volume_bufs_out = (uint8_t **)malloc(sizeof(uint8_t *));
		*volume_lens_out = (size_t *)malloc(sizeof(size_t));
		if (!*volume_bufs_out || !*volume_lens_out) {
			rarz_close(archive);
			free(data);
			free(*volume_bufs_out);
			free(*volume_lens_out);
			*volume_bufs_out = NULL;
			*volume_lens_out = NULL;
			return NULL;
		}
		(*volume_bufs_out)[0] = data;
		(*volume_lens_out)[0] = len;
		*vol_count_out = 1;
		return archive;
	}

	/* Multi-volume: read all volumes into memory */
	uint8_t **bufs = (uint8_t **)calloc((size_t)vs.count, sizeof(uint8_t *));
	size_t *lens = (size_t *)calloc((size_t)vs.count, sizeof(size_t));
	if (!bufs || !lens) {
		free(bufs);
		free(lens);
		free_volume_set(&vs);
		return NULL;
	}

	for (int i = 0; i < vs.count; i++) {
		bufs[i] = read_file(vs.paths[i], &lens[i]);
		if (!bufs[i]) {
			for (int j = 0; j < i; j++) free(bufs[j]);
			free(bufs);
			free(lens);
			free_volume_set(&vs);
			return NULL;
		}
	}

	int num_vols = vs.count;
	printf("Opening %d volumes...\n", num_vols);

	/* Build const pointer array for rarz_open_volumes */
	const uint8_t **const_bufs = (const uint8_t **)bufs;
	rarz_archive *archive = rarz_open_volumes(const_bufs, lens, (uint32_t)num_vols);
	free_volume_set(&vs);

	if (!archive) {
		for (int i = 0; i < num_vols; i++) free(bufs[i]);
		free(bufs);
		free(lens);
		return NULL;
	}

	*volume_bufs_out = bufs;
	*volume_lens_out = lens;
	*vol_count_out = num_vols;
	return archive;
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
	volume_set vs = discover_volumes(path);
	if (vs.count == 0) {
		fprintf(stderr, "error: cannot discover volumes for '%s'\n", path);
		return 1;
	}

	int all_valid = 1;
	for (int i = 0; i < vs.count; i++) {
		size_t len = 0;
		uint8_t *data = read_file(vs.paths[i], &len);
		if (!data) { all_valid = 0; continue; }

		if (i == 0) {
			printf("Testing archive: %s", path);
			if (vs.count > 1) printf(" (%d volumes)", vs.count);
			printf("\n");
		}

		rarz_validation_result result = rarz_validate(data, len);

		if (!result.is_valid) {
			printf("Volume %d (%s): INVALID\n", i + 1, vs.paths[i]);
			if (result.error_msg)
				printf("  Error: %s\n", result.error_msg);
			all_valid = 0;
		}

		if (i == 0) {
			printf("Format: %s\n", format_name(result.family));
			if (result.has_encrypted) {
				printf("Encrypted: yes\n");
				printf("Note: encrypted content not verified (use --password for full check)\n");
			}
		}

		free(data);
	}

	printf("Validation: %s\n", all_valid ? "VALID" : "INVALID");
	free_volume_set(&vs);
	return all_valid ? 0 : 1;
}

/* ========================================================================== */
/* cmd_volumes                                                                */
/* ========================================================================== */

static int cmd_volumes(const char *path) {
	volume_set vs = discover_volumes(path);
	if (vs.count == 0) {
		fprintf(stderr, "error: cannot discover volumes for '%s'\n", path);
		return 1;
	}

	printf("Archive: %s\n", path);
	printf("Volumes: %d\n", vs.count);
	for (int i = 0; i < vs.count; i++) {
		printf("  %2d: %s\n", i + 1, vs.paths[i]);
	}

	free_volume_set(&vs);
	return 0;
}

/* ========================================================================== */
/* cmd_list                                                                   */
/* ========================================================================== */

static int cmd_list(const char *path) {
	uint8_t **vol_bufs = NULL;
	size_t *vol_lens = NULL;
	int vol_count = 0;

	rarz_archive *archive = open_with_volumes(path, &vol_bufs, &vol_lens, &vol_count);
	if (!archive) {
		const char *err = rarz_last_error();
		fprintf(stderr, "error: failed to open archive '%s'%s%s\n", path,
		        err ? ": " : "", err ? err : "");
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
	for (int i = 0; i < vol_count; i++) free(vol_bufs[i]);
	free(vol_bufs);
	free(vol_lens);
	return 0;
}

/* ========================================================================== */
/* cmd_extract                                                                */
/* ========================================================================== */

static int cmd_extract(const char *archive_path, const char *dest_dir) {
	uint8_t **vol_bufs = NULL;
	size_t *vol_lens = NULL;
	int vol_count = 0;

	rarz_archive *archive = open_with_volumes(archive_path, &vol_bufs, &vol_lens, &vol_count);
	if (!archive) {
		const char *err = rarz_last_error();
		fprintf(stderr, "error: failed to open archive '%s'%s%s\n", archive_path,
		        err ? ": " : "", err ? err : "");
		return 1;
	}

	uint32_t count = rarz_file_count(archive);
	int errors = 0;

	/* Pre-compute total unpacked size for progress tracking */
	uint64_t total_size = 0;
	uint32_t file_count = 0; /* non-directory count */
	for (uint32_t i = 0; i < count; i++) {
		rarz_file_entry pe;
		if (rarz_file_info(archive, i, &pe) == 0 && !pe.is_directory) {
			total_size += pe.unpacked_size;
			file_count++;
		}
	}

	uint64_t bytes_done = 0;
	uint32_t files_done = 0;
	double start_time = get_time_sec();

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

		/* Show progress (TTY) or filename (non-TTY) */
		files_done++;
		if (g_is_tty) {
			double elapsed = get_time_sec() - start_time;
			int pct = total_size > 0 ? (int)((bytes_done * 100) / total_size) : 0;
			char rate_buf[32], eta_buf[16];
			format_throughput(rate_buf, sizeof(rate_buf), bytes_done, elapsed);
			double eta = (pct > 0 && elapsed > 0.1)
				? elapsed * (100.0 - pct) / pct : -1;
			format_eta(eta_buf, sizeof(eta_buf), eta);
			progress_show("Extracting", name_buf, (int)files_done, (int)file_count,
			              pct, rate_buf, pct > 0 ? eta_buf : NULL);
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
			progress_clear();
			const char *exerr = rarz_last_error();
			fprintf(stderr, "error: extraction failed for '%s' (code %lld)%s%s\n",
			        name_buf, (long long)extracted,
			        exerr ? ": " : "", exerr ? exerr : "");
			free(file_buf);
			errors++;
			continue;
		}

		/* Write to disk */
		FILE *out = fopen(out_path, "wb");
		if (!out) {
			progress_clear();
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
			progress_clear();
			fprintf(stderr, "error: short write for '%s'\n", name_buf);
			errors++;
			continue;
		}

		bytes_done += (uint64_t)extracted;

		if (!g_is_tty) {
			printf("  %s\n", name_buf);
		}
	}

	progress_clear();

	/* Final summary */
	double total_elapsed = get_time_sec() - start_time;
	char size_buf[32], rate_buf[32];
	format_bytes(size_buf, sizeof(size_buf), total_size);
	format_throughput(rate_buf, sizeof(rate_buf), total_size, total_elapsed);

	printf("Extracted %u file%s", file_count, file_count == 1 ? "" : "s");
	printf(" (%s in %.2fs, %s)", size_buf, total_elapsed, rate_buf);
	if (errors > 0) {
		printf(" (%d error%s)", errors, errors == 1 ? "" : "s");
	}
	printf("\n");

	rarz_close(archive);
	for (int i = 0; i < vol_count; i++) free(vol_bufs[i]);
	free(vol_bufs);
	free(vol_lens);
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
	int input_count = argc - arg_start - 1;

	if (input_count == 0) {
		fprintf(stderr, "error: no files specified\n");
		return 1;
	}

	/* Build entry list from arguments (may expand via directory recursion) */
	entry_list list;
	if (entry_list_init(&list, 128) != 0) {
		fprintf(stderr, "error: out of memory\n");
		return 1;
	}

	for (int i = 0; i < input_count; i++) {
		const char *path = argv[arg_start + 1 + i];
		struct stat st;

		if (g_is_tty) {
			/* Show which file we're reading */
			const char *bname = strrchr(path, '/');
			bname = bname ? bname + 1 : path;
			progress_show("Reading", bname, i + 1, input_count, -1, NULL, NULL);
		}

		if (lstat(path, &st) != 0) {
			progress_clear();
			fprintf(stderr, "error: cannot stat '%s': %s\n", path, strerror(errno));
			entry_list_free(&list);
			return 1;
		}

#ifndef _WIN32
		if (S_ISLNK(st.st_mode)) {
			progress_clear();
			fprintf(stderr, "warning: skipping symlink '%s'\n", path);
			continue;
		}
#endif

		if (S_ISDIR(st.st_mode)) {
#ifndef _WIN32
			/* Strip trailing slash if present */
			char clean_path[4096];
			size_t plen = strlen(path);
			if (plen > 0 && plen < sizeof(clean_path)) {
				memcpy(clean_path, path, plen + 1);
				while (plen > 1 && clean_path[plen - 1] == '/')
					clean_path[--plen] = '\0';
			} else {
				snprintf(clean_path, sizeof(clean_path), "%s", path);
			}

			/* Get the basename of the directory */
			const char *dir_base = strrchr(clean_path, '/');
			dir_base = dir_base ? dir_base + 1 : clean_path;

			/* Add the directory entry itself */
			char dir_archive[4096];
			snprintf(dir_archive, sizeof(dir_archive), "%s/", dir_base);
			entry_list_add_dir(&list, dir_archive, &st);

			/* Recursively walk */
			walk_directory(&list, clean_path, dir_archive);
#else
			fprintf(stderr, "error: directory archiving not supported on Windows yet\n");
			entry_list_free(&list);
			return 1;
#endif
		} else if (S_ISREG(st.st_mode)) {
			/* Individual file: use basename only */
			const char *name = strrchr(path, '/');
			name = name ? name + 1 : path;

			size_t fsize = 0;
			uint8_t *fdata = read_file(path, &fsize);
			if (!fdata) {
				entry_list_free(&list);
				return 1;
			}
			if (entry_list_add_file(&list, name, fdata, fsize, &st) != 0) {
				free(fdata);
				fprintf(stderr, "error: out of memory\n");
				entry_list_free(&list);
				return 1;
			}
		} else {
			fprintf(stderr, "warning: skipping '%s' (not a regular file or directory)\n", path);
		}
	}

	if (list.count == 0) {
		fprintf(stderr, "error: no files to archive\n");
		entry_list_free(&list);
		return 1;
	}

	/* Compute total input size for progress/summary */
	uint64_t total_input = 0;
	int file_entries = 0;
	for (int i = 0; i < list.count; i++) {
		total_input += list.entries[i].data_len;
		if (!list.entries[i].is_directory) file_entries++;
	}

	int result = 0;
	double compress_start = get_time_sec();

	/* Show compression start (TTY only) */
	if (g_is_tty) {
		char size_buf[32], method_buf[8];
		format_bytes(size_buf, sizeof(size_buf), total_input);
		if (method == 0)
			snprintf(method_buf, sizeof(method_buf), "store");
		else
			snprintf(method_buf, sizeof(method_buf), "m%d", method);
		fprintf(stderr, "\r  Compressing %d file%s (%s) with %s...    ",
		        file_entries, file_entries == 1 ? "" : "s",
		        size_buf, method_buf);
		fflush(stderr);
	}

	/* For store mode, use the simpler path with exact size calculation */
	if (method == 0) {
		int64_t needed = rarz_calculate_archive_size(list.entries, (uint32_t)list.count);
		if (needed <= 0) {
			progress_clear();
			const char *cerr = rarz_last_error();
			fprintf(stderr, "error: cannot calculate archive size%s%s\n",
			        cerr ? ": " : "", cerr ? cerr : "");
			entry_list_free(&list);
			return 1;
		}

		uint8_t *archive_buf = (uint8_t *)malloc((size_t)needed);
		if (!archive_buf) {
			progress_clear();
			fprintf(stderr, "error: cannot allocate %lld bytes\n", (long long)needed);
			entry_list_free(&list);
			return 1;
		}

		int64_t written = rarz_create_archive(list.entries, (uint32_t)list.count,
		                                       archive_buf, (size_t)needed);
		if (written <= 0) {
			progress_clear();
			const char *aerr = rarz_last_error();
			fprintf(stderr, "error: archive creation failed (code %lld)%s%s\n",
			        (long long)written,
			        aerr ? ": " : "", aerr ? aerr : "");
			free(archive_buf);
			entry_list_free(&list);
			return 1;
		}

		FILE *out = fopen(archive_path, "wb");
		if (!out) {
			progress_clear();
			fprintf(stderr, "error: cannot create '%s': %s\n",
			        archive_path, strerror(errno));
			free(archive_buf);
			entry_list_free(&list);
			return 1;
		}

		size_t nwritten = fwrite(archive_buf, 1, (size_t)written, out);
		fclose(out);
		free(archive_buf);

		if (nwritten != (size_t)written) {
			progress_clear();
			fprintf(stderr, "error: short write to '%s'\n", archive_path);
			entry_list_free(&list);
			return 1;
		}

		progress_clear();
		double elapsed = get_time_sec() - compress_start;
		char in_buf[32], out_buf2[32], rate_buf[32];
		format_bytes(in_buf, sizeof(in_buf), total_input);
		format_bytes(out_buf2, sizeof(out_buf2), (uint64_t)written);
		format_throughput(rate_buf, sizeof(rate_buf), total_input, elapsed);
		printf("Created %s (%s -> %s, %d file%s, store, %.2fs, %s)\n",
		       archive_path, in_buf, out_buf2,
		       file_entries, file_entries == 1 ? "" : "s",
		       elapsed, rate_buf);
	} else {
		/* Compressed mode: allocate generous buffer (input size + overhead) */
		/* Compressed output can be larger than input for incompressible data,
		 * plus we need space for headers. Use 2x input + 64KB per file. */
		size_t buf_size = (size_t)(total_input * 2 + (uint64_t)list.count * 65536 + 4096);

		uint8_t *archive_buf = (uint8_t *)malloc(buf_size);
		if (!archive_buf) {
			progress_clear();
			fprintf(stderr, "error: cannot allocate %zu bytes\n", buf_size);
			entry_list_free(&list);
			return 1;
		}

		int64_t written = rarz_create_archive_compressed(
			list.entries, (uint32_t)list.count,
			archive_buf, buf_size, method);

		if (written <= 0) {
			progress_clear();
			const char *cerr2 = rarz_last_error();
			fprintf(stderr, "error: archive creation failed (code %lld)%s%s\n",
			        (long long)written,
			        cerr2 ? ": " : "", cerr2 ? cerr2 : "");
			free(archive_buf);
			entry_list_free(&list);
			return 1;
		}

		FILE *out = fopen(archive_path, "wb");
		if (!out) {
			progress_clear();
			fprintf(stderr, "error: cannot create '%s': %s\n",
			        archive_path, strerror(errno));
			free(archive_buf);
			entry_list_free(&list);
			return 1;
		}

		size_t nwritten = fwrite(archive_buf, 1, (size_t)written, out);
		fclose(out);
		free(archive_buf);

		if (nwritten != (size_t)written) {
			progress_clear();
			fprintf(stderr, "error: short write to '%s'\n", archive_path);
			entry_list_free(&list);
			return 1;
		}

		progress_clear();
		double elapsed = get_time_sec() - compress_start;
		char in_buf[32], out_buf2[32], rate_buf[32];
		format_bytes(in_buf, sizeof(in_buf), total_input);
		format_bytes(out_buf2, sizeof(out_buf2), (uint64_t)written);
		format_throughput(rate_buf, sizeof(rate_buf), total_input, elapsed);
		int ratio = total_input > 0 ? (int)(((uint64_t)written * 100) / total_input) : 100;
		printf("Created %s (%s -> %s, %d%%, %d file%s, -m%d, %.2fs, %s)\n",
		       archive_path, in_buf, out_buf2, ratio,
		       file_entries, file_entries == 1 ? "" : "s",
		       method, elapsed, rate_buf);
	}

	entry_list_free(&list);
	return result;
}

/* ========================================================================== */
/* main                                                                       */
/* ========================================================================== */

int main(int argc, char **argv) {
	g_is_tty = isatty(fileno(stderr));

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

	case CMD_VOLUMES:
		if (argc < 3) {
			fprintf(stderr, "error: 'volumes' requires an archive path\n");
			return 1;
		}
		return cmd_volumes(argv[2]);

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
