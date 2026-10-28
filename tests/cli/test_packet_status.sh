#!/usr/bin/env bash
# Real process signals and exit codes independently check the durable receipt.
set -u
source tests/support/capture.bash || exit 1
helper=$(realpath "${PACKET_STATUS_HELPER:-tests/support/packet-status.bash}")
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
errors=0
out='' err='' rc=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors + 1)); }

cat > "$scratch/packet" <<'PACKET'
#!/usr/bin/env bash
set -u
source "$1" || exit 1
packet_status_begin "$2" || exit 1
case "$3" in
	term) kill -TERM "$BASHPID" ;;
	int) kill -INT "$BASHPID" ;;
	nonzero) exit 7 ;;
	partial) printf 'first step only\n' > "$2/step.log"; exit 0 ;;
	missing) exit 0 ;;
	success) packet_status_complete || exit 1 ;;
	missing-marker) packet_status_complete || exit 1; rm "$2/packet.complete" ;;
	bad-marker) packet_status_complete || exit 1; printf 'partial\n' > "$2/packet.complete" ;;
	write-failure) packet_status_complete || exit 1; mkdir "$2/packet.exit" ;;
	term-after-complete) packet_status_complete || exit 1; kill -TERM "$BASHPID" ;;
	int-after-complete) packet_status_complete || exit 1; kill -INT "$BASHPID" ;;
	nonzero-after-complete) packet_status_complete || exit 1; exit 7 ;;
	term-during-receipt|int-during-receipt)
		packet_status_complete || exit 1
		receipt_signal=TERM
		[[ $3 != int-during-receipt ]] || receipt_signal=INT
		# Deliver a real signal immediately after the status write boundary.
		printf() {
			unset -f printf
			builtin printf "$@"
			kill -s "$receipt_signal" "$BASHPID"
		}
		;;
esac
PACKET

while read -r mode expected; do
	receipt="$scratch/$mode"
	mkdir "$receipt" || exit 1
	# capture uses asynchronous subshells, which can inherit ignored SIGINT.
	# Reset the child's OS disposition so these are real signal-delivery tests.
	capture env --default-signal=INT --default-signal=TERM bash "$scratch/packet" "$helper" "$receipt" "$mode"
	[[ $rc == "$expected" ]] || fail "$mode process exit $rc, expected $expected"
	actual=missing
	[[ ! -f $receipt/packet.exit ]] || actual=$(< "$receipt/packet.exit")
	[[ $actual == "$expected" ]] || fail "$mode receipt $actual, expected $expected"
done <<'CASES'
term 143
int 130
nonzero 7
partial 1
missing 1
success 0
missing-marker 1
bad-marker 1
term-after-complete 143
int-after-complete 130
nonzero-after-complete 7
term-during-receipt 143
int-during-receipt 130
CASES

# An old success receipt must neither authorize a new run nor be overwritten.
receipt="$scratch/stale"
mkdir "$receipt" || exit 1
printf '0\n' > "$receipt/packet.exit"
printf 'complete\n' > "$receipt/packet.complete"
capture env --default-signal=INT --default-signal=TERM bash "$scratch/packet" "$helper" "$receipt" nonzero
[[ $rc != 0 && $(< "$receipt/packet.exit") == 0 ]] || fail 'receipt reuse must fail without overwriting historical evidence'

for signal in INT TERM; do
	receipt="$scratch/ignored-$signal"
	mkdir "$receipt" || exit 1
	capture env --ignore-signal="$signal" bash "$scratch/packet" "$helper" "$receipt" success
	[[ $rc != 0 && ! -e $receipt/packet.exit ]] || fail "ignored $signal must refuse initialization before work"
done

receipt="$scratch/write-failure"
mkdir "$receipt" || exit 1
capture env --default-signal=INT --default-signal=TERM bash "$scratch/packet" "$helper" "$receipt" write-failure
[[ $rc != 0 && ! -f $receipt/packet.exit ]] || fail 'receipt write failure must fail the process'

receipt="$scratch/claimed"
mkdir -p "$receipt/.packet-status" || exit 1
capture env --default-signal=INT --default-signal=TERM bash "$scratch/packet" "$helper" "$receipt" success
[[ $rc != 0 && ! -e $receipt/packet.exit ]] || fail 'a claimed receipt directory must refuse another writer'

[[ $errors == 0 ]] || exit 1
printf 'PASS: packet signals, exits, completion evidence, and historical receipt preservation\n'
