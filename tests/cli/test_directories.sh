#!/usr/bin/env bash
set -u

RARZ="zig-out/bin/rarz"
errors=0

fail() {
	echo "FAIL: $1"
	errors=$((errors + 1))
}

# ========================================================================
# Test 1: Directory recursion + path preservation
# ========================================================================
echo "=== Test 1: Directory recursion + path preservation ==="

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Create a nested directory structure
mkdir -p "$tmpdir/mydir/sub/deep"
echo "hello from root" > "$tmpdir/mydir/root.txt"
echo "hello from sub" > "$tmpdir/mydir/sub/mid.txt"
echo "hello from deep" > "$tmpdir/mydir/sub/deep/file.txt"

# Archive the directory
if ! "$RARZ" a "$tmpdir/test1.rar" "$tmpdir/mydir/" 2>/dev/null; then
	fail "test1: rarz a failed to archive directory"
else
	# Extract and verify path structure
	mkdir -p "$tmpdir/extract1"
	if ! "$RARZ" x "$tmpdir/test1.rar" "$tmpdir/extract1" 2>/dev/null; then
		fail "test1: rarz x failed to extract"
	else
		# Verify nested files exist with full paths preserved
		if [ ! -f "$tmpdir/extract1/mydir/root.txt" ]; then
			fail "test1: mydir/root.txt not found after extract"
		fi
		if [ ! -f "$tmpdir/extract1/mydir/sub/mid.txt" ]; then
			fail "test1: mydir/sub/mid.txt not found after extract"
		fi
		if [ ! -f "$tmpdir/extract1/mydir/sub/deep/file.txt" ]; then
			fail "test1: mydir/sub/deep/file.txt not found after extract"
		fi
		# Verify content
		content=$(cat "$tmpdir/extract1/mydir/sub/deep/file.txt" 2>/dev/null || echo "")
		if [ "$content" != "hello from deep" ]; then
			fail "test1: mydir/sub/deep/file.txt has wrong content: '$content'"
		fi
	fi
fi

# ========================================================================
# Test 2: Mixed files + directories
# ========================================================================
echo "=== Test 2: Mixed files + directories ==="

echo "standalone content" > "$tmpdir/standalone.txt"

if ! "$RARZ" a "$tmpdir/test2.rar" "$tmpdir/standalone.txt" "$tmpdir/mydir/" 2>/dev/null; then
	fail "test2: rarz a failed with mixed files + directory"
else
	mkdir -p "$tmpdir/extract2"
	if ! "$RARZ" x "$tmpdir/test2.rar" "$tmpdir/extract2" 2>/dev/null; then
		fail "test2: rarz x failed to extract"
	else
		if [ ! -f "$tmpdir/extract2/standalone.txt" ]; then
			fail "test2: standalone.txt not found"
		fi
		if [ ! -f "$tmpdir/extract2/mydir/root.txt" ]; then
			fail "test2: mydir/root.txt not found in mixed archive"
		fi
	fi
fi

# ========================================================================
# Test 3: More than 64 files
# ========================================================================
echo "=== Test 3: More than 64 files ==="

mkdir -p "$tmpdir/manyfiles"
for i in $(seq 1 70); do
	echo "file content $i" > "$tmpdir/manyfiles/file_$(printf '%03d' $i).txt"
done

if ! "$RARZ" a "$tmpdir/test3.rar" "$tmpdir/manyfiles/" 2>/dev/null; then
	fail "test3: rarz a failed with 70 files"
else
	# List and count files
	file_count=$("$RARZ" l "$tmpdir/test3.rar" 2>/dev/null | grep -c "file_[0-9]" || echo "0")
	if [ "$file_count" -lt 70 ]; then
		fail "test3: expected 70 files, got $file_count"
	fi
fi

# ========================================================================
# Test 4: Compressed directory round-trip
# ========================================================================
echo "=== Test 4: Compressed directory round-trip ==="

if ! "$RARZ" a -m3 "$tmpdir/test4.rar" "$tmpdir/mydir/" 2>/dev/null; then
	fail "test4: rarz a -m3 failed with directory"
