#!/usr/bin/env bash
# Preserve legacy operators through corruption-reader's versioned consumer API.
# Call only inside the suite's filesystem boundary with a test-owned target.
legacy_mutate() (
	local source=$1 target=$2 operator=$3 parameter=$4 value=${5:-0}
	local size profile scratch mask out='' err='' rc=0 input_hash mutant_hash
	[[ -f $source && ! -L $target && ! $source -ef $target ]] || return 2
	[[ $parameter =~ ^(0|[1-9][0-9]{0,14})$ && $value =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 2
	size=$(wc -c < "$source") || return 2
	case $operator in
		overwrite-byte-v1|xor-byte-v1)
			((parameter<size && value<=255)) || return 2
			printf -v mask '%02x' "$value"
			profile=$(jq -cn --arg name "rarz-legacy-$operator" --argjson offset "$parameter" --arg mask "$mask" --arg op "$operator" '
				{profile:1,name:$name,root:{zone:{kind:"range",unit:"bytes",start:$offset,length:1},do:(if $op=="overwrite-byte-v1" then [{op:"zero_out"},{op:"xor",mask:$mask}] else {op:"xor",mask:$mask} end)}}') || return 2 ;;
		drop-suffix-v1)
			((parameter>0 && parameter<size)) || return 2
			profile=$(jq -cn --arg name "rarz-legacy-$operator" --argjson length "$parameter" '
				{profile:1,name:$name,root:{zone:{kind:"range",unit:"bytes",start:0,anchor:"end",length:$length},do:{op:"delete"}}}') || return 2 ;;
		*) return 2 ;;
	esac
	scratch=$(mktemp -d) || return 1
	trap 'rm -rf "$scratch"' EXIT
	printf '%s\n' "$profile" > "$scratch/profile.json" || return 1
	input_hash=$(sha256sum "$source") || return 1; input_hash=${input_hash%% *}
	capture timeout 600 corruption-reader corrupt "$scratch/profile.json" --master 0 --round 0 --report "$scratch/report.jsonl" -o "$target" "$source"
	[[ $rc == 0 ]] || { printf 'legacy mutation failed (exit %s): %s\n' "$rc" "$err" >&2; return 1; }
	mutant_hash=$(sha256sum "$target") || return 1; mutant_hash=${mutant_hash%% *}
	jq -ce --arg operator "$operator" --arg input "$input_hash" --arg mutant "$mutant_hash" '
		select(.report==1 and .emitted==true and .status=="applied") |
		{schema:"rarz-legacy-mutation/v1",operator:$operator,input_sha256:$input,mutant_sha256:$mutant,unchanged:($input==$mutant),record:.record}' "$scratch/report.jsonl"
)
