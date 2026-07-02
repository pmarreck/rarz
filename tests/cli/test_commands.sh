#!/usr/bin/env bash
set -u

RARZ="zig-out/bin/rarz"
errors=0

# Generate a test archive
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "hello rarz" > "$tmpdir/hello.txt"
echo "world" > "$tmpdir/world.txt"

# Create archive with official rar (store mode, RAR5 format)
(cd "$tmpdir" && rar a -m0 -ma5 test.rar hello.txt world.txt) >/dev/null 2>&1

# Test: rarz t
if ! "$RARZ" t "$tmpdir/test.rar" >/dev/null 2>&1; then
	echo "FAIL: rarz t should succeed on valid archive"
	errors=$((errors + 1))
fi

# Test: rarz test (long form)
if ! "$RARZ" test "$tmpdir/test.rar" >/dev/null 2>&1; then
	echo "FAIL: rarz test (long form) should succeed"
	errors=$((errors + 1))
fi

# Test: rarz t output contains VALID
output=$("$RARZ" t "$tmpdir/test.rar" 2>&1)
if [[ "$output" != *"VALID"* ]]; then
	echo "FAIL: rarz t should report VALID"
	errors=$((errors + 1))
fi

# Test: rarz l
output=$("$RARZ" l "$tmpdir/test.rar" 2>&1)
if [[ "$output" != *"hello.txt"* ]]; then
	echo "FAIL: rarz l should list hello.txt"
	errors=$((errors + 1))
fi

# Test: rarz list (long form)
output=$("$RARZ" list "$tmpdir/test.rar" 2>&1)
if [[ "$output" != *"world.txt"* ]]; then
	echo "FAIL: rarz list should list world.txt"
	errors=$((errors + 1))
fi

# Test: rarz v (verbose list)
output=$("$RARZ" v "$tmpdir/test.rar" 2>&1)
if [[ "$output" != *"Unpacked"* ]]; then
	echo "FAIL: rarz v should show verbose header"
	errors=$((errors + 1))
fi
if [[ "$output" != *"hello.txt"* ]]; then
	echo "FAIL: rarz v should list hello.txt"
	errors=$((errors + 1))
fi

# Test: rarz list-verbose (long form)
output=$("$RARZ" list-verbose "$tmpdir/test.rar" 2>&1)
if [[ "$output" != *"Packed"* ]]; then
	echo "FAIL: rarz list-verbose should show Packed column"
	errors=$((errors + 1))
fi

# Test: rarz x (extract)
mkdir "$tmpdir/out"
if "$RARZ" x "$tmpdir/test.rar" "$tmpdir/out" >/dev/null 2>&1; then
	# Check extracted files exist and match
	if [ ! -f "$tmpdir/out/hello.txt" ]; then
		echo "FAIL: hello.txt not extracted"
		errors=$((errors + 1))
	elif [ "$(cat "$tmpdir/out/hello.txt")" != "hello rarz" ]; then
		echo "FAIL: hello.txt content mismatch"
		errors=$((errors + 1))
	fi

	if [ ! -f "$tmpdir/out/world.txt" ]; then
		echo "FAIL: world.txt not extracted"
		errors=$((errors + 1))
	elif [ "$(cat "$tmpdir/out/world.txt")" != "world" ]; then
		echo "FAIL: world.txt content mismatch"
		errors=$((errors + 1))
	fi
else
	echo "FAIL: rarz x should succeed on store archive"
	errors=$((errors + 1))
fi

# Test: rarz extract (long form)
mkdir "$tmpdir/out2"
if ! "$RARZ" extract "$tmpdir/test.rar" "$tmpdir/out2" >/dev/null 2>&1; then
	echo "FAIL: rarz extract (long form) should succeed"
	errors=$((errors + 1))
fi

# Test: rarz a (create store archive)
if ! "$RARZ" a "$tmpdir/created.rar" "$tmpdir/hello.txt" "$tmpdir/world.txt" >/dev/null 2>&1; then
	echo "FAIL: rarz a should succeed creating archive"
	errors=$((errors + 1))
fi

# Test: created archive is valid according to rarz
if [ -f "$tmpdir/created.rar" ]; then
	output=$("$RARZ" t "$tmpdir/created.rar" 2>&1)
	if [[ "$output" != *"VALID"* ]]; then
		echo "FAIL: rarz-created archive should validate as VALID"
		errors=$((errors + 1))
	fi

	# Test: created archive is readable by official unrar
	if ! unrar t "$tmpdir/created.rar" >/dev/null 2>&1; then
		echo "FAIL: rarz-created archive should be valid for unrar"
		errors=$((errors + 1))
	fi

	# Test: extract rarz-created archive and verify contents
	mkdir -p "$tmpdir/rarz_out"
	if unrar x -o+ "$tmpdir/created.rar" "$tmpdir/rarz_out/" >/dev/null 2>&1; then
		if [ ! -f "$tmpdir/rarz_out/hello.txt" ]; then
			echo "FAIL: unrar should extract hello.txt from rarz archive"
			errors=$((errors + 1))
		elif [ "$(cat "$tmpdir/rarz_out/hello.txt")" != "hello rarz" ]; then
			echo "FAIL: unrar-extracted hello.txt content mismatch"
			errors=$((errors + 1))
		fi
		if [ ! -f "$tmpdir/rarz_out/world.txt" ]; then
			echo "FAIL: unrar should extract world.txt from rarz archive"
			errors=$((errors + 1))
		elif [ "$(cat "$tmpdir/rarz_out/world.txt")" != "world" ]; then
			echo "FAIL: unrar-extracted world.txt content mismatch"
			errors=$((errors + 1))
		fi
	else
		echo "FAIL: unrar x should succeed on rarz-created archive"
		errors=$((errors + 1))
	fi

	# Test: rarz can also list the created archive
	output=$("$RARZ" l "$tmpdir/created.rar" 2>&1)
	if [[ "$output" != *"hello.txt"* ]]; then
		echo "FAIL: rarz l should list hello.txt in created archive"
		errors=$((errors + 1))
	fi

	# Test: rarz can extract the created archive
	mkdir -p "$tmpdir/rarz_extract"
	if "$RARZ" x "$tmpdir/created.rar" "$tmpdir/rarz_extract" >/dev/null 2>&1; then
		if [ ! -f "$tmpdir/rarz_extract/hello.txt" ]; then
			echo "FAIL: rarz x should extract hello.txt from created archive"
			errors=$((errors + 1))
		elif [ "$(cat "$tmpdir/rarz_extract/hello.txt")" != "hello rarz" ]; then
			echo "FAIL: rarz-extracted hello.txt content mismatch"
			errors=$((errors + 1))
		fi
	else
		echo "FAIL: rarz x should succeed on rarz-created archive"
		errors=$((errors + 1))
	fi
else
	echo "FAIL: rarz a did not create the archive file"
	errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors tests"
	exit 1
fi

echo "PASS: test_commands.sh"