else
	mkdir -p "$tmpdir/extract4"
	if ! "$RARZ" x "$tmpdir/test4.rar" "$tmpdir/extract4" 2>/dev/null; then
		fail "test4: rarz x failed to extract compressed directory archive"
	else
		content=$(cat "$tmpdir/extract4/mydir/sub/deep/file.txt" 2>/dev/null || echo "")
		if [ "$content" != "hello from deep" ]; then
			fail "test4: compressed round-trip content mismatch: '$content'"
		fi
	fi
fi

# ========================================================================
# Test 5: Metadata preserved (non-zero mtime)
# ========================================================================
echo "=== Test 5: Metadata preserved ==="

if [ -f "$tmpdir/test1.rar" ]; then
	# Check that listing shows non-empty dates (not all spaces)
	date_lines=$("$RARZ" l "$tmpdir/test1.rar" 2>/dev/null | grep -E "^[[:space:]]+[0-9]" | grep -cv "^.*          " || echo "0")
	if [ "$date_lines" -lt 1 ]; then
		fail "test5: expected non-zero mtime in listing, all dates appear empty"
	fi
fi

# ========================================================================
# Test 6: Interop — rarz -> unrar (directory archive, store + compressed)
# ========================================================================
echo "=== Test 6: Interop — rarz -> unrar (directory archive) ==="

if [ -f "$tmpdir/test1.rar" ]; then
	# unrar t should validate
	if ! unrar t "$tmpdir/test1.rar" >/dev/null 2>&1; then
		fail "test6: unrar t failed on rarz-created directory archive"
	else
		echo "  OK: unrar t validates rarz directory archive"
	fi

	# unrar x should extract with paths preserved, byte-for-byte
	mkdir -p "$tmpdir/unrar_out"
	if unrar x -o+ "$tmpdir/test1.rar" "$tmpdir/unrar_out/" >/dev/null 2>&1; then
		# Check every original file against unrar extraction
		checked=0
		while IFS= read -r relpath; do
			orig="$tmpdir/$relpath"
			extracted="$tmpdir/unrar_out/$relpath"
			if [ ! -f "$extracted" ]; then
				fail "test6: unrar missing $relpath"
			elif ! cmp -s "$orig" "$extracted"; then
				fail "test6: unrar content mismatch for $relpath"
			else
				checked=$((checked + 1))
			fi
		done < <(cd "$tmpdir" && find mydir -type f | sort)
		echo "  OK: unrar extracted $checked files with correct content"
	else
		fail "test6: unrar x failed on rarz-created directory archive"
	fi

	# Also test the compressed variant
	if [ -f "$tmpdir/test4.rar" ]; then
		mkdir -p "$tmpdir/unrar_m3"
		if unrar x -o+ "$tmpdir/test4.rar" "$tmpdir/unrar_m3/" >/dev/null 2>&1; then
			checked=0
			while IFS= read -r relpath; do
				orig="$tmpdir/$relpath"
				extracted="$tmpdir/unrar_m3/$relpath"
				if [ ! -f "$extracted" ]; then
					fail "test6: unrar m3 missing $relpath"
				elif ! cmp -s "$orig" "$extracted"; then
					fail "test6: unrar m3 content mismatch for $relpath"
				else
					checked=$((checked + 1))
				fi
			done < <(cd "$tmpdir" && find mydir -type f | sort)
			echo "  OK: unrar extracted $checked files from -m3 archive"
		else
			fail "test6: unrar x failed on rarz -m3 directory archive"
		fi
	fi
fi

# ========================================================================
# Test 7: Interop — rar -> rarz (multiple directories, all methods)
# ========================================================================
echo "=== Test 7: Interop — rar -> rarz (multi-directory archive) ==="

# Create multiple directory trees
mkdir -p "$tmpdir/src/alpha/deep" "$tmpdir/src/beta"
echo "alpha root" > "$tmpdir/src/alpha/root.txt"
echo "alpha deep" > "$tmpdir/src/alpha/deep/nested.txt"
echo "beta file" > "$tmpdir/src/beta/data.bin"
# Create a file at the top level too
echo "top level" > "$tmpdir/src/top.txt"

# Archive with rar using relative paths (cd into parent)
(cd "$tmpdir/src" && rar a -r "$tmpdir/rar_multi.rar" . >/dev/null 2>&1)

