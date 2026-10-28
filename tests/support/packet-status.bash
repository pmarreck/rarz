# Source in a dedicated acceptance script. Call begin before any work and
# complete only after every required step and identity check has succeeded.
# The script owns its EXIT/TERM/INT traps; callers must not replace them.
packet_status_begin() {
	# Bash cannot install a handler for signals ignored when it was launched.
	# Start it with default INT/TERM dispositions rather than accepting a
	# receipt from a process that cannot honor interruption.
	[[ $(trap -p INT) != "trap -- '' SIGINT" ]] || return 1
	[[ $(trap -p TERM) != "trap -- '' SIGTERM" ]] || return 1
	_packet_receipt=$1
	_packet_completed=0
	[[ -d $_packet_receipt ]] || return 1
	[[ ! -e $_packet_receipt/packet.exit && ! -e $_packet_receipt/packet.complete ]] || return 1
	# Atomic claim prevents concurrent writers and accidental directory reuse.
	mkdir "$_packet_receipt/.packet-status" || return 1
	# Signals must update the receipt even while the EXIT finalizer is writing.
	trap '_packet_status_finish 143' TERM
	trap '_packet_status_finish 130' INT
	trap '_packet_status_finish "$?"' EXIT
}

packet_status_complete() {
	printf 'complete\n' > "$_packet_receipt/packet.complete" || return 1
	_packet_completed=1
}

_packet_status_finish() {
	local code=$1
	trap - EXIT
	if (( code == 0 )); then
		if [[ $_packet_completed != 1 || ! -f $_packet_receipt/packet.complete ]]; then
			code=1
		elif [[ $(< "$_packet_receipt/packet.complete") != complete ]]; then
			code=1
		fi
	fi
	printf '%s\n' "$code" > "$_packet_receipt/packet.exit" || code=1
	exit "$code"
}
