#!/usr/bin/env bash
set -u
source tests/support/validation-outcome.bash || exit 1

RARZ="${RARZ:-zig-out/bin/rarz}"
FIXTURES="tests/fixtures"
errors=0
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

fail() {
	echo "FAIL: $1"
	errors=$((errors + 1))
}

# Ensure fixtures exist
if [ ! -d "$FIXTURES" ] || [ -z "$(ls "$FIXTURES"/*.rar 2>/dev/null)" ]; then
	echo "ERROR: No fixtures found in $FIXTURES/"
	echo "Run: nix develop -c bash tests/generate_fixtures.sh"
	exit 1
fi

# --- Interop Gate A: official-encoded archives decode in rarz ---

echo "=== Interop Gate A: official -> rarz ==="

for f in "$FIXTURES"/*.rar; do
	name=$(basename "$f")

	# Skip multi-volume parts (not standalone archives)
	if echo "$name" | grep -qE '\.part[0-9]+\.rar$'; then
		continue
	fi

	# Header-encrypted fixtures are UNVERIFIABLE by design: `rarz t` reports
	# UNVERIFIABLE and exits 69, which is the correct verdict, not a failure.
	# Their own gate is test_verify.sh Gate G.
	case "$name" in
		rar4_hp.rar|rar5_hp.rar) continue ;;
	esac

	# rarz t should succeed on all official archives
	observe_rarz_test "$RARZ" "$f"
	if [[ $rarz_t_class != valid ]]; then
		fail "$name: rarz=$rarz_t_class/$rarz_t_status, expected valid"
	fi

	# rarz l should succeed
	if ! "$RARZ" l "$f" >/dev/null 2>&1; then
		fail "rarz l failed on $name"
	fi
done

# Store archives should extract correctly
for f in "$FIXTURES"/rar5_store.rar "$FIXTURES"/single_file.rar "$FIXTURES"/rarz_created.rar; do
	[ -f "$f" ] || continue
	name=$(basename "$f")
	tmpdir=$(mktemp -d)

	if "$RARZ" x "$f" "$tmpdir" >/dev/null 2>&1; then
		# Verify at least one file was extracted
		if [ -z "$(find "$tmpdir" -type f)" ]; then
			fail "rarz x $name: no files extracted"
		fi
	else
		fail "rarz x failed on $name"
	fi

	rm -rf "$tmpdir"
done

# --- Interop Gate B: rarz-encoded archives decode in official tools ---

echo "=== Interop Gate B: rarz -> official ==="

if [ -f "$FIXTURES/rarz_created.rar" ]; then
	# unrar t should succeed
	if ! unrar t "$FIXTURES/rarz_created.rar" >/dev/null 2>&1; then
		fail "unrar t failed on rarz_created.rar"
	fi

	# unrar x should succeed
	tmpdir=$(mktemp -d)
	if unrar x -o+ "$FIXTURES/rarz_created.rar" "$tmpdir/" >/dev/null 2>&1; then
		if [ ! -f "$tmpdir/rarz_file.txt" ]; then
			# Check without path prefix
			found=$(find "$tmpdir" -name "rarz_file.txt" -type f | head -1)
			if [ -z "$found" ]; then
				fail "unrar x rarz_created.rar: rarz_file.txt not extracted"
			fi
		fi
	else
		fail "unrar x failed on rarz_created.rar"
	fi
	rm -rf "$tmpdir"
fi

# --- Corruption Detection ---

echo "=== Corruption Detection (5x deterministic mutations) ==="

# Use a deterministic seed for reproducible mutations
seed=42

for f in "$FIXTURES"/rar5_store.rar "$FIXTURES"/single_file.rar; do
	[ -f "$f" ] || continue
	name=$(basename "$f")
	filesize=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)

	# Skip signature region (first 8 bytes)
	safe_start=9
	detected=0
	benign=0
	stricter=0

	for i in $(seq 1 5); do
		# Deterministic offset from seed
		offset=$(( (seed * 31 + i * 17) % (filesize - safe_start) + safe_start ))

		corrupt_file="$work/corrupt_${name}_${i}.rar"
		legacy_mutate "$f" "$corrupt_file" overwrite-byte-v1 "$offset" 255 || exit 1

		observe_unrar_test "$corrupt_file"
		observe_rarz_test "$RARZ" "$corrupt_file"
		case "$(classify_mutation_pair "$unrar_t_class" "$rarz_t_class")" in
			detected) detected=$((detected + 1)) ;;
			benign) benign=$((benign + 1)) ;;
			stricter) stricter=$((stricter + 1)) ;;
			*) fail "$name mutation $i: unrar=$unrar_t_class/$unrar_t_execution/$unrar_t_status rarz=$rarz_t_class/$rarz_t_execution/$rarz_t_status" ;;
		esac

		rm -f "$corrupt_file"
	done
	[[ $detected -gt 0 ]] || fail "$name: mutation gate produced no confirmed damage detections"
	printf '  %s: %s detected, %s benign, %s stricter\n' "$name" "$detected" "$benign" "$stricter"
done

# --- Summary ---

echo ""
if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors integration tests"
	exit 1
fi

echo "PASS: test_integration.sh"
