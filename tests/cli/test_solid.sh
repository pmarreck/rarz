#!/usr/bin/env bash
# Solid-archive support, measured against the unrar oracle.
#
# WHAT A SOLID ARCHIVE IS, AND WHY IT BREAKS AN INDEX-BASED API
#   In a solid archive every file is compressed as ONE continuous stream: file N
#   inherits the LZ window and the Huffman tables from file N-1. rarz's
#   `rarz_extract_to_buffer(handle, index, ...)` is random access with a fresh
#   decoder per call, so file 0 decodes correctly and everything after it decodes
#   against an empty window.
#
# WHY THIS MATTERS MORE THAN "EXTRACTION IS BROKEN"
#   The archives here are VALID -- unrar tests them All OK. rarz reported them
#   INVALID. For a product whose entire value is a trustworthy verdict, a false
#   positive on a good archive is the same betrayal as a false negative on a bad
#   one. Worse, one RAR5 entry came back at exactly the right size with the wrong
#   bytes, so a size check would have blessed it.
#
# THE THREE GATES
#   A. Extraction is byte-identical to unrar, per file. Catches silent wrongness
#      that a "did it error?" check cannot.
#   B. `rarz t` reports VALID -- i.e. the false positive is gone.
#   C. Corruption is still DETECTED. Gates A and B alone are satisfiable by
#      making the decoder forgiving, which would trade a false positive for a
#      false negative. C is differential against unrar: for each mutation we
#      compare verdicts and reject both missed damage and inconclusive runs.
set -u
source tests/support/validation-outcome.bash || exit 1

RARZ="${RARZ:-zig-out/bin/rarz}"
FIXTURES="${FIXTURES:-tests/fixtures}"
errors=0
pass=0

fail() {
	echo "  FAIL: $1"
	errors=$((errors + 1))
}

ok() {
	echo "  OK: $1"
	pass=$((pass + 1))
}

if [ ! -x "$RARZ" ]; then
	echo "ERROR: rarz binary not found at $RARZ"
	exit 1
fi

if ! command -v unrar >/dev/null 2>&1; then
	echo "ERROR: unrar not found -- run under 'nix develop -c'."
	echo "Without the oracle every assertion here is vacuous."
	exit 1
fi

# Look in both locations so this suite keeps working across the promotion out of
# known_gaps/ that is itself part of the acceptance criteria.
find_fixture() {
	if [ -f "$FIXTURES/$1" ]; then
		echo "$FIXTURES/$1"
	elif [ -f "$FIXTURES/known_gaps/$1" ]; then
		echo "$FIXTURES/known_gaps/$1"
	fi
}

SOLID_FIXTURES=""
for name in rar2_v20_solid.rar rar4_v29_solid.rar rar5_solid.rar; do
	p=$(find_fixture "$name")
	p=${p:-"$FIXTURES/$name"}
	SOLID_FIXTURES="$SOLID_FIXTURES $p"
done
require_fixture_paths $SOLID_FIXTURES || exit 1

# =============================================================================
# Precondition: every fixture really is solid, and really is valid.
# =============================================================================
echo "=== Precondition: fixtures are solid and unrar-clean ==="

for f in $SOLID_FIXTURES; do
	name=$(basename "$f")
	if ! unrar t "$f" >/dev/null 2>&1; then
		fail "$name: unrar does NOT consider this archive valid -- fixture is untrustworthy"
		continue
	fi
	# `rar a -s` silently produces a NON-solid archive when there is nothing to
	# share. A non-solid fixture here would pass every gate below while proving
	# nothing at all.
	if unrar lt "$f" 2>&1 | grep -qi 'solid'; then
		ok "$name: solid, and unrar reports All OK"
	else
		fail "$name: not actually a solid archive -- this fixture cannot falsify the bug"
	fi
done

# =============================================================================
# Gate A: extraction byte-identical to unrar
# =============================================================================
echo ""
echo "=== Gate A: solid extraction is byte-identical to unrar ==="

