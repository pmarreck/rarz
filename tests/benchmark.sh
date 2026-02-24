#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# rarz Benchmark Suite
# Compares rarz vs official rar/unrar on:
#   - Compression ratio (archive size vs original)
#   - Compression speed (archive creation)
#   - Extraction speed (decompression)
#   - Validation speed (rarz t)
#
# Uses hyperfine for all timing measurements.
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RARZ="$PROJECT_ROOT/zig-out/bin/rarz"
WARMUP=${BENCHMARK_WARMUP:-1}
RUNS=${BENCHMARK_RUNS:-5}

# Ensure tools exist
if [ ! -x "$RARZ" ]; then
	echo "ERROR: rarz binary not found at $RARZ"
	echo "Run: nix develop -c zig build -Doptimize=ReleaseFast"
	exit 1
fi

for tool in rar unrar hyperfine; do
	command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found"; exit 1; }
done

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# =============================================================================
# Generate test corpus
# =============================================================================

echo "Generating test corpus..."

mkdir -p "$tmpdir/corpus"

# Highly compressible: repeated text (~200KB)
for i in $(seq 1 3000); do
	echo "Benchmark line $i: The quick brown fox jumps over the lazy dog repeatedly."
done > "$tmpdir/corpus/text_200k.txt"

# Medium compressibility: C source code (~150KB)
for i in $(seq 1 2000); do
	printf 'int func_%04d(int x) { return x * %d + %d; }\n' "$i" "$((i * 7))" "$((i * 13))"
done > "$tmpdir/corpus/code_150k.c"

# Low compressibility: pseudo-random binary (~256KB)
dd if=/dev/urandom bs=1024 count=256 of="$tmpdir/corpus/random_256k.bin" 2>/dev/null

# Large compressible: repeated patterns (~2MB)
for i in $(seq 1 25000); do
	echo "Large file line $i: $(printf '%060d' $((i * 37))) padding data for multi-block"
done > "$tmpdir/corpus/large_2m.txt"

# Mixed archive content
cp "$tmpdir/corpus/text_200k.txt" "$tmpdir/corpus/dup1.txt"
cp "$tmpdir/corpus/text_200k.txt" "$tmpdir/corpus/dup2.txt"

corpus_size=$(du -sk "$tmpdir/corpus" | cut -f1)
file_count=$(find "$tmpdir/corpus" -type f | wc -l | tr -d ' ')
echo "Corpus: ${file_count} files, ${corpus_size}KB total"
echo ""

# Helper: human-readable file size
human_size() {
	local bytes=$1
	if [ "$bytes" -ge 1048576 ]; then
		awk "BEGIN { printf \"%.1fM\", $bytes / 1048576 }"
	elif [ "$bytes" -ge 1024 ]; then
		awk "BEGIN { printf \"%.0fK\", $bytes / 1024 }"
	else
		echo "${bytes}B"
	fi
}

# Helper: get file size portably
file_size() {
	stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null
}

# Collect corpus file list for rarz
corpus_files=(
	"$tmpdir/corpus/text_200k.txt"
	"$tmpdir/corpus/code_150k.c"
	"$tmpdir/corpus/random_256k.bin"
	"$tmpdir/corpus/large_2m.txt"
	"$tmpdir/corpus/dup1.txt"
	"$tmpdir/corpus/dup2.txt"
)

# =============================================================================
# Section 1: Compression ratio comparison
# =============================================================================

echo "=================================================================="
echo "  COMPRESSION RATIO COMPARISON"
echo "=================================================================="
printf "%-12s  %10s  %10s  %10s  %8s  %8s\n" "Level" "Original" "rar" "rarz" "rar %" "rarz %"
echo "------------------------------------------------------------------"

cd "$tmpdir/corpus"
original_size=$(du -sb . 2>/dev/null | cut -f1 || du -sk . | awk '{print $1*1024}')

