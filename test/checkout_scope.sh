#!/usr/bin/env bash
# Regression: Checkout badges appear only for branch-bearing open PRs in the
# focused repo (fixture: acme/widgets), never for other repos (acme/gadgets).
# Usage: bash test/checkout_scope.sh
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fx="$root/test/fixtures"
focus="acme/widgets"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/graphite-checkout.XXXXXX")
sock="$tmp/ctl.sock"
daemon_socket="$tmp/daemon.sock"
log="$tmp/tern.log"
state="$tmp/state"
pid=""
daemon_pid=""
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$state"
plugin_dir=$(tern plugin dir) || exit 1
linked="$plugin_dir/graphite.path"
if [ ! -f "$linked" ] || [ "$(cat "$linked")" != "$root" ]; then
	echo "FAIL: graphite is not linked to this checkout ($root)"
	echo "Link it with: tern plugin link \"$root\""
	exit 1
fi

cleanup() {
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		tern ctl --control "$sock" quit >/dev/null 2>&1
		for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
		kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
		wait "$pid" 2>/dev/null
	fi
	if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
		kill "$daemon_pid" 2>/dev/null
		for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$daemon_pid" 2>/dev/null || break; sleep 0.3; done
		kill -0 "$daemon_pid" 2>/dev/null && kill -9 "$daemon_pid" 2>/dev/null
		wait "$daemon_pid" 2>/dev/null
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Effective PR state mirrors the detail override in the renderer; a branch is
# required for Checkout to exist. The fixture daemon below has empty hidden_sections.
rows=$(jq -r --slurpfile info "$fx/pull_request_info.json" '
	[
		.sections[].prs[] as $pr
		| ($info[0][$pr.repo.owner + "/" + $pr.repo.name].result.prs[]?
			| select(.prNumber == $pr.number)) as $detail
		| (if $detail.state == "OPEN" or $detail.state == "MERGED" or $detail.state == "CLOSED"
			then $detail.state else $pr.state end) as $effective
		| select($effective == "OPEN" and ($detail.headRefName // "") != "")
		| $pr.repo.owner + "/" + $pr.repo.name
	]
	| .[]' "$fx/sections_summary.json") || { echo "FAIL: jq could not derive expectations"; exit 1; }
expect_match=$(printf '%s\n' "$rows" | grep -c -x "$focus")
expect_other=$(printf '%s\n' "$rows" | grep -v -x "$focus" | grep -c .)
expect_total=$((expect_match + expect_other))
if [ "$expect_match" -lt 1 ] || [ "$expect_other" -lt 1 ]; then
	echo "FAIL: fixtures must hold both matching ($expect_match) and non-matching ($expect_other) branch-bearing open PRs"
	exit 1
fi

# SHOW_CHECKOUT=false seeds show_checkout_button=false and expects no Checkout
# badges at all. SEND_MODE=pane seeds send_mode=pane and expects the
# "Send to agent" label; the default (clipboard) renders "Copy prompt".
show_checkout="${SHOW_CHECKOUT:-true}"
send_mode="${SEND_MODE:-clipboard}"
send_label="Copy prompt"
[ "$send_mode" = "pane" ] && send_label="Send to agent"
# SHOW_DIFF=false seeds show_diff_button=false and expects no Diff badges; the
# default expects one Diff badge per rendered open PR (no branch/repo condition).
show_diff="${SHOW_DIFF:-true}"
[ "$show_checkout" = "false" ] && expect_match=0
mkdir -p "$state/tern/plugin-data/graphite"
jq -n --argjson c "$show_checkout" --argjson d "$show_diff" --arg m "$send_mode" '{show_checkout_button: $c, show_diff_button: $d, send_mode: $m}' \
	>"$state/tern/plugin-data/graphite/config.json" || { echo "FAIL: could not seed config.json"; exit 1; }

# Use a fresh daemon so the test loads the linked checkout's current code, and
# an isolated state dir so user hidden_sections/config cannot affect the oracle.
TERN_DAEMON_SOCKET="$daemon_socket" XDG_STATE_HOME="$state" \
	tern daemon --socket "$daemon_socket" >"$log" 2>&1 &
daemon_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[ -S "$daemon_socket" ] && break
	if ! kill -0 "$daemon_pid" 2>/dev/null; then
		echo "FAIL: isolated Tern daemon exited during startup"
		cat "$log"
		exit 1
	fi
	sleep 0.3
done
if [ ! -S "$daemon_socket" ]; then
	echo "FAIL: isolated Tern daemon did not create its socket"
	cat "$log"
	exit 1
fi
(
	cd "$root"
	TERN_DAEMON_SOCKET="$daemon_socket" XDG_STATE_HOME="$state" GRAPHITE_AUTOOPEN=fixture \
		exec tern --control "$sock" .
) >>"$log" 2>&1 &
pid=$!

a11y=""; sends=0; checkouts=0
for _ in $(seq 1 60); do
	kill -0 "$pid" 2>/dev/null || break
	if a11y=$(tern ctl --control "$sock" a11y 2>/dev/null); then
		sends=$(printf '%s\n' "$a11y" | jq --arg l "$send_label" '[.. | strings | select(. == $l)] | length' 2>/dev/null)
		[ "$sends" -ge "$expect_total" ] && break
	fi
	sleep 0.5
done
checkouts=$(printf '%s\n' "$a11y" | jq '[.. | strings | select(. == "Checkout")] | length' 2>/dev/null)
diffs=$(printf '%s\n' "$a11y" | jq '[.. | strings | select(. == "Diff")] | length' 2>/dev/null)
expect_diff=$sends
[ "$show_diff" = "false" ] && expect_diff=0

if [ "$sends" -lt "$expect_total" ]; then
	echo "FAIL: fixture did not render ($send_label rows: $sends, expected >= $expect_total)"
	echo "--- tern log ---"; cat "$log"
	echo "--- a11y ---"; printf '%s\n' "$a11y"
	exit 1
fi
if [ "$checkouts" -ne "$expect_match" ]; then
	echo "FAIL: Checkout badges=$checkouts, expected $expect_match (show_checkout_button=$show_checkout, matching $focus, non-matching=$expect_other)"
	echo "--- a11y ---"; printf '%s\n' "$a11y"
	exit 1
fi
if [ "$diffs" -ne "$expect_diff" ]; then
	echo "FAIL: Diff badges=$diffs, expected $expect_diff (show_diff_button=$show_diff, $send_label badges=$sends)"
	echo "--- a11y ---"; printf '%s\n' "$a11y"
	exit 1
fi
echo "PASS: Diff badges=$diffs == $expect_diff (show_diff_button=$show_diff); Checkout badges=$checkouts == $expect_match (show_checkout_button=$show_checkout); $send_label badges=$sends (send_mode=$send_mode); non-matching branch-bearing open PRs=$expect_other"