for f in $SOLID_FIXTURES; do
	name=$(basename "$f")

	rarz_dir=$(mktemp -d)
	unrar_dir=$(mktemp -d)

	rarz_out=$("$RARZ" x "$f" "$rarz_dir" 2>&1)
	rarz_rc=$?

	# Extracting a VALID archive must succeed cleanly. Comparing only file
	# CONTENT would let a nonzero exit and an error on stderr slide by, and a
	# caller scripting around rarz sees the exit code, not the bytes.
	if [ "$rarz_rc" -ne 0 ]; then
		fail "$name: rarz extract exited $rarz_rc on a valid archive: $(echo "$rarz_out" | grep -i error | head -1)"
	fi
	if echo "$rarz_out" | grep -qi 'error'; then
		fail "$name: rarz extract reported an error on a valid archive: $(echo "$rarz_out" | grep -i error | head -1)"
	fi

	if ! unrar x -o+ "$f" "$unrar_dir/" >/dev/null 2>&1; then
		fail "$name: unrar extract failed"
		rm -rf "$rarz_dir" "$unrar_dir"
		continue
	fi

	missing=0
	wrong=0
	total=0
	while IFS= read -r relpath; do
		total=$((total + 1))
		if [ ! -f "$rarz_dir/$relpath" ]; then
			missing=$((missing + 1))
		elif ! cmp -s "$rarz_dir/$relpath" "$unrar_dir/$relpath"; then
			wrong=$((wrong + 1))
			echo "      mismatch: $relpath"
		fi
	done < <(cd "$unrar_dir" && find . -type f | sed 's|^\./||' | sort)

	if [ "$missing" -eq 0 ] && [ "$wrong" -eq 0 ] && [ "$total" -gt 0 ]; then
		ok "$name: all $total files byte-identical"
	else
		fail "$name: $total files, $missing missing, $wrong wrong (rarz exit $rarz_rc)"
	fi

	rm -rf "$rarz_dir" "$unrar_dir"
done

# =============================================================================
# Gate B: validation agrees with the oracle on the PRISTINE archive
# =============================================================================
echo ""
echo "=== Gate B: rarz validates solid archives as VALID ==="

for f in $SOLID_FIXTURES; do
	name=$(basename "$f")
	observe_rarz_test "$RARZ" "$f"
	if [[ $rarz_t_class == valid ]]; then
		ok "$name: VALID"
	else
		fail "$name: $rarz_t_class (exit $rarz_t_status), expected valid"
	fi
done

# =============================================================================
# Gate C: corruption is still detected (differential vs unrar)
# =============================================================================
echo ""
echo "=== Gate C: corruption in solid archives is still detected ==="

# Gates A and B can both be satisfied by a decoder that simply stops
# complaining. This gate is what stops that: it flips a byte deep in the payload
# and compares explicit verdicts. Crashes, timeouts and unsupported outcomes
# are inconclusive and fail the gate; they cannot count as damage detection.
for f in $SOLID_FIXTURES; do
	name=$(basename "$f")
	filesize=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)

	# Stay clear of the signature and the first headers; we want payload bytes.
	safe_start=$((filesize / 4))
	span=$((filesize - safe_start - 16))
	if [ "$span" -lt 1 ]; then fail "$name: INCOMPLETE mutation range"; continue; fi
	# Preregistered checksum-damage controls from the hash-pinned corpus.
	# These are existing trial positions, overwritten with 0xA5, not new shots.
	case "$name" in
		rar2_v20_solid.rar) control_offset=11280 ;;
		rar4_v29_solid.rar) control_offset=13305 ;;
		rar5_solid.rar) control_offset=13290 ;;
		*) fail "$name: no declared must-detect control"; continue ;;
	esac

	total=12
	exercised=0
	controls_passed=0
	detected=0
	benign=0
	stricter=0
	failed=0
	for i in $(seq 1 $total); do
		offset=$(( safe_start + (i * 7919) % span ))
		corrupt="$(mktemp)"
		legacy_mutate "$f" "$corrupt" overwrite-byte-v1 "$offset" 165 || exit 1

		observe_unrar_test "$corrupt"
		observe_rarz_test "$RARZ" "$corrupt"
		exercised=$((exercised + 1))
		pair=$(classify_mutation_pair "$unrar_t_class" "$rarz_t_class")
		if [[ $offset == "$control_offset" && $pair == detected ]]; then
			controls_passed=$((controls_passed + 1))
		fi
		case "$pair" in
			detected) detected=$((detected + 1)) ;;
			benign) benign=$((benign + 1)) ;;
			stricter) stricter=$((stricter + 1)) ;;
			*)
				failed=$((failed + 1))
				fail "$name mutation $i: unrar=$unrar_t_class/$unrar_t_execution/$unrar_t_status rarz=$rarz_t_class/$rarz_t_execution/$rarz_t_status"
				;;
		esac

		rm -f "$corrupt"
	done

	if [[ $(classify_required_trials "$total" "$exercised" 1 "$controls_passed") != complete ]]; then
		fail "$name: INCOMPLETE ($exercised/$total trials, $controls_passed/1 known damage controls)"
	elif [ "$failed" -eq 0 ]; then
		ok "$name: $detected detected, $benign benign, $stricter stricter ($total mutations)"
	fi
done

echo ""
echo "Results: $pass passed, $errors failed"

if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors assertion(s)"
	exit 1
fi

echo "PASS: test_solid.sh"
