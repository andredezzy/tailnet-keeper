#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-derp.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

mkdir -p "$SANDBOX/state" "$SANDBOX/run"
cat >"$SANDBOX/derp-map.json" <<'JSON'
{"Regions":{"1":{"Nodes":[{"IPv4":"8.8.8.8","IPv6":"2600:1900:4000:4d12::"}]}}}
JSON
TAILNET_KEEPER_TESTING=1 bash -c '
    source "$1"
    extract_derp_candidates "$2" "$3" "$4"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX/derp-map.json" "$SANDBOX/v4" "$SANDBOX/v6" || fail 'dual-stack DERP parser rejected valid map'
[ "$(cat "$SANDBOX/v4")" = 8.8.8.8 ] || fail 'DERP parser missed IPv4 relay'
[ "$(cat "$SANDBOX/v6")" = '2600:1900:4000:4d12::' ] || fail 'DERP parser missed IPv6 relay'

seed_state() {
    printf '1.1.1.1\n' >"$SANDBOX/state/derp-ipv4"
    printf '2600::1\n' >"$SANDBOX/state/derp-ipv6"
    printf '192.200.0.0/24|-inet|192.168.0.1|en0|-|-\n' >"$SANDBOX/state/routes"
    : >"$SANDBOX/state/table-log"
    rm -f "$SANDBOX/run"/*
}

seed_state
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.0.1
    physical_ipv6_gateway=fe80::1%en0
    physical_interface=en0

    build_derp_candidates() { printf "8.8.8.8\n" >"$1"; printf "2600::8\n" >"$2"; }
    ensure_owned_route() { journal_add "$2" "$1" -; }
    rollback_candidate_routes() { :; }
    snapshot_derp_table() { [ "$1" = tailscale_derp ] && printf "1.1.1.1\n" >"$2" || printf "2600::1\n" >"$2"; }
    replace_derp_table() { printf called >"$STATE_DIR/table-called"; return 1; }

    ! refresh_derp_routes
    [ -f "$STATE_DIR/table-called" ]
    [ "$(cat "$DERP_CACHE")" = 1.1.1.1 ]
    [ "$(cat "$DERP_IPV6_CACHE")" = 2600::1 ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'DERP refresh bypassed its PF table seam'

seed_state
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.0.1
    physical_ipv6_gateway=fe80::1%en0
    physical_interface=en0

    build_derp_candidates() { printf "8.8.8.8\n" >"$1"; printf "2600::8\n" >"$2"; }
    ensure_owned_route() { journal_add "$2" "$1" -; }
    rollback_candidate_routes() { journal_remove 8.8.8.8; journal_remove 2600::8; }
    snapshot_derp_table() { [ "$1" = tailscale_derp ] && printf "9.9.9.9\n" >"$2" || printf "2600::9\n" >"$2"; }
    replace_derp_table() { printf "%s:%s\n" "$1" "$(cat "$2")" >>"$STATE_DIR/table-log"; }
    commit_derp_state() { return 1; }

    ! refresh_derp_routes
    [ "$(cat "$DERP_CACHE")" = 1.1.1.1 ]
    [ "$(cat "$DERP_IPV6_CACHE")" = 2600::1 ]
    [ "$(cat "$ROUTE_JOURNAL")" = "192.200.0.0/24|-inet|192.168.0.1|en0|-|-" ]
    cat >"$STATE_DIR/table-expected" <<EOF
tailscale_derp:8.8.8.8
tailscale_derp6:2600::8
tailscale_derp:9.9.9.9
tailscale_derp6:2600::9
EOF
    cmp -s "$STATE_DIR/table-expected" "$STATE_DIR/table-log"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'dual-stack DERP commit failure did not restore tables, caches, and journal'

printf '8.8.8.8\n' >"$SANDBOX/old"
: >"$SANDBOX/desired"
printf '8.8.8.8|-inet|192.168.1.1|en0|-|-\n' >"$SANDBOX/state/routes"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    restore_journaled_route() { return 1; }
    ! retire_unwanted_owned_routes "$3" "$3"
    [ -s "$ROUTE_JOURNAL" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX/old" "$SANDBOX/desired" || fail 'failed stale-route restore lost journal evidence'

seed_state
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.0.1
    physical_interface=en0
    build_derp_candidates() { printf "8.8.8.8\n" >"$1"; : >"$2"; }
    ensure_owned_route() { return 0; }
    snapshot_derp_table() { : >"$2"; }
    replace_derp_table() { return 0; }
    commit_derp_state() { return 0; }
    retire_unwanted_owned_routes() { return 1; }
    ! refresh_derp_routes
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'DERP refresh hid stale-route retirement failure'

printf '8.8.8.8\n' >"$SANDBOX/candidate"
mkdir -p "$SANDBOX/readonly"
chmod 0500 "$SANDBOX/readonly"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -uo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.0.1
    physical_interface=en0
    journal_entry() { return 1; }
    route_matches() { return 1; }
    capture_specific_route() { return 0; }
    ensure_owned_route() { : >"$STATE_DIR/route-mutated"; }
    ! stage_candidate_routes -inet "$2" 192.168.0.1 en0 "$3/touched" 2>/dev/null
    [ ! -e "$STATE_DIR/route-mutated" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX/candidate" "$SANDBOX/readonly" || fail 'DERP route changed before rollback record was durable'
chmod 0700 "$SANDBOX/readonly"

seed_state
chmod 000 "$SANDBOX/state/derp-ipv4"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -uo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.0.1
    physical_interface=en0
    snapshot_derp_table() { : >"$2"; }
    build_derp_candidates() { printf "8.8.8.8\n" >"$1"; : >"$2"; }
    ensure_owned_route() { return 0; }
    replace_derp_table() { : >"$STATE_DIR/table-was-touched"; }
    status=0
    refresh_derp_routes 2>/dev/null || status=$?
    [ "$status" -ne 0 ]
    [ ! -e "$STATE_DIR/table-was-touched" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'failed DERP snapshot did not abort before mutation'
chmod 600 "$SANDBOX/state/derp-ipv4"
[ "$(cat "$SANDBOX/state/derp-ipv4")" = 1.1.1.1 ] || fail 'failed DERP snapshot damaged the cache'

TAILNET_KEEPER_TESTING=1 bash -c '
    set -uo pipefail
    source "$1"
    rollback_candidate_routes() { return 1; }
    replace_derp_table() { return 0; }
    restore_derp_state() { return 0; }
    ! restore_derp_transaction a b c d e f 1 1
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'DERP rollback hid route rollback failure'

printf '8.8.8.8|-inet|0|1|-|-\n' >"$SANDBOX/touched-inspection"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.0.1
    physical_interface=en0
    route_matches() { return 1; }
    capture_specific_route() { return 1; }
    ! rollback_candidate_routes "$2"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX/touched-inspection" || fail 'DERP rollback treated route inspection failure as absence'

printf '%s\n' \
    '192.200.0.0/24|-inet|192.168.0.1|en0|-|-' \
    '8.8.8.8|-inet|192.168.0.1|en0|-|-' >"$SANDBOX/state/routes"
printf '%s\n' '192.200.0.0/24|-inet|192.168.0.1|en0|-|-' >"$SANDBOX/old-journal"
cp "$SANDBOX/state/derp-ipv4" "$SANDBOX/old-v4-cache"
cp "$SANDBOX/state/derp-ipv6" "$SANDBOX/old-v6-cache"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    rollback_candidate_routes() { return 1; }
    replace_derp_table() { return 0; }
    status=0
    restore_derp_transaction "$2" "$3" "$4" "$5" "$6" "$7" 1 1 || status=$?
    [ "$status" -ne 0 ]
    grep -Fq "8.8.8.8|-inet|" "$ROUTE_JOURNAL"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX/touched" "$SANDBOX/old-v4-table" "$SANDBOX/old-v6-table" "$SANDBOX/old-v4-cache" "$SANDBOX/old-v6-cache" "$SANDBOX/old-journal" || fail 'partial route rollback lost ownership evidence'

seed_state
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -uo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.0.1
    physical_interface=en0
    snapshot_derp_table() { : >"$2"; }
    build_derp_candidates() { printf "8.8.8.8\n" >"$1"; : >"$2"; }
    stage_candidate_routes() { return 1; }
    restore_derp_transaction() { return 1; }
    status=0
    refresh_derp_routes || status=$?
    [ "$status" -eq 2 ]
    [ -e "$RUNTIME_DIR/routes-old" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'DERP refresh discarded incomplete rollback evidence'

printf '%s\n' \
    '192.200.0.0/24|-inet|192.168.0.1|en0|-|-' \
    '8.8.8.8|-inet|192.168.0.1|en0|-|-' >"$SANDBOX/state/routes"
printf '9.9.9.9\n' >"$SANDBOX/desired-v4"
printf '2606:4700:4700::1111\n' >"$SANDBOX/desired-v6"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    restore_journaled_route() { return 0; }
    retire_unwanted_owned_routes "$2" "$3"
    journal_has 192.200.0.0/24
    if journal_has 8.8.8.8; then exit 1; fi
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX/desired-v4" "$SANDBOX/desired-v6" || fail 'orphaned journal route was not retired'

printf '8.8.8.8\n' >"$SANDBOX/state/derp-ipv4"
printf '2600:1900:4000:4d12::\n' >"$SANDBOX/state/derp-ipv6"
printf '%s\n' \
    '192.200.0.0/24|-inet|192.168.0.1|en0|-|-' \
    '9.9.9.9|-inet|192.168.0.1|en0|-|-' >"$SANDBOX/state/routes"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.0.1
    physical_ipv6_gateway=fe80::1%en0
    physical_interface=en0
    route_matches() { return 0; }
    if routes_complete; then exit 1; fi
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'orphaned journal route did not force reconciliation'

grep -q 'restore_file_atomically' "$PROJECT_ROOT/libexec/derp.sh" || fail 'DERP cache rollback writes directly over live cache'

printf '%s\n' '2600:0:0:0:0:0:0:1|-inet6|fe80::1%en0|en0|-|-' >"$SANDBOX/state/routes"
printf '2600::1\n' >"$SANDBOX/desired6"
: >"$SANDBOX/desired4"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    marker="$4/retired"
    retire_owned_route() { : >"$marker"; }
    retire_unwanted_owned_routes "$2" "$3"
    [ ! -e "$marker" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX/desired4" "$SANDBOX/desired6" "$SANDBOX" || fail 'equivalent IPv6 route was retired as stale'

# One address, two spellings: the journal must resolve both to a single entry
# so repair never creates a second entry whose "prior" is the keeper's own route.
printf '%s\n' '2600:0:0:0:0:0:0:1|-inet6|fe80::1%en0|en0|198.51.100.1|en1' >"$SANDBOX/state/routes"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.0.1
    physical_ipv6_gateway=fe80::1%en0
    physical_interface=en0
    journal_entry 2600::1 >/dev/null
    journal_add 2600::1 -inet6 "203.0.113.9 en2"
    [ "$(wc -l <"$ROUTE_JOURNAL" | tr -d " ")" = 1 ]
    grep -q "|198.51.100.1|en1|normal$" "$ROUTE_JOURNAL"
    journal_remove 2600:0:0:0:0:0:0:1
    [ ! -s "$ROUTE_JOURNAL" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'equivalent IPv6 spellings created duplicate journal entries'

# xmllint exits 10 for an empty XPath match but non-zero otherwise; a real
# failure must not be published as "this family has no relays".
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    xml=$2/derp.xml
    printf "<plist><dict><key>IPv4</key><string>8.8.8.8</string></dict></plist>\n" >"$xml"
    extract_derp_addresses "$xml" IPv4 "$2/out4"
    [ "$(cat "$2/out4")" = 8.8.8.8 ]
    extract_derp_addresses "$xml" IPv6 "$2/out6"
    [ ! -s "$2/out6" ]
    if extract_derp_addresses "$2/missing.xml" IPv6 "$2/out6"; then exit 1; fi
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX" || fail 'DERP extraction failure was published as an empty relay set'

# The DERP map is JSON. Earlier code gated it with `plutil -lint`, which parses
# its input as a property list and rejects JSON outright, so a cold cache could
# never be populated on a real host. Run the real plutil against a real-shaped
# map to keep the parse path honest.
json_sandbox=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-derp-json.XXXXXX")
cat >"$json_sandbox/derp-map.json" <<'JSON'
{
	"Regions": {
		"1": {
			"RegionID": 1,
			"Nodes": [
				{ "Name": "1a", "IPv4": "199.38.181.104", "IPv6": "2606:b740:1::104" }
			]
		}
	}
}
JSON
/usr/bin/plutil -convert xml1 -o "$json_sandbox/derp-map.xml" "$json_sandbox/derp-map.json" >/dev/null 2>&1 ||
    fail 'the real plutil could not convert a real-shaped DERP map'
/usr/bin/plutil -lint "$json_sandbox/derp-map.json" >/dev/null 2>&1 &&
    fail 'plutil -lint accepted JSON, so the gate it replaced may be reinstated'
grep -q '^[^#]*\$PLUTIL" -lint' "$PROJECT_ROOT/libexec/derp.sh" &&
    fail 'the DERP fetch path lints JSON as a property list'
rm -rf "$json_sandbox"

# The keeper must be able to build its bypass when the Tailscale daemon is
# unreachable, because that is the state it exists to repair: without the
# bypass the CLI cannot serve the DERP map that building the bypass needs.
grep -q 'controlplane.tailscale.com/derpmap/default' "$PROJECT_ROOT/libexec/derp.sh" ||
    fail 'the DERP map has no source when the local daemon is down'
DEADLOCK_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-derp-deadlock.XXXXXX")
cat >"$DEADLOCK_SANDBOX/curl" <<'STUB'
#!/bin/bash
printf '{ "Regions": { "1": { "RegionID": 1, "Nodes": [ { "Name": "1a", "IPv4": "199.38.181.104", "IPv6": "2606:b740:1::104" } ] } } }\n'
STUB
chmod +x "$DEADLOCK_SANDBOX/curl"
deadlock_map=$(TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_CURL="$DEADLOCK_SANDBOX/curl" \
    TAILNET_KEEPER_TAILSCALE_CLI=/nonexistent/tailnet-keeper-tailscale \
    /bin/bash -c '
        TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
        fetch_derp_map "$2" >/dev/null 2>&1 || exit 1
        cat "$2"
    ' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$DEADLOCK_SANDBOX/map.json") ||
    fail 'the keeper could not fetch a DERP map without the local daemon'
printf '%s' "$deadlock_map" | grep -q '199.38.181.104' ||
    fail 'the fallback DERP map was empty'
rm -rf "$DEADLOCK_SANDBOX"

# PF echoes IPv6 in its own canonical spelling, dropping leading zeros within
# a group, so comparing its table against the cache verbatim reports a
# mismatch for addresses that are in fact identical. Both sides are compared
# canonically, the way route identity already is.
IPV6_TABLE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-derp-v6.XXXXXX")
printf '2001:19f0:c000:c564:5400:04ff:fe26:2ba8\n2606:b740:1::104\n' >"$IPV6_TABLE_SANDBOX/cache"
printf '2001:19f0:c000:c564:5400:4ff:fe26:2ba8\n2606:b740:1:0:0:0:0:104\n' >"$IPV6_TABLE_SANDBOX/table"
same=$(TAILNET_KEEPER_TESTING=1 /bin/bash -c '
    TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
    canonical_address_set <"$2"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$IPV6_TABLE_SANDBOX/cache")
other=$(TAILNET_KEEPER_TESTING=1 /bin/bash -c '
    TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
    canonical_address_set <"$2"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$IPV6_TABLE_SANDBOX/table")
[ -n "$same" ] || fail 'canonical address set produced nothing'
[ "$same" = "$other" ] ||
    fail 'equivalent IPv6 spellings compared as different DERP tables'
rm -rf "$IPV6_TABLE_SANDBOX"

# The PF table files live under the configured state directory. A hardcoded
# path in the template made the rendered rules unloadable whenever that
# directory was not the default, so every test run and every DESTDIR install
# produced a ruleset PF refused with "cannot load ... No such file".
TABLE_PATH_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-tablepath.XXXXXX")
! grep -q '/var/db/tailnet-keeper/derp-ipv' "$PROJECT_ROOT/tailnet-keeper.pf" ||
    fail 'the PF template hardcodes the default state directory'
rendered=$(TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_STATE_DIR="$TABLE_PATH_SANDBOX/state" \
    TAILNET_KEEPER_RUNTIME_DIR="$TABLE_PATH_SANDBOX/run" \
    /bin/bash -c '
        TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
        render_rules en0 utun4 "$2"
    ' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$PROJECT_ROOT/tailnet-keeper.pf")
printf '%s' "$rendered" | grep -q "$TABLE_PATH_SANDBOX/state/derp-ipv4" ||
    fail 'rendered rules do not point at the configured state directory'
printf '%s' "$rendered" | grep -q '__[A-Z_]*__' &&
    fail 'rendered rules still contain placeholders'
rm -rf "$TABLE_PATH_SANDBOX"

printf 'derp_transaction=PASS\n'
