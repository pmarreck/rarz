#!/usr/bin/env bash
# Producer-observed units and overflow boundaries without giant allocations.
set -u
source tests/support/capture.bash || exit 1
RARZ=$(realpath "${RARZ:-zig-out/bin/rarz}") || exit 1
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
out='' err='' rc=0
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
printf 'Volume-size control %.0s' {1..1024} > "$scratch/payload.txt"
while read -r size expected; do
	for producer in rar "$RARZ"; do
		label=reference; [[ $producer == rar ]] || label=candidate
		directory="$scratch/$label-$size"
		mkdir "$directory" || exit 1
		capture "$producer" a -m0 "-v$size" "$directory/archive.rar" "$scratch/payload.txt"
		[[ $rc == 0 ]] || { fail "$label rejected $size: $err"; continue; }
		first=''
		for part in "$directory"/*.rar; do first=$part; break; done
		[[ -f $first ]] || { fail "$label $size emitted no archive"; continue; }
		[[ $(stat -c %s "$first") == "$expected" ]] || fail "$label $size did not produce $expected-byte volumes"
	done
done <<'SIZES'
2k 2048
2K 2000
2048b 2048
2048B 2048
2 2000
SIZES

# UINT64_MAX divided by each declared unit. The missing source ensures that
# accepted sizes reach I/O but cannot allocate a requested huge volume.
while read -r accepted overflow; do
	capture "$RARZ" a "-v$accepted" "$scratch/out.rar" "$scratch/missing"
	[[ $rc == 1 && $err == *'cannot stat'* ]] || fail "$accepted did not pass numeric validation"
	capture "$RARZ" a "-v$overflow" "$scratch/out.rar" "$scratch/missing"
	[[ $rc == 1 && $err == *'invalid volume size'* ]] || fail "$overflow was not rejected as overflow"
done <<'BOUNDARIES'
18446744073709551615b 18446744073709551616b
18446744073709551615B 18446744073709551616B
18446744073709551 18446744073709552
18446744073709551K 18446744073709552K
18014398509481983k 18014398509481984k
18446744073709M 18446744073710M
17592186044415m 17592186044416m
18446744073G 18446744074G
17179869183g 17179869184g
18446744T 18446745T
16777215t 16777216t
BOUNDARIES
for size in -1 +2 ' 2k' 2kk 2.5K 0 18446744073709551616; do
	capture "$RARZ" a "-v$size" "$scratch/out.rar" "$scratch/missing"
	[[ $rc == 1 && $err == *'invalid volume size'* ]] || fail "invalid numeric token accepted: $size"
done
[[ $errors == 0 ]] || exit 1
printf 'PASS: producer volume units and checked unsigned-size boundaries\n'
