#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEEPER="$PROJECT_ROOT/bin/tailnet-keeper"
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-mullvad.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/state" "$SANDBOX/run"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Mullvad writes `null` for unset options, which is why this file cannot be
# read through plutil like every other parse in the project.
settings() {
    local state=$1 ads=$2 trackers=$3 malware=$4 adult=$5 gambling=$6 social=$7 extra=${8:-}
    cat <<JSON
{
  "tunnel_options": {
    "wireguard": { "mtu": null, "rotation_interval": null },
    "dns_options": {
      "state": "$state",
      "default_options": {
        "block_ads": $ads,
        "block_trackers": $trackers,
        "block_malware": $malware,
        "block_adult_content": $adult,
        "block_gambling": $gambling,
        "block_social_media": $social$extra
      },
      "custom_options": { "addresses": [] }
    }
  }
}
JSON
}

block_for() {
    TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
    TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
    TAILNET_KEEPER_MULLVAD_SETTINGS="$1" \
    bash -c 'set -uo pipefail; source "$1"; mullvad_blocklist_block' _ "$KEEPER"
}

# `cmd && fail` leaves the assertion resting on $? surviving the list, which
# reads as an accident. The status is captured where it is produced.
expect_status() {
    local expected=$1 file=$2 message=$3 status=0
    block_for "$file" >/dev/null || status=$?
    [ "$status" -eq "$expected" ] || fail "$message (exit $status)"
}

# One bit per list, so the block the resolver can land in is sized from the
# lists the settings declare, not from a table of the ones known when this was
# written. Six lists is today's shape; the others are what a release that adds
# one has to keep working through.
settings default true true true false true false >"$SANDBOX/six.json"
[ "$(block_for "$SANDBOX/six.json")" = '100.64.0.0/26 64' ] ||
    fail "six lists sized the block as '$(block_for "$SANDBOX/six.json")', expected 100.64.0.0/26 64"

settings default true false false false false false ',
        "block_web3": false' >"$SANDBOX/seven.json"
[ "$(block_for "$SANDBOX/seven.json")" = '100.64.0.0/25 128' ] ||
    fail "a seventh list did not widen the block by one bit"

settings default true false false false false false ',
        "block_web3": false,
        "block_AI": false' >"$SANDBOX/eight.json"
[ "$(block_for "$SANDBOX/eight.json")" = '100.64.0.0/24 256' ] ||
    fail "an eighth list did not widen the block by one bit"

# Which lists are on decides only whether the resolver moves at all: the route
# covers wherever inside the block it lands, so any single list gives the same
# block as all six.
for probe in "true false false false false false" \
             "false false false false false true" \
             "true true true true true true"; do
    read -r ads trackers malware adult gambling social <<<"$probe"
    settings default "$ads" "$trackers" "$malware" "$adult" "$gambling" "$social" >"$SANDBOX/any.json"
    [ "$(block_for "$SANDBOX/any.json")" = '100.64.0.0/26 64' ] ||
        fail "enabled lists [$probe] changed the block, which covers all of them"
done

# The keys are matched as tokens, not by line, so a file Mullvad writes
# without pretty-printing reads the same.
/usr/bin/awk '{ printf "%s", $0 }' <(settings default true true true false true false) >"$SANDBOX/min.json"
[ "$(block_for "$SANDBOX/min.json")" = '100.64.0.0/26 64' ] ||
    fail 'a minified settings file did not read the same as a formatted one'

# Custom DNS replaces the blocking resolver, and no list enabled leaves the
# tunnel's own resolver in place. Both mean there is nothing to route, which
# is not the same as a file that could not be read.
settings custom true true true false true false >"$SANDBOX/custom.json"
expect_status 1 "$SANDBOX/custom.json" 'custom DNS did not report "nothing to route"'
settings default false false false false false false >"$SANDBOX/none.json"
expect_status 1 "$SANDBOX/none.json" 'an empty blocklist did not report "nothing to route"'
expect_status 1 "$SANDBOX/absent.json" 'a missing Mullvad install was read as broken settings'

# Past the ceiling the route would cover tailnet space plausibly in use, and a
# file claiming that many lists is one this reader no longer understands.
settings default true false false false false false ',
        "block_a": false,
        "block_b": false,
        "block_c": false' >"$SANDBOX/nine.json"
expect_status 2 "$SANDBOX/nine.json" 'a ninth list was sized rather than refused'

# A key appearing twice means the shape changed under an assumption this parse
# depends on, so it refuses rather than read whichever copy came first.
settings default true false false false false false ',
        "block_ads": false' >"$SANDBOX/dup.json"
expect_status 2 "$SANDBOX/dup.json" 'a duplicated key was not refused'