if [ -f "$tmpdir/rar_multi.rar" ]; then
	# rarz t should validate
	if ! "$RARZ" t "$tmpdir/rar_multi.rar" >/dev/null 2>&1; then
		fail "test7: rarz t failed on rar-created multi-dir archive"
	else
		echo "  OK: rarz t validates rar multi-dir archive"
	fi

	# rarz l should list
	file_count=$("$RARZ" l "$tmpdir/rar_multi.rar" 2>/dev/null | grep -c "[0-9]" || echo "0")
	echo "  OK: rarz l lists $file_count entries"

	# rarz x should extract and content must match
	mkdir -p "$tmpdir/rarz_from_rar"
	if "$RARZ" x "$tmpdir/rar_multi.rar" "$tmpdir/rarz_from_rar" >/dev/null 2>&1; then
		checked=0
		while IFS= read -r relpath; do
			orig="$tmpdir/src/$relpath"
			# rar may strip leading ./ or not; search by name
			fname=$(basename "$relpath")
			found=$(find "$tmpdir/rarz_from_rar" -name "$fname" -type f | head -1)
			if [ -z "$found" ]; then
				fail "test7: rarz missing '$fname' from rar archive"
			elif ! cmp -s "$orig" "$found"; then
				fail "test7: rarz content mismatch for '$fname'"
			else
				checked=$((checked + 1))
			fi
		done < <(cd "$tmpdir/src" && find . -type f | sed 's|^\./||' | sort)
		echo "  OK: rarz extracted $checked files from rar archive, all match"
	else
		fail "test7: rarz x failed on rar-created multi-dir archive"
	fi

	# Cross-check: extract with both tools and compare byte-for-byte
	mkdir -p "$tmpdir/unrar_from_rar"
	if unrar x -o+ "$tmpdir/rar_multi.rar" "$tmpdir/unrar_from_rar/" >/dev/null 2>&1; then
		mismatches=0
		while IFS= read -r relpath; do
			rarz_file="$tmpdir/rarz_from_rar/$relpath"
			unrar_file="$tmpdir/unrar_from_rar/$relpath"
			if [ -f "$rarz_file" ] && [ -f "$unrar_file" ]; then
				if ! cmp -s "$rarz_file" "$unrar_file"; then
					fail "test7: rarz vs unrar mismatch for '$relpath'"
					mismatches=$((mismatches + 1))
				fi
			fi
		done < <(cd "$tmpdir/unrar_from_rar" && find . -type f | sed 's|^\./||' | sort)
		if [ "$mismatches" -eq 0 ]; then
			echo "  OK: rarz and unrar produce identical files"
		fi
	fi
else
	fail "test7: rar command failed to create archive"
fi

# ========================================================================
# Test 8: Interop — rarz store directory -> unrar (no compression)
# ========================================================================
echo "=== Test 8: Interop — rarz -m0 directory -> unrar ==="

if ! "$RARZ" a -m0 "$tmpdir/test8_store.rar" "$tmpdir/mydir/" 2>/dev/null; then
	fail "test8: rarz a -m0 failed"
else
	mkdir -p "$tmpdir/unrar_store"
	if unrar x -o+ "$tmpdir/test8_store.rar" "$tmpdir/unrar_store/" >/dev/null 2>&1; then
		checked=0
		while IFS= read -r relpath; do
			orig="$tmpdir/$relpath"
			extracted="$tmpdir/unrar_store/$relpath"
			if [ ! -f "$extracted" ]; then
				fail "test8: unrar store missing $relpath"
			elif ! cmp -s "$orig" "$extracted"; then
				fail "test8: unrar store content mismatch for $relpath"
			else
				checked=$((checked + 1))
			fi
		done < <(cd "$tmpdir" && find mydir -type f | sort)
		echo "  OK: unrar extracted $checked files from rarz -m0 archive"
	else
		fail "test8: unrar x failed on rarz -m0 directory archive"
	fi
fi

# ========================================================================
# Summary
# ========================================================================
echo ""
if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors directory tests"
	exit 1
fi

echo "PASS: test_directories.sh"
