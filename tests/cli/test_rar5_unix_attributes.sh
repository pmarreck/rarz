#!/usr/bin/env bash
# RAR5 uses host value 1 for Unix; value 3 belongs to the older format.
set -u
umask 077
export LC_ALL=C
source tests/support/capture.bash || exit 1
RARZ=$(realpath "${RARZ:-zig-out/bin/rarz}") || exit 1
scratch=$(mktemp -d) || exit 1
errors=0
trap 'if [[ $errors == 0 ]]; then rm -rf "$scratch"; else printf "Failure fixtures retained at %s\n" "$scratch"; fi' EXIT
out='' err='' rc=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
mkdir "$scratch/source" || exit 1
mkdir "$scratch/source/nested" || exit 1
mkdir "$scratch/source/empty" || exit 1
printf '#!/bin/sh\nprintf "archive attribute control\\n"\n' > "$scratch/source/script.sh"
printf 'Nested attribute control\n' > "$scratch/source/nested/data.txt"
chmod 710 "$scratch/source"
chmod 731 "$scratch/source/nested"
chmod 750 "$scratch/source/empty"
chmod 751 "$scratch/source/script.sh"
chmod 640 "$scratch/source/nested/data.txt"
TZ=UTC touch -t 202601020304.05 "$scratch/source" "$scratch/source/nested" "$scratch/source/empty" || exit 1
cd "$scratch" || exit 1
for method in 0 3; do
 capture "$RARZ" a "-m$method" "archive-$method.rar" source
 [[ $rc == 0 ]] || { fail "creation failed for m$method"; continue; }
 capture unrar lt -p- "archive-$method.rar"
 [[ $rc == 0 ]] || { fail "reference listing failed for m$method"; continue; }
 unix_entries=0
 attributes=''
 name=''
 while IFS= read -r line; do
  line=${line%$'\r'}
  [[ $line != *'Host OS: Unix'* ]] || unix_entries=$((unix_entries+1))
  case "$line" in
   *'Name: '*) name=${line#*Name: } ;;
   *'Attributes: '*) attributes+="$name=${line#*Attributes: }"$'\n' ;;
  esac
 done <<< "$out"
 [[ $unix_entries == 5 ]] || fail "m$method declares $unix_entries Unix entries, expected three directories and two files"
 expected_attributes=$(stat -c '%n=%A' source source/nested source/empty source/script.sh source/nested/data.txt | sort)
 observed_attributes=$(printf '%s' "$attributes" | sort)
 [[ $observed_attributes == "$expected_attributes" ]] || fail "m$method archived attributes differ from the source set"
 mkdir "extract-$method" || exit 1
 capture unrar x -p- -idq -o+ "archive-$method.rar" "extract-$method/"
 [[ $rc == 0 ]] || { fail "reference extraction failed for m$method (exit $rc): $err"; continue; }
 [[ $(stat -c %a "extract-$method/source") == 710 ]] || fail "m$method directory mode lost"
 [[ $(stat -c %a "extract-$method/source/nested") == 731 ]] || fail "m$method nested directory mode lost"
 [[ $(stat -c %a "extract-$method/source/script.sh") == 751 ]] || fail "m$method executable mode lost"
 [[ $(stat -c %a "extract-$method/source/nested/data.txt") == 640 ]] || fail "m$method nested file mode lost"
 cmp source/script.sh "extract-$method/source/script.sh" >/dev/null || fail "m$method data changed"
 cmp source/nested/data.txt "extract-$method/source/nested/data.txt" >/dev/null || fail "m$method nested data changed"
 for directory in source source/nested source/empty; do
  [[ $(stat -c %Y "extract-$method/$directory") == $(stat -c %Y "$directory") ]] || fail "m$method directory timestamp changed for $directory"
 done
 # UNRAR leaves empty-directory modes restricted even for producer archives.
 # Check the stored mode above and compare extraction against that control.
 capture rar a "-m$method" "reference-$method.rar" source
 [[ $rc == 0 ]] || { fail "reference creation failed for m$method"; continue; }
 mkdir "reference-$method" || exit 1
 capture unrar x -p- -idq -o+ "reference-$method.rar" "reference-$method/"
 [[ $rc == 0 ]] || { fail "reference control extraction failed for m$method"; continue; }
 [[ $(stat -c %a "extract-$method/source/empty") == $(stat -c %a "reference-$method/source/empty") ]] || fail "m$method empty directory differs from independent producer extraction"
done
[[ $errors == 0 ]] || exit 1
printf 'PASS: RAR5 Unix identity and independent attribute restoration\n'
