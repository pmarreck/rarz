#!/usr/bin/env bash
set -u

RARZ="zig-out/bin/rarz"
errors=0

# Test: help output
output=$("$RARZ" 2>&1 || true)
if [[ "$output" != *"rarz"* ]]; then
	echo "FAIL: help output missing 'rarz'"
	errors=$((errors + 1))
fi

# Test: --help flag
output=$("$RARZ" --help 2>&1 || true)
if [[ "$output" != *"Usage"* ]]; then
	echo "FAIL: --help output missing 'Usage'"
	errors=$((errors + 1))
fi

# Test: unsupported command
if "$RARZ" z 2>/dev/null; then
	echo "FAIL: unsupported command should exit non-zero"
	errors=$((errors + 1))
fi

# Test: missing archive argument for test
if "$RARZ" t 2>/dev/null; then
	echo "FAIL: missing archive arg should exit non-zero"
	errors=$((errors + 1))
fi

# Test: missing archive argument for list
if "$RARZ" l 2>/dev/null; then
	echo "FAIL: missing archive arg for list should exit non-zero"
	errors=$((errors + 1))
fi

# Test: missing archive argument for extract
if "$RARZ" x 2>/dev/null; then
	echo "FAIL: missing archive arg for extract should exit non-zero"
	errors=$((errors + 1))
fi

# Test: nonexistent file
if "$RARZ" t /nonexistent/archive.rar 2>/dev/null; then
	echo "FAIL: nonexistent file should exit non-zero"
	errors=$((errors + 1))
fi

# Test: unsupported command stderr message
output=$("$RARZ" z 2>&1 || true)
if [[ "$output" != *"unsupported command: z"* ]]; then
	echo "FAIL: unsupported command should print error message"
	errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors tests"
	exit 1
fi

echo "PASS: test_basic.sh"
