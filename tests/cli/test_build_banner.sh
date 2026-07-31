#!/usr/bin/env bash
# `--about` surface + the DEBUG BUILD banner's gating.
#
# WHY THE BANNER ASSERTION IS A RELATION, NOT A CONSTANT
#   The obvious test — "a ReleaseSafe binary must not print DEBUG BUILD" — passes
#   vacuously if the banner is deleted outright, and it hard-codes the mode the
#   suite happens to build in. So instead we assert the INVARIANT:
#
#       banner present  <==>  --about reports a Debug build
#
#   That bites in both directions and in whatever mode the binary was built:
#   a ReleaseSafe build that warns fails, and a Debug build that stays silent
#   fails too. Deleting the banner cannot satisfy it.
#
#   The bug this pins: the banner was guarded by `#ifndef NDEBUG`, and Zig
#   defines NDEBUG only for ReleaseFast/ReleaseSmall — NOT for ReleaseSafe,
#   which is the fleet floor and what ./test builds. So every test run printed
#   "DEBUG BUILD" about a build that was not debug.
set -u

# Overridable so the Debug half of the invariant can be exercised against a
# separately-built binary without a second copy of this file.
RARZ="${RARZ:-zig-out/bin/rarz}"
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

echo "=== --about surface ==="

about_out=$("$RARZ" --about 2>/dev/null)
about_rc=$?

if [ "$about_rc" -ne 0 ]; then
	fail "--about should exit 0 (got $about_rc)"
else
	ok "--about exits 0"
fi

# Peter's CLI brief: --about is a ONE-LINE description carrying the app name,
# its version, and the platform/arch it was compiled for.
line_count=$(printf '%s\n' "$about_out" | grep -c .)
if [ "$line_count" -ne 1 ]; then
	fail "--about must be exactly one line (got $line_count)"
else
	ok "--about is one line"
fi

case "$about_out" in
	*rarz*) ok "--about names the app" ;;
	*)      fail "--about missing app name: '$about_out'" ;;
esac

if printf '%s' "$about_out" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
	ok "--about carries a semantic version"
else
	fail "--about missing a version: '$about_out'"
fi

# Architecture and OS. Compare against the host, since the suite runs natively.
host_arch=$(uname -m)
case "$host_arch" in
	arm64) host_arch="aarch64" ;;
	amd64) host_arch="x86_64" ;;
esac
if printf '%s' "$about_out" | grep -qi "$host_arch"; then
	ok "--about reports the architecture ($host_arch)"
else
	fail "--about missing architecture '$host_arch': '$about_out'"
fi

host_os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$host_os" in
	darwin) host_os="macos" ;;
esac
if printf '%s' "$about_out" | grep -qi "$host_os"; then
	ok "--about reports the OS ($host_os)"
else
	fail "--about missing OS '$host_os': '$about_out'"
fi

echo ""
echo "=== DEBUG BUILD banner is gated on the ACTUAL optimize mode ==="

# stdout and stderr captured separately: --about is output, the banner is
# metadata and belongs on stderr per the brief.
banner_err=$("$RARZ" --about 2>&1 >/dev/null)

if printf '%s' "$about_out" | grep -qi 'debug'; then
	# Debug build: the banner is REQUIRED. This is the half that stops the
	# test from being satisfiable by deleting the banner.
	if printf '%s' "$banner_err" | grep -q 'DEBUG BUILD'; then
		ok "Debug build warns on stderr"
	else
		fail "Debug build must print DEBUG BUILD to stderr"
	fi
else
	if printf '%s' "$banner_err" | grep -q 'DEBUG BUILD'; then
		fail "non-Debug build must NOT print DEBUG BUILD (mode: '$about_out')"
	else
		ok "non-Debug build stays silent"
	fi
fi

# The banner must never reach stdout — it would corrupt piped output.
about_stdout_only=$("$RARZ" --about 2>/dev/null)
if printf '%s' "$about_stdout_only" | grep -q 'DEBUG BUILD'; then
	fail "DEBUG BUILD leaked onto stdout"
else
	ok "banner never reaches stdout"
fi

# Peter's brief: suppressible via MUTE_DEBUG_STATUS, so suites that expect a
# clean stderr can silence it without giving up a debug build.
muted_err=$(MUTE_DEBUG_STATUS=1 "$RARZ" --about 2>&1 >/dev/null)
if printf '%s' "$muted_err" | grep -q 'DEBUG BUILD'; then
	fail "MUTE_DEBUG_STATUS=1 should suppress the banner"
else
	ok "MUTE_DEBUG_STATUS=1 suppresses the banner"
fi

echo ""
echo "Results: $pass passed, $errors failed"

if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors assertion(s)"
	exit 1
fi

echo "PASS: test_build_banner.sh"