# A list somebody names `block_foo` is a value, not a declared list.
settings default true true true false true false >"$SANDBOX/named.json"
python3 - "$SANDBOX/named.json" <<'DECOY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["custom_lists"] = {"lists": [{"name": "block_foo", "id": "x"}]}
json.dump(document, open(path, "w"), indent=2)
DECOY
[ "$(block_for "$SANDBOX/named.json")" = '100.64.0.0/26 64' ] ||
    fail 'a custom list named like a blocklist was counted as one'

# A name is JSON, so it can hold an escaped quote. The key match stops at a
# backslash as well as at a quote, or a value somebody typed forges a list and
# the keeper withdraws the route over their choice of name.
settings default true true true false true false >"$SANDBOX/escaped.json"
python3 - "$SANDBOX/escaped.json" <<'DECOY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["custom_lists"] = {"lists": [{"name": 'see "block_zzz": true', "id": "x"}]}
json.dump(document, open(path, "w"), indent=2)
DECOY
[ "$(block_for "$SANDBOX/escaped.json")" = '100.64.0.0/26 64' ] ||
    fail 'an escaped quote in a list name forged a blocklist key'

# The kernel consults a scoped default only for a socket bound to its
# interface, and Mullvad's resolver binds none: the unscoped default is the
# path its query actually takes.
selected=$(TAILNET_KEEPER_TESTING=1 bash -c '
    set -uo pipefail
    source "$1"
    find_unscoped_default_interface <<TABLE
default            192.168.100.1      UGdScIg               en0
default            link#21            UCSIg               utun6
default            utun7              UGdScg              utun7
default            link#24            UCSIg           bridge100      !
TABLE
' _ "$KEEPER")
[ "$selected" = utun7 ] ||
    fail "unscoped default resolved to '$selected' rather than the VPN tunnel"

# A node inside the block is found; one past its last address is not, so a
# wider block is what puts a node in reach and no narrower one does.
peer_probe() {
    local size=$1 peers=$2
    printf '%s\n' "$peers" >"$SANDBOX/peers.fixture"
    TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
    TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
    bash -c '
        set -uo pipefail
        source "$1"
        validate_tailscale_cli() { return 0; }
        run_with_timeout() { /bin/cat "'"$SANDBOX/peers.fixture"'" >"$2"; return 0; }
        tailnet_peer_inside_block '"$size"'
    ' _ "$KEEPER"
}
peer_probe 64 '100.64.0.23  rack  a@  linux  -' ||
    fail 'a node inside the block was not found'
peer_probe 64 '100.64.0.64  rack  a@  linux  -' &&
    fail 'a node one past the block was treated as inside it'
peer_probe 128 '100.64.0.64  rack  a@  linux  -' ||
    fail 'widening the block did not bring a node into reach'
peer_probe 64 '100.123.186.98  macbook  a@  macOS  -' &&
    fail 'an ordinary tailnet node was treated as inside the block'

# The relay bookkeeping identifies a stale relay by exclusion, so a resolver
# route in the journal was read as one: routes_complete went false on every
# run, the DERP refresh deleted the route, and this module put it back. The
# route flapped once per run and the signature-verifying node check ran with
# it. A failed retirement took the whole keeper into fail_safely, which is the
# teardown a DNS fault must never cause.
printf '%s\n' \
    '192.200.0.0/24|-inet|192.168.0.1|en0|-|-|normal' \
    '199.165.136.0/24|-inet|192.168.0.1|en0|-|-|normal' \
    '5.161.218.233|-inet|192.168.0.1|en0|-|-|normal' \
    '203.0.113.9|-inet|192.168.0.1|en0|-|-|normal' \
    '100.64.0.0/26|-inet|interface#utun7|utun7|-|-|-' >"$SANDBOX/state/routes"
printf '5.161.218.233\n' >"$SANDBOX/state/derp-ipv4"
: >"$SANDBOX/state/derp-ipv6"
stale=$(TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
    TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
    bash -c '
        set -uo pipefail
        source "$1"
        physical_ipv6_gateway=
        journaled_relays_not_in "$DERP_CACHE" /dev/null
    ' _ "$KEEPER")
[ "$stale" = 203.0.113.9 ] ||
    fail "stale relays resolved to '$stale'; the resolver route is not a relay and a real stray still is"

grep -v '203\.0\.113\.9' "$SANDBOX/state/routes" >"$SANDBOX/routes.trimmed"
cp "$SANDBOX/routes.trimmed" "$SANDBOX/state/routes"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -uo pipefail
    source "$1"
    physical_ipv6_gateway=
    journal_owns_only_desired
' _ "$KEEPER" ||
    fail 'a journaled resolver route made the relay set look incomplete'

# Widening the block moves the route, and the prefix it was placed under has
# to be withdrawn before the new one goes in.
settings default true true true false true false >"$SANDBOX/s.json"
printf '%s\n' \
    '100.64.0.0/25|-inet|interface#utun7|utun7|-|-|-' \
    '203.0.113.9|-inet|192.168.0.1|en0|-|-|normal' >"$SANDBOX/state/routes"
outcome=$(TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
    TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
    TAILNET_KEEPER_MULLVAD_SETTINGS="$SANDBOX/s.json" \
    bash -c '
        set -uo pipefail
        source "$1"
        physical_interface=en0
        tailscale_interface=utun6
        find_unscoped_default_interface() { printf "utun7\n"; }
        route_matches() { return 1; }
        tailnet_peer_inside_block() { return 1; }
        retired=
        retire_owned_route() { retired="$retired $1"; return 0; }
        ensure_owned_route() { printf "placed %s via %s\n" "$2" "$4"; return 0; }
        reconcile_mullvad_dns_route
        printf "retired:%s\n" "$retired"
    ' _ "$KEEPER")
grep -q 'placed 100.64.0.0/26 via utun7' <<<"$outcome" ||
    fail "the current block was not routed into the tunnel: $outcome"
grep -q 'retired: 100.64.0.0/25' <<<"$outcome" ||
    fail "the prefix the route was placed under was not withdrawn: $outcome"
if grep -q '203.0.113.9' <<<"$outcome"; then
    fail 'retirement reached a route outside the resolver network'
fi

# Settings that cannot be read leave the block unknown, so a route placed
# under an earlier reading is withdrawn rather than left covering tailnet
# addresses while health reports nothing routed.
settings default true false false false false false ',
        "block_a": false,
        "block_b": false,
        "block_c": false' >"$SANDBOX/nine.json"
printf '%s\n' '100.64.0.0/26|-inet|interface#utun7|utun7|-|-|-' >"$SANDBOX/state/routes"
set +e
outcome=$(TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
    TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
    TAILNET_KEEPER_MULLVAD_SETTINGS="$SANDBOX/nine.json" \
    bash -c '
        set -uo pipefail
        source "$1"
        physical_interface=en0
        tailscale_interface=utun6
        retire_owned_route() { printf "retired %s\n" "$1"; return 0; }
        ensure_owned_route() { printf "PLACED\n"; return 0; }
        reconcile_mullvad_dns_route
        printf "status=%s route=[%s]\n" "$?" "$mullvad_dns_route"
    ' _ "$KEEPER")
set -e
grep -q 'retired 100.64.0.0/26' <<<"$outcome" ||
    fail "unreadable settings left an earlier route in place: $outcome"
grep -q 'status=2 route=\[\]' <<<"$outcome" ||
    fail "unreadable settings did not report an empty route: $outcome"

# A route that rolled back is not a route, so the field must not describe it.
settings default true true true false true false >"$SANDBOX/s.json"
: >"$SANDBOX/state/routes"
set +e
outcome=$(TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
    TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
    TAILNET_KEEPER_MULLVAD_SETTINGS="$SANDBOX/s.json" \
    bash -c '
        set -uo pipefail
        source "$1"
        physical_interface=en0
        tailscale_interface=utun6
        find_unscoped_default_interface() { printf "utun7\n"; }
        route_matches() { return 1; }
        retire_owned_route() { return 0; }
        tailnet_peer_inside_block() { return 1; }
        ensure_owned_route() { return 1; }
        reconcile_mullvad_dns_route
        printf "status=%s route=[%s]\n" "$?" "$mullvad_dns_route"
    ' _ "$KEEPER")
set -e
grep -q 'status=1 route=\[\]' <<<"$outcome" ||
    fail "a rolled-back route was still reported in health: $outcome"

# Tailscale assigns from the same /10, so a node can land inside the block.
# Routing over it would take that node off the tailnet: the overlap is named,
# and an unanswered check is a different finding with its own code. Either
# way the block is not left routed.
printf '%s\n' '100.64.0.0/26|-inet|interface#utun7|utun7|-|-|-' >"$SANDBOX/state/routes"
for probe in "0 3" "2 4"; do
    read -r node_status expected_status <<<"$probe"
    set +e
    TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
    TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
    TAILNET_KEEPER_MULLVAD_SETTINGS="$SANDBOX/s.json" \
    bash -c '
        set -uo pipefail
        source "$1"
        physical_interface=en0
        tailscale_interface=utun6
        find_unscoped_default_interface() { printf "utun7\n"; }
        route_matches() { return 1; }
        retire_owned_route() { printf "retired %s\n" "$1"; return 0; }
        tailnet_peer_inside_block() { return '"$node_status"'; }
        ensure_owned_route() { printf "PLACED\n"; return 0; }
        reconcile_mullvad_dns_route
    ' _ "$KEEPER" >"$SANDBOX/collision" 2>&1
    actual_status=$?
    set -e
    [ "$actual_status" -eq "$expected_status" ] ||
        fail "node check $node_status reported $actual_status, expected $expected_status"
    if grep -q PLACED "$SANDBOX/collision"; then
        fail "a route was placed despite node check $node_status"
    fi
    grep -q 'retired 100.64.0.0/26' "$SANDBOX/collision" ||
        fail "node check $node_status left the route for the current block in place"
done

printf 'mullvad_dns=PASS\n'
