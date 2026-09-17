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

# `cmd && fail` leaves the assertion resting on $? surviving the list, which
# reads as an accident. The status is captured where it is produced.
expect_status() {
    local expected=$1 file=$2 message=$3 status=0
    address_for "$file" >/dev/null || status=$?
    [ "$status" -eq "$expected" ] || fail "$message (exit $status)"
}

address_for() {
    TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
    TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
    TAILNET_KEEPER_MULLVAD_SETTINGS="$1" \
    bash -c 'set -uo pipefail; source "$1"; mullvad_blocklist_address' _ "$KEEPER"
}

# Every bit was confirmed against the address the daemon queries with only
# that list on; the sum is what a mixed selection has to reproduce.
for probe in "1 true false false false false false" \
             "2 false true false false false false" \
             "4 false false true false false false" \
             "8 false false false true false false" \
             "16 false false false false true false" \
             "32 false false false false false true" \
             "23 true true true false true false" \
             "63 true true true true true true"; do
    read -r expected ads trackers malware adult gambling social <<<"$probe"
    settings default "$ads" "$trackers" "$malware" "$adult" "$gambling" "$social" >"$SANDBOX/s.json"
    actual=$(address_for "$SANDBOX/s.json") ||
        fail "blocklist sum $expected was not computed"
    [ "$actual" = "100.64.0.$expected" ] ||
        fail "blocklist sum expected 100.64.0.$expected, got $actual"
done

# The keys are matched as tokens, not by line, so a file Mullvad writes
# without pretty-printing reads the same.
/usr/bin/awk '{ printf "%s", $0 }' <(settings default true true true false true false) >"$SANDBOX/min.json"
[ "$(address_for "$SANDBOX/min.json")" = 100.64.0.23 ] ||
    fail 'a minified settings file did not read the same as a formatted one'

# Custom DNS replaces the blocking resolver, and no list enabled leaves the
# tunnel's own resolver in place. Both mean there is no address to rescue,
# which is not the same as a file that could not be read.
settings custom true true true false true false >"$SANDBOX/custom.json"
expect_status 1 "$SANDBOX/custom.json" 'custom DNS did not report "nothing to route"'

settings default false false false false false false >"$SANDBOX/none.json"
expect_status 1 "$SANDBOX/none.json" 'an empty blocklist did not report "nothing to route"'

# A list this bit table does not name means the sum would silently omit it.
settings default true false false false false false ',
        "block_crypto": true' >"$SANDBOX/seventh.json"
expect_status 2 "$SANDBOX/seventh.json" 'an unknown blocklist was not refused'

# The guard has to see a key by any name, not one spelled the way the six
# known lists happen to be. A key it misses is a list the sum omits, and the
# address is then routed with healthy health -- the outcome the guard exists
# to prevent.
for decoy in 'block_web3' 'block_AI' 'block_ads2'; do
    settings default true false false false false false ",
        \"$decoy\": true" >"$SANDBOX/named-list.json"
    expect_status 2 "$SANDBOX/named-list.json" "a blocklist named $decoy was not refused"
done

# A key appearing twice means the shape changed under the assumption this
# parse depends on, so it refuses rather than read whichever copy came first.
settings default true false false false false false ',
        "block_ads": false' >"$SANDBOX/dup.json"
expect_status 2 "$SANDBOX/dup.json" 'a duplicated key was not refused'
expect_status 1 "$SANDBOX/absent.json" 'a missing Mullvad install was read as broken settings'

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

# Toggling a list moves the resolver address, and the route placed under the
# old one has to be withdrawn before the new one goes in.
settings default true true true false true false >"$SANDBOX/s.json"
printf '%s\n' \
    '100.64.0.7|-inet|interface#utun7|utun7|-|-|normal' \
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
        tailnet_peer_holds_address() { return 1; }
        retired=
        retire_owned_route() { retired="$retired $1"; return 0; }
        ensure_owned_route() { printf "placed %s via %s\n" "$2" "$4"; return 0; }
        reconcile_mullvad_dns_route
        printf "retired:%s\n" "$retired"
    ' _ "$KEEPER")
grep -q 'placed 100.64.0.23 via utun7' <<<"$outcome" ||
    fail "the current resolver address was not routed into the tunnel: $outcome"
grep -q 'retired: 100.64.0.7' <<<"$outcome" ||
    fail "the address the route was placed under was not withdrawn: $outcome"
if grep -q '203.0.113.9' <<<"$outcome"; then
    fail 'retirement reached a route outside the resolver network'
