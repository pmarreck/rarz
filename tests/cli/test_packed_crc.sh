#!/usr/bin/env bash
set -u
source tests/support/capture.bash || exit 1
RARZ=$(realpath "${RARZ:-zig-out/bin/rarz}") || exit 1
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
errors=0
out='' err='' rc=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
for prefix in rar4_vol_store rar4_vol_m3 rar5_vol_store rar5_vol_m3; do
	mkdir "$scratch/$prefix" || exit 1
	for path in tests/fixtures/"$prefix".part*.rar; do
		[[ -f $path ]] || exit 1
		cp "$path" "$scratch/$prefix/" || exit 1
	done
	first="$scratch/$prefix/$prefix.part1.rar"
	[[ -f $first ]] || first="$scratch/$prefix/$prefix.part01.rar"
	capture unrar t -p- -idq -qo- "$first"
	[[ $rc == 0 ]] || { fail "$prefix reference rejected pristine volumes"; continue; }
	capture "$RARZ" t "$first"
	[[ $rc == 0 ]] || { fail "$prefix candidate rejected pristine volumes"; continue; }
	capture luajit tests/support/packed-crc.lua mutate "$first" "$first"
	[[ $rc == 0 ]] || { fail "$prefix mutation adapter failed: $err"; continue; }
	capture unrar t -p- -idq -qo- "$first"
	# The reference ignores this inconsistent field while checking final content.
	[[ $rc == 0 ]] || fail "$prefix reference behavior changed (exit $rc)"
	capture luajit tests/support/packed-crc.lua check "$first"
	[[ $rc != 0 && $err == *'packed-part CRC mismatch'* ]] || fail "$prefix independent packed checksum check did not reject mutation"
	capture "$RARZ" t "$first"
	[[ $rc == 1 && $out == *'packed-part CRC32 mismatch'* ]] || fail "$prefix missed packed-part damage (exit $rc)"
	capture "$RARZ" verify "$first"
	[[ $rc == 1 ]] || fail "$prefix file verifier missed packed-part damage (exit $rc)"
	cp "$first" "$scratch/standalone.bin" || exit 1
	capture "$RARZ" t "$scratch/standalone.bin"
	[[ $rc == 1 && $out == *'packed-part CRC32 mismatch'* ]] || fail "$prefix standalone part missed packed CRC damage (exit $rc)"
done
awk 'BEGIN { for (i=1; i<=2048; i++) printf "%05d packed CRC control %d\n", i, i*i }' > "$scratch/payload.txt"
for method in 0 3; do
	capture "$RARZ" a "-m$method" -v2k "$scratch/writer-$method.rar" "$scratch/payload.txt"
	[[ $rc == 0 ]] || { fail "m$method writer failed"; continue; }
	# The CLI pads part numbers to the number of digits in the volume count.
	first=''
	for candidate in "$scratch/writer-$method".part*.rar; do first=$candidate; break; done
	[[ -f $first ]] || { fail "m$method writer produced no volumes"; continue; }
	capture luajit tests/support/packed-crc.lua check "$first"
	[[ $rc == 0 ]] || fail "m$method writer packed-part check failed: $err"
	capture unrar t -p- -idq -qo- "$first"
	[[ $rc == 0 ]] || fail "m$method reference rejected new volumes"
	capture "$RARZ" t "$first"
	[[ $rc == 0 ]] || fail "m$method candidate rejected new volumes"
done
[[ $errors == 0 ]] || exit 1
printf 'PASS: independent packed-part checksum damage across RAR4/RAR5 store/compressed volumes\n'