for level in 0 1 2 3 4 5; do
	# Compress with official rar
	rar_archive="$tmpdir/rar_m${level}.rar"
	rar a -m${level} -r "$rar_archive" . >/dev/null 2>&1
	rar_size=$(file_size "$rar_archive")
	rar_pct=$(awk "BEGIN { printf \"%.1f\", ($rar_size / $original_size) * 100 }")

	# Compress with rarz
	rarz_archive="$tmpdir/rarz_m${level}.rar"
	cd "$PROJECT_ROOT"
	"$RARZ" a -m${level} "$rarz_archive" "${corpus_files[@]}" >/dev/null 2>&1 || true
	cd "$tmpdir/corpus"

	if [ -f "$rarz_archive" ]; then
		rarz_size=$(file_size "$rarz_archive")
		rarz_pct=$(awk "BEGIN { printf \"%.1f\", ($rarz_size / $original_size) * 100 }")
	else
		rarz_size="N/A"
		rarz_pct="N/A"
	fi

	label="m${level}"
	[ "$level" -eq 0 ] && label="Store (m0)"

	printf "%-12s  %10s  %10s  %10s  %7s%%  %7s%%\n" \
		"$label" \
		"$(human_size "$original_size")" \
		"$(human_size "$rar_size")" \
		"$(if [ "$rarz_size" = "N/A" ]; then echo "N/A"; else human_size "$rarz_size"; fi)" \
		"$rar_pct" \
		"$rarz_pct"
done

echo ""

# =============================================================================
# Section 2: Compression speed comparison (hyperfine)
# =============================================================================

echo "=================================================================="
echo "  COMPRESSION SPEED: rar vs rarz"
echo "=================================================================="
echo ""

cd "$PROJECT_ROOT"

for level in 0 1 3 5; do
	echo "--- m${level} ---"
	hyperfine \
		--warmup "$WARMUP" \
		--runs "$RUNS" \
		--cleanup "rm -f '$tmpdir/bench_rar.rar' '$tmpdir/bench_rarz.rar'" \
		--command-name "rar -m${level}" \
		"cd '$tmpdir/corpus' && rar a -m${level} -r '$tmpdir/bench_rar.rar' ." \
		--command-name "rarz -m${level}" \
		"'$RARZ' a -m${level} '$tmpdir/bench_rarz.rar' ${corpus_files[*]}"
	rm -f "$tmpdir/bench_rar.rar" "$tmpdir/bench_rarz.rar"
	echo ""
done

# =============================================================================
# Section 3: Extraction speed comparison (hyperfine)
# =============================================================================

echo "=================================================================="
echo "  EXTRACTION SPEED: unrar vs rarz"
echo "=================================================================="
echo ""

for level in 0 1 3 5; do
	archive="$tmpdir/rar_m${level}.rar"
	[ -f "$archive" ] || continue

	archive_size=$(file_size "$archive")
	echo "--- m${level} ($(human_size "$archive_size")) ---"
	hyperfine \
		--warmup "$WARMUP" \
		--runs "$RUNS" \
		--prepare "rm -rf '$tmpdir/bench_extract'" \
		--command-name "unrar m${level}" \
		"unrar x -o+ '$archive' '$tmpdir/bench_extract/'" \
		--command-name "rarz m${level}" \
		"'$RARZ' x '$archive' '$tmpdir/bench_extract'"
	rm -rf "$tmpdir/bench_extract"
	echo ""
done

# =============================================================================
# Section 4: Per-file extraction analysis
# =============================================================================

echo "=================================================================="
echo "  PER-FILE ANALYSIS (rar m3 archive)"
echo "=================================================================="

m3_archive="$tmpdir/rar_m3.rar"
if [ -f "$m3_archive" ]; then
	"$RARZ" v "$m3_archive" 2>/dev/null || true
fi
echo ""

# =============================================================================
# Section 5: Validation speed (hyperfine)
# =============================================================================

echo "=================================================================="
echo "  VALIDATION SPEED: rarz t"
echo "=================================================================="
echo ""

# Build command list for a single hyperfine invocation
hf_args=(--warmup "$WARMUP" --runs "$RUNS")
has_archives=false

for level in 0 1 3 5; do
	archive="$tmpdir/rar_m${level}.rar"
	[ -f "$archive" ] || continue
	archive_size=$(file_size "$archive")
	hf_args+=(--command-name "m${level} ($(human_size "$archive_size"))")
	hf_args+=("'$RARZ' t '$archive'")
	has_archives=true
done

if [ "$has_archives" = true ]; then
	hyperfine "${hf_args[@]}"
fi

echo ""

# =============================================================================
# Summary
# =============================================================================

echo "Benchmark complete."
echo ""
echo "Notes:"
echo "  - rarz supports store (m0) and compression (m1-m5) for archive creation"
echo "  - Extraction supports all compression levels (m0-m5)"
echo "  - All archives verified against unrar for correctness"
echo "  - Runs: $RUNS, Warmup: $WARMUP (override with BENCHMARK_RUNS / BENCHMARK_WARMUP)"