fi

# Tailscale assigns from the same /10, so the two can land on one address.
# Routing it would take that peer off the tailnet: the collision is named,
# and an unanswered check is a different finding with its own code.
printf '%s\n' '100.64.0.23|-inet|interface#utun7|utun7|-|-|-' >"$SANDBOX/state/routes"
for probe in "0 3" "2 4"; do
    read -r peer_status expected_status <<<"$probe"
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
        tailnet_peer_holds_address() { return '"$peer_status"'; }
        ensure_owned_route() { printf "PLACED\n"; return 0; }
        reconcile_mullvad_dns_route
    ' _ "$KEEPER" >"$SANDBOX/collision" 2>&1
    actual_status=$?
    set -e
    [ "$actual_status" -eq "$expected_status" ] ||
        fail "peer check $peer_status reported $actual_status, expected $expected_status"
    if grep -q PLACED "$SANDBOX/collision"; then
        fail "a route was placed despite peer check $peer_status"
    fi
    # The tunnel an earlier run pointed this address into may since have
    # changed, and a peer holding it needs the table clear, so the route is
    # withdrawn rather than left because the address still matches.
    grep -q 'retired 100.64.0.23' "$SANDBOX/collision" ||
        fail "peer check $peer_status left the route for the current address in place"
done

# The relay bookkeeping identifies a stale relay by exclusion, so a resolver
# route in the journal was read as one: routes_complete went false on every
# run, the DERP refresh deleted the route, and this module put it back. The
# route flapped once per run and the signature-verifying peer check ran with
# it. A failed retirement took the whole keeper into fail_safely, which is the
# teardown a DNS fault must never cause.
printf '%s\n' \
    '192.200.0.0/24|-inet|192.168.0.1|en0|-|-|normal' \
    '199.165.136.0/24|-inet|192.168.0.1|en0|-|-|normal' \
    '5.161.218.233|-inet|192.168.0.1|en0|-|-|normal' \
    '203.0.113.9|-inet|192.168.0.1|en0|-|-|normal' \
    '100.64.0.23|-inet|interface#utun7|utun7|-|-|-' >"$SANDBOX/state/routes"
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

# Settings that cannot be read leave the right address unknown, so a route
# placed under an earlier reading is withdrawn rather than left stranding
# whatever now holds it while health reports nothing routed.
settings default true false false false false false ',
        "block_crypto": true' >"$SANDBOX/seventh.json"
printf '%s\n' '100.64.0.23|-inet|interface#utun7|utun7|-|-|-' >"$SANDBOX/state/routes"
set +e
outcome=$(TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
    TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
    TAILNET_KEEPER_MULLVAD_SETTINGS="$SANDBOX/seventh.json" \
    bash -c '
        set -uo pipefail
        source "$1"
        physical_interface=en0
        tailscale_interface=utun6
        retire_owned_route() { printf "retired %s\n" "$1"; return 0; }
        ensure_owned_route() { printf "PLACED\n"; return 0; }
        reconcile_mullvad_dns_route
        printf "status=%s address=[%s]\n" "$?" "$mullvad_dns_address"
    ' _ "$KEEPER")
set -e
grep -q 'retired 100.64.0.23' <<<"$outcome" ||
    fail "unreadable settings left an earlier route in place: $outcome"
grep -q 'status=2 address=\[\]' <<<"$outcome" ||
    fail "unreadable settings did not report an empty address: $outcome"

# A route that rolled back is not a route, so the address must not describe it.
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
        tailnet_peer_holds_address() { return 1; }
        ensure_owned_route() { return 1; }
        reconcile_mullvad_dns_route
        printf "status=%s address=[%s]\n" "$?" "$mullvad_dns_address"
    ' _ "$KEEPER")
set -e
grep -q 'status=1 address=\[\]' <<<"$outcome" ||
    fail "a rolled-back route was still reported in health: $outcome"

# A custom list a user names `block_foo` is a value, not a seventh list.
settings default true true true false true false >"$SANDBOX/named.json"
python3 - "$SANDBOX/named.json" <<'DECOY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["custom_lists"] = {"lists": [{"name": "block_foo", "id": "x"}]}
json.dump(document, open(path, "w"), indent=2)
DECOY
[ "$(address_for "$SANDBOX/named.json")" = 100.64.0.23 ] ||
    fail 'a custom list named like a blocklist was counted as one'

printf 'mullvad_dns=PASS\n'
