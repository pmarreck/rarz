#!/usr/bin/env bash
# Test-only classification of the existing `rarz t` process contract.
source "$(dirname "${BASH_SOURCE[0]}")/capture.bash" || return 1

# Pure: a complete recorded exit status and stdout produce one classification.
# `valid` is the command's archive verdict, not a claim to decrypt its entries.
classify_rarz_test() {
	local status=$1 output=$2 line verdict='' count=0
	while IFS= read -r line; do
		line=${line%$'\r'}
		case "$line" in
			Validation:*) verdict=${line#'Validation: '}; count=$((count + 1)) ;;
		esac
	done <<< "$output"
	if [[ $count != 1 ]]; then
		printf 'tool-error\n'
		return
	fi
	case "$status:$verdict" in
		0:VALID) printf 'valid\n' ;;
		1:INVALID) printf 'damaged\n' ;;
		69:UNVERIFIABLE) printf 'unverifiable\n' ;;
		*) printf 'tool-error\n' ;;
	esac
}

# UNRAR's checksum-error status is 3. Version 7.20 also reports truncated
# service blocks with warning status 1 and an explicit end-of-archive error.
# Corrupt archive-comment payloads can return 0 with an explicit diagnostic.
# Generic warnings, fatal errors, unavailable input and timeouts are inconclusive.
classify_unrar_test() {
	local status=$1 diagnostic=${2-} line truncated=0 corrupt_comment=0
	while IFS= read -r line; do
		line=${line%$'\r'}
		[[ $line == 'Unexpected end of archive' ]] && truncated=1
		[[ $line == 'The archive comment is corrupt' ]] && corrupt_comment=1
	done <<< "$diagnostic"
	if [[ $status == 0 && $corrupt_comment == 1 ]]; then printf 'damaged\n'; return; fi
	case "$status:$truncated" in
		0:0) printf 'valid\n' ;;
		3:*|1:1) printf 'damaged\n' ;;
		*) printf 'tool-error\n' ;;
	esac
}

# Retain the older gates' allowance for stricter structural validation, but
# distinguish it from confirmed checksum detection and never agree on errors.
classify_mutation_pair() {
	case "$1:$2" in
		valid:valid) printf 'benign\n' ;;
		valid:damaged) printf 'stricter\n' ;;
		damaged:valid) printf 'missed\n' ;;
		damaged:damaged) printf 'detected\n' ;;
		*) printf 'inconclusive\n' ;;
	esac
}

# Real adapter. Keep all process observations available for assertion failures;
# stderr must never be mistaken for the stdout verdict protocol.
observe_rarz_test() {
	local executable=$1 archive=$2 out='' err='' rc=125
	capture timeout 60 "$executable" t "$archive"
	rarz_t_stdout=$out
	rarz_t_stderr=$err
	rarz_t_status=$rc
	rarz_t_class=$(classify_rarz_test "$rc" "$out")
}

observe_unrar_test() {
	local archive=$1 out='' err='' rc=125
	capture timeout 60 unrar t "$archive"
	unrar_t_stdout=$out
	unrar_t_stderr=$err
	unrar_t_status=$rc
	unrar_t_class=$(classify_unrar_test "$rc" "$err")
}

# Pure set check over newline-delimited fixture identities. Extra available
# fixtures are harmless; an empty required set or a missing member is not.
classify_required_fixture_set() {
	local required=$1 present=$2 path any=0
	while IFS= read -r path; do
		[[ -n $path ]] || continue
		any=1
		case $'\n'"$present"$'\n' in
			*$'\n'"$path"$'\n'*) ;;
			*) printf 'incomplete\n'; return ;;
		esac
	done <<< "$required"
	if [[ $any == 1 ]]; then printf 'complete\n'; else printf 'incomplete\n'; fi
}

# Pure: exact case accounting plus a separately declared, nonempty set of
# known must-detect controls. Benign random trials never satisfy that set.
classify_required_trials() {
	if [[ $1 =~ ^[1-9][0-9]*$ && $2 == "$1" && $3 =~ ^[1-9][0-9]*$ && $4 == "$3" ]]; then
		printf 'complete\n'
	else
		printf 'incomplete\n'
	fi
}

require_fixture_paths() {
	local required='' present='' path
	for path in "$@"; do
		required+="$path"$'\n'
		if [[ -f $path ]]; then present+="$path"$'\n'; fi
	done
	if [[ $(classify_required_fixture_set "$required" "$present") == complete ]]; then return 0; fi
	printf 'INCOMPLETE: required fixture set is empty or has unavailable files\n'
	return 1
}
