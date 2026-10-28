#!/usr/bin/env bash
# Compare metadata with an independent extractor, not a rarz round trip.
set -u
source tests/support/capture.bash || exit 1
RARZ=$(realpath "${RARZ:-zig-out/bin/rarz}")
errors=0
out='' err='' rc=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors + 1)); }
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/input/tree/sub"
awk 'BEGIN { for (i=0; i<80; i++) print "timestamp interop payload" }' > "$scratch/input/payload"
cp "$scratch/input/payload" "$scratch/input/tree/sub/payload"

# Epoch, leap day, and the last representable RAR5 base-header second.
# The two fixed zones also catch accidentally packing a local DOS clock.
for stamp in 0 951782400 4294967295; do
	for zone in UTC0 EST5; do
		capture touch -d "@$stamp" "$scratch/input/payload"
		if [[ $rc != 0 || $(stat -c %Y "$scratch/input/payload") != "$stamp" ]]; then
			fail "filesystem cannot establish required timestamp $stamp"; continue
		fi
		for mode in store compressed volume compressed-volume; do
			case "$mode" in
				store) args=(-m0) ;;
				compressed) args=(-m3) ;;
				volume) args=(-m0 -v1k) ;;
				compressed-volume) args=(-m3 -v1k) ;;
			esac
			case_dir="$scratch/$stamp-$zone-$mode"
			mkdir -p "$case_dir/extracted"
			capture env TZ="$zone" "$RARZ" a "${args[@]}" "$case_dir/archive.rar" "$scratch/input/payload"
			if [[ $rc != 0 ]]; then fail "$stamp/$zone/$mode creation exit $rc"; continue; fi
			archive="$case_dir/archive.rar"
			[[ $mode == *volume ]] && archive="$case_dir/archive.part1.rar"
			capture env TZ="$zone" unrar x -idq -o+ "$archive" "$case_dir/extracted/"
			if [[ $rc != 0 ]]; then fail "$stamp/$zone/$mode reference extraction exit $rc"; continue; fi
			actual=$(stat -c %Y "$case_dir/extracted/payload")
			[[ $actual == "$stamp" ]] || fail "$stamp/$zone/$mode restored timestamp $actual"
			cmp -s "$scratch/input/payload" "$case_dir/extracted/payload" || fail "$stamp/$zone/$mode payload differs"
		done
	done
done

# A recursive directory has its own timestamp, independent of its contents.
touch -d @951782400 "$scratch/input/tree/sub/payload" "$scratch/input/tree/sub" "$scratch/input/tree"
mkdir -p "$scratch/tree-extracted"
capture "$RARZ" a -m0 "$scratch/tree.rar" "$scratch/input/tree"
[[ $rc == 0 ]] || fail "directory creation exit $rc"
# UnRAR does not restore these directory mtimes after creating children.
# Its metadata listing independently checks the stored directory values.
capture env TZ=UTC0 unrar lt "$scratch/tree.rar"
[[ $rc == 0 ]] || fail "directory reference listing exit $rc"
actual=$(awk '/^[[:space:]]*Name:/ {name=$2; sub(/\/$/, "", name)} /^[[:space:]]*mtime:/ {print $2, $3, name}' <<< "$out" | sort)
expected=$'2000-02-29 00:00:00,000000000 tree\n2000-02-29 00:00:00,000000000 tree/sub\n2000-02-29 00:00:00,000000000 tree/sub/payload'
[[ $actual == "$expected" ]] || fail 'stored directory timestamp set differs from reference'

# Out-of-range file/directory dates must fail before publishing an archive,
# including nested entries after a valid root was collected.
for stamp in -1 4294967296; do
	for kind in file directory nested-file nested-directory; do
		mkdir -p "$scratch/bad-$stamp-$kind/tree/sub"
		printf 'data\n' > "$scratch/bad-$stamp-$kind/tree/sub/payload"
		root="$scratch/bad-$stamp-$kind/tree"
		case "$kind" in
			file) target="$root/sub/payload"; input="$target" ;;
			directory) target="$root"; input="$root" ;;
			nested-file) target="$root/sub/payload"; input="$root" ;;
			nested-directory) target="$root/sub"; input="$root" ;;
		esac
		touch -d "@$stamp" "$target"
		archive="$scratch/bad-$stamp-$kind/archive.rar"
		capture "$RARZ" a -m0 "$archive" "$input"
		[[ $rc == 1 && $err == *'mtime outside RAR5'* && ! -e $archive ]] || fail "$stamp/$kind must reject unrepresentable mtime before archive output (exit $rc)"
	done
done

# Compare the complete name/date sets from independent producer fixtures.
for zone in UTC0 EST5; do
	for fixture in rar4_store rar5_store; do
		capture env TZ="$zone" unrar lt "tests/fixtures/$fixture.rar"
		[[ $rc == 0 ]] || { fail "$fixture reference listing exit $rc"; continue; }
		expected=$(awk '/^[[:space:]]*Name:/ {name=$2} /^[[:space:]]*mtime:/ {print $2, name}' <<< "$out" | sort)
		capture env TZ="$zone" "$RARZ" l "tests/fixtures/$fixture.rar"
		[[ $rc == 0 ]] || { fail "$fixture listing exit $rc"; continue; }
		actual=$(awk '$5 ~ /^[0-9][0-9][0-9][0-9]-/ {sub(/\/$/, "", $7); print $5, $7}' <<< "$out" | sort)
		[[ -n $expected && $actual == "$expected" ]] || fail "$fixture/$zone listing dates disagree with reference"
	done
done

[[ $errors == 0 ]] || exit 1
printf 'PASS: timestamp interop, range rejection, recursion, and format-aware listing\n'
