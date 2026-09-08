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

# Kernel seams for refresh tests: the table holds only the uplink default,
# so every candidate is absent; adds and deletes are accepted and logged.
cat >"$SANDBOX/netstat" <<'STUB'
#!/bin/bash
printf 'default            192.168.0.1        UGScg                 en0\n'
STUB
cat >"$SANDBOX/route" <<'STUB'
#!/bin/bash
echo "$*" >>"${TAILNET_KEEPER_RUNTIME_DIR}/route.calls"
case "$*" in *get*) printf '   route to: x\ndestination: default\n       mask: default\n    gateway: 192.168.0.1\n  interface: en0\n      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING>\n' ;; esac
exit 0
STUB
chmod 0755 "$SANDBOX/netstat" "$SANDBOX/route"

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
TAILNET_KEEPER_ROUTE="$SANDBOX/route" TAILNET_KEEPER_NETSTAT="$SANDBOX/netstat" \
bash -c '
    set -euo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.0.1
    physical_ipv6_gateway=fe80::1%en0
    physical_interface=en0

    build_derp_candidates() { printf "8.8.8.8\n" >"$1"; printf "2600::8\n" >"$2"; }
    placed_routes_cover() { return 0; }
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
TAILNET_KEEPER_ROUTE="$SANDBOX/route" TAILNET_KEEPER_NETSTAT="$SANDBOX/netstat" \
bash -c '
    set -euo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.0.1
    physical_ipv6_gateway=fe80::1%en0
    physical_interface=en0

    build_derp_candidates() { printf "8.8.8.8\n" >"$1"; printf "2600::8\n" >"$2"; }
    placed_routes_cover() { return 0; }
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
TAILNET_KEEPER_ROUTE="$SANDBOX/route" TAILNET_KEEPER_NETSTAT="$SANDBOX/netstat" \
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
TAILNET_KEEPER_ROUTE="$SANDBOX/route" TAILNET_KEEPER_NETSTAT="$SANDBOX/netstat" \
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
TAILNET_KEEPER_ROUTE="$SANDBOX/route" TAILNET_KEEPER_NETSTAT="$SANDBOX/netstat" \
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
TAILNET_KEEPER_ROUTE="$SANDBOX/route" TAILNET_KEEPER_NETSTAT="$SANDBOX/netstat" \
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
TAILNET_KEEPER_ROUTE="$SANDBOX/route" TAILNET_KEEPER_NETSTAT="$SANDBOX/netstat" \
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
TAILNET_KEEPER_ROUTE="$SANDBOX/route" TAILNET_KEEPER_NETSTAT="$SANDBOX/netstat" \
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
TAILNET_KEEPER_ROUTE="$SANDBOX/route" TAILNET_KEEPER_NETSTAT="$SANDBOX/netstat" \
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
TAILNET_KEEPER_ROUTE="$SANDBOX/route" TAILNET_KEEPER_NETSTAT="$SANDBOX/netstat" \
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
TAILNET_KEEPER_ROUTE="$SANDBOX/route" TAILNET_KEEPER_NETSTAT="$SANDBOX/netstat" \
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
TAILNET_KEEPER_ROUTE="$SANDBOX/route" TAILNET_KEEPER_NETSTAT="$SANDBOX/netstat" \
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
TAILNET_KEEPER_ROUTE="$SANDBOX/route" TAILNET_KEEPER_NETSTAT="$SANDBOX/netstat" \
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
TAILNET_KEEPER_ROUTE="$SANDBOX/route" TAILNET_KEEPER_NETSTAT="$SANDBOX/netstat" \
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

# The steady-state check runs every five minutes over the full relay list.
# One read of the routing table answers it; one kernel lookup per address
# does not scale and cost nine seconds per run. Shapes are what netstat
# prints on macOS 26.6.2: a placed bypass is UGHS , a placed prefix UGScI,
# and a neighbour entry the kernel cloned is UHLWI and must not count.
COMPLETE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-complete.XXXXXX")
mkdir -p "$COMPLETE_SANDBOX/state" "$COMPLETE_SANDBOX/run"
printf '172.237.61.190\n172.237.61.194\n' >"$COMPLETE_SANDBOX/state/derp-ipv4"
printf '2606:b740:1::104\n2606:b740:1:0:0:0:0:105\n' >"$COMPLETE_SANDBOX/state/derp-ipv6"
cat >"$COMPLETE_SANDBOX/state/routes" <<'JOURNAL'
192.200.0.0/24|-inet|192.168.0.1|en0|-|-|-
2606:b740:49::/48|-inet6|fe80::1%en0|en0|-|-|-
172.237.61.190|-inet|192.168.0.1|en0|-|-|-
172.237.61.194|-inet|192.168.0.1|en0|-|-|-
2606:b740:1:0:0:0:0:104|-inet6|fe80::1%en0|en0|-|-|-
2606:b740:1:0:0:0:0:105|-inet6|fe80::1%en0|en0|-|-|-
JOURNAL
cat >"$COMPLETE_SANDBOX/table-inet" <<'TABLE'
default            192.168.0.1        UGScg                 en0
192.200.0          192.168.0.1        UGSc                  en0
172.237.61.190     192.168.0.1        UGHS                  en0
172.237.61.194     192.168.0.1        UGHS                  en0
192.168.0.7        a:b:c:d:e:f        UHLWI                 en0
TABLE
cat >"$COMPLETE_SANDBOX/table-inet6" <<'TABLE'
default                                 fe80::1%en0                             UGcg                  en0
2606:b740:49::/48                       fe80::1%en0                             UGSc                  en0
2606:b740:1::104                        fe80::1%en0                             UGHS                  en0
2606:b740:1::105                        fe80::1%en0                             UGHS                  en0
2804:7f0:1::a799                        link#11                                 UHLWI                 en0
TABLE
printf '#!/bin/bash\ncase "$*" in *inet6*) cat "%s/table-inet6" ;; *) cat "%s/table-inet" ;; esac\n' \
    "$COMPLETE_SANDBOX" "$COMPLETE_SANDBOX" >"$COMPLETE_SANDBOX/netstat"
chmod 0755 "$COMPLETE_SANDBOX/netstat"
printf '#!/bin/bash\ntouch "%s/route.called"\nexit 1\n' "$COMPLETE_SANDBOX" >"$COMPLETE_SANDBOX/route"
chmod 0755 "$COMPLETE_SANDBOX/route"
complete_check() {
    TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_NETSTAT="$COMPLETE_SANDBOX/netstat" \
    TAILNET_KEEPER_ROUTE="$COMPLETE_SANDBOX/route" \
    TAILNET_KEEPER_STATE_DIR="$COMPLETE_SANDBOX/state" \
    TAILNET_KEEPER_RUNTIME_DIR="$COMPLETE_SANDBOX/run" \
    bash -c '
        source "$1"
        physical_interface=en0
        physical_ipv4_gateway=192.168.0.1
        physical_ipv6_gateway="fe80::1%en0"
        routes_complete
    ' _ "$PROJECT_ROOT/bin/tailnet-keeper"
}
complete_check || fail 'a complete route set was reported incomplete'
[ ! -e "$COMPLETE_SANDBOX/route.called" ] || fail 'the completeness check still asks the kernel one route at a time'
# The journal side of the check is a set comparison too. One awk per journal
# line put 0.7s of every five-minute run into canonicalising the same list,
# and grew with the relay count. With 400 journaled IPv6 addresses the check
# must still finish in well under a second.
for i in $(seq 1 400); do
    printf '2606:b740:1::%x\n' "$((0x1000 + i))" >>"$COMPLETE_SANDBOX/state/derp-ipv6"
    printf '2606:b740:1:0:0:0:0:%x|-inet6|fe80::1%%en0|en0|-|-|-\n' "$((0x1000 + i))" >>"$COMPLETE_SANDBOX/state/routes"
    printf '2606:b740:1::%x                         fe80::1%%en0                             UGHS                  en0\n' "$((0x1000 + i))" >>"$COMPLETE_SANDBOX/table-inet6"
done
started=$SECONDS
complete_check || fail 'a large complete route set was reported incomplete'
[ $((SECONDS - started)) -le 1 ] || fail "the completeness check took $((SECONDS - started))s for 400 journal lines"
# One placed route losing its scope, or one going missing, is incomplete.
sed -i '' 's/172.237.61.194     192.168.0.1        UGHS /172.237.61.194     192.168.0.1        UGHSI/' "$COMPLETE_SANDBOX/table-inet"
if complete_check; then fail 'a scoped bypass route counted as complete, and a plain socket cannot use it'; fi
sed -i '' 's/172.237.61.194     192.168.0.1        UGHSI/172.237.61.194     192.168.0.1        UGH  /' "$COMPLETE_SANDBOX/table-inet"
if complete_check; then fail 'a host route the keeper did not place counted as complete'; fi
sed -i '' '/172.237.61.194/d' "$COMPLETE_SANDBOX/table-inet"
if complete_check; then fail 'a missing bypass route counted as complete'; fi
rm -rf "$COMPLETE_SANDBOX"

# A relay whose route is already correct is proven from the routing table
# and nothing else: rollback ignores unchanged records, so capturing a prior
# for one is work that is never read. Four kernel lookups per present address
# put six seconds into every hourly refresh.
STAGE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-stage.XXXXXX")
mkdir -p "$STAGE_SANDBOX/state" "$STAGE_SANDBOX/run"
printf '172.237.61.190|-inet|192.168.0.1|en0|-|-|-\n' >"$STAGE_SANDBOX/state/routes"
printf '172.237.61.190\n' >"$STAGE_SANDBOX/candidate"
printf '#!/bin/bash\necho "$*" >>"${0}.calls"\nexit 0\n' >"$STAGE_SANDBOX/route"
cat >"$STAGE_SANDBOX/netstat" <<'FIXTURE'
#!/bin/bash
echo "$*" >>"${0}.calls"
printf '%s\n' \
  'default            192.168.0.1        UGScg                 en0' \
  '172.237.61.190     192.168.0.1        UGHS                  en0'
FIXTURE
chmod 0755 "$STAGE_SANDBOX/route" "$STAGE_SANDBOX/netstat"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_ROUTE="$STAGE_SANDBOX/route" TAILNET_KEEPER_NETSTAT="$STAGE_SANDBOX/netstat" \
TAILNET_KEEPER_STATE_DIR="$STAGE_SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$STAGE_SANDBOX/run" \
bash -c '
    source "$1"
    physical_interface=en0
    physical_ipv4_gateway=192.168.0.1
    : >"$2/touched"
    stage_candidate_routes -inet "$2/candidate" 192.168.0.1 en0 "$2/touched"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$STAGE_SANDBOX" || fail 'staging a present route failed'
[ ! -e "$STAGE_SANDBOX/route.calls" ] || fail "staging an already-correct route called route(8): $(cat "$STAGE_SANDBOX/route.calls")"
[ "$(wc -l <"$STAGE_SANDBOX/netstat.calls" | tr -d ' ')" -eq 1 ] || fail "staging an already-correct route read the table $(wc -l <"$STAGE_SANDBOX/netstat.calls" | tr -d ' ') times instead of once"
grep -q '^172.237.61.190|-inet|1|0|' "$STAGE_SANDBOX/touched" || fail 'a present route was not recorded as owned and unchanged'
rm -rf "$STAGE_SANDBOX"

# Staging decides which candidates already have their route from one read of
# the table per family, not one read per candidate. With 88 relays a
# per-candidate read put twenty seconds into every network change, most of
# it re-reading a table that does not change between candidates. Candidates
# the table already covers are recorded unchanged without touching the
# kernel; only the missing ones take the placement path.
BULK_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-bulk.XXXXXX")
mkdir -p "$BULK_SANDBOX/state" "$BULK_SANDBOX/run"
: >"$BULK_SANDBOX/state/routes"
seq 1 200 | awk '{ printf "10.%d.%d.%d\n", int($1/65536)%256, int($1/256)%256, $1%256 }' >"$BULK_SANDBOX/candidate"
# The table holds the first 190; the last 10 are missing.
{
    printf 'default            192.168.0.1        UGScg                 en0\n'
    head -190 "$BULK_SANDBOX/candidate" | awk '{ printf "%-18s 192.168.0.1        UGHS                  en0\n", $1 }'
} >"$BULK_SANDBOX/table"
cat >"$BULK_SANDBOX/netstat" <<'STUB'
#!/bin/bash
echo "$*" >>"${0}.calls"
cat "$BULK_TABLE"
STUB
cat >"$BULK_SANDBOX/route" <<'STUB'
#!/bin/bash
echo "$*" >>"${0}.calls"
case "$*" in
    *add*) a=$(echo "$*" | awk '{print $(NF-1)}'); printf '%-18s 192.168.0.1        UGHS                  en0\n' "$a" >>"$BULK_TABLE" ;;
    *get*) printf '   route to: x\ndestination: default\n       mask: default\n    gateway: 192.168.0.1\n  interface: en0\n      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING>\n' ;;
esac
exit 0
STUB
chmod 0755 "$BULK_SANDBOX/netstat" "$BULK_SANDBOX/route"
bulk_start=$(date +%s)
BULK_TABLE="$BULK_SANDBOX/table" \
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_ROUTE="$BULK_SANDBOX/route" TAILNET_KEEPER_NETSTAT="$BULK_SANDBOX/netstat" \
TAILNET_KEEPER_STATE_DIR="$BULK_SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$BULK_SANDBOX/run" \
bash -c '
    source "$1"
    physical_interface=en0
    physical_ipv4_gateway=192.168.0.1
    : >"$2/touched"
    stage_candidate_routes -inet "$2/candidate" 192.168.0.1 en0 "$2/touched"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$BULK_SANDBOX" || fail 'bulk staging failed'
bulk_seconds=$(( $(date +%s) - bulk_start ))
table_reads=$(wc -l <"$BULK_SANDBOX/netstat.calls" | tr -d ' ')
[ "$(grep -c '|-inet|0|0|' "$BULK_SANDBOX/touched")" -eq 190 ] || fail "bulk staging recorded $(grep -c '|-inet|0|0|' "$BULK_SANDBOX/touched") present routes, expected 190"
[ "$(grep -c '|-inet|0|1|' "$BULK_SANDBOX/touched")" -eq 10 ] || fail "bulk staging recorded $(grep -c '|-inet|0|1|' "$BULK_SANDBOX/touched") placed routes, expected 10"
[ "$(grep -c ' add ' "$BULK_SANDBOX/route.calls")" -eq 10 ] || fail "bulk staging ran $(grep -c ' add ' "$BULK_SANDBOX/route.calls") route adds for 10 missing routes"
# Placing a missing route costs kernel calls, not process spawns: one add,
# one verifying table read, one journal write for the whole batch. Each
# spawn is ~5ms on macOS; at twenty per route a cold start of 176 relays
# took twenty seconds, of which the kernel needed under one.
[ "$(grep -c ' get ' "$BULK_SANDBOX/route.calls")" -eq 0 ] || fail "bulk staging ran $(grep -c ' get ' "$BULK_SANDBOX/route.calls") lookups for 10 missing routes; the table read already answered what each host had"
[ "$(grep -c ' delete ' "$BULK_SANDBOX/route.calls")" -eq 0 ] || fail "bulk staging ran $(grep -c ' delete ' "$BULK_SANDBOX/route.calls") deletes for hosts the table showed no route for"
[ "$table_reads" -le 22 ] || fail "bulk staging read the table $table_reads times for 10 placements (one to classify, one to verify each)"
[ "$(grep -c . "$BULK_SANDBOX/state/routes")" -eq 10 ] || fail "journal holds $(grep -c . "$BULK_SANDBOX/state/routes") entries, expected 10"
# Each journal line is exactly seven fields; a batch write must produce the
# same shape as a single write.
[ "$(awk -F'|' 'NF != 7' "$BULK_SANDBOX/state/routes" | wc -l | tr -d ' ')" -eq 0 ] || fail "batch journal wrote malformed lines: $(awk -F'|' 'NF != 7' "$BULK_SANDBOX/state/routes" | head -1)"
grep -q '^10.0.0.200|-inet|192.168.0.1|en0|-|-|-$' "$BULK_SANDBOX/state/routes" || fail "batch journal entry has the wrong shape: $(grep '^10.0.0.200' "$BULK_SANDBOX/state/routes")"
[ "$table_reads" -le 40 ] || fail "bulk staging read the table $table_reads times for 200 candidates; the present ones must come from one read"
[ "$bulk_seconds" -lt 5 ] || fail "bulk staging of 200 candidates took ${bulk_seconds}s"
# A host that already has a foreign static route is displaced, not merely
# added to: its prior route is recorded for rollback and deleted before the
# add, and the prior comes from the same table read as presence.
printf '10.9.9.9\n' >"$BULK_SANDBOX/candidate-foreign"
printf '10.9.9.9           198.51.100.1       UGHS                  en1\n' >>"$BULK_SANDBOX/table"
: >"$BULK_SANDBOX/route.calls"; : >"$BULK_SANDBOX/netstat.calls"; : >"$BULK_SANDBOX/touched"
BULK_TABLE="$BULK_SANDBOX/table" \
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_ROUTE="$BULK_SANDBOX/route" TAILNET_KEEPER_NETSTAT="$BULK_SANDBOX/netstat" \
TAILNET_KEEPER_STATE_DIR="$BULK_SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$BULK_SANDBOX/run" \
bash -c '
    source "$1"
    physical_interface=en0
    physical_ipv4_gateway=192.168.0.1
    placed_routes_cover() { return 0; }
    stage_candidate_routes -inet "$2/candidate-foreign" 192.168.0.1 en0 "$2/touched"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$BULK_SANDBOX" || fail 'staging over a foreign route failed'
grep -q '^10.9.9.9|-inet|0|1|198.51.100.1|en1|normal$' "$BULK_SANDBOX/touched" || fail "foreign prior route not recorded for rollback: $(cat "$BULK_SANDBOX/touched")"
grep -q '^10.9.9.9|-inet|192.168.0.1|en0|198.51.100.1|en1|normal$' "$BULK_SANDBOX/state/routes" || fail "foreign prior route not journaled: $(grep 10.9.9.9 "$BULK_SANDBOX/state/routes")"
grep -q ' delete -inet -host 10.9.9.9' "$BULK_SANDBOX/route.calls" || fail 'foreign route was not deleted before the add'
[ "$(grep -c ' get ' "$BULK_SANDBOX/route.calls")" -eq 0 ] || fail 'the foreign prior was looked up instead of read from the table'

# The touched file is shared by both families. Staging IPv6 after IPv4 must
# add only its own candidates, never replay the IPv4 lines as IPv6 adds.
printf '2600::1\n' >"$BULK_SANDBOX/candidate6"
: >"$BULK_SANDBOX/route.calls"
BULK_TABLE="$BULK_SANDBOX/table" \
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_ROUTE="$BULK_SANDBOX/route" TAILNET_KEEPER_NETSTAT="$BULK_SANDBOX/netstat" \
TAILNET_KEEPER_STATE_DIR="$BULK_SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$BULK_SANDBOX/run" \
bash -c '
    source "$1"
    physical_interface=en0
    physical_ipv4_gateway=192.168.0.1
    physical_ipv6_gateway=fe80::1%en0
    placed_routes_cover() { return 0; }
    stage_candidate_routes -inet6 "$2/candidate6" fe80::1%en0 en0 "$2/touched"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$BULK_SANDBOX" || fail 'IPv6 staging after IPv4 failed'
[ "$(grep -c ' add ' "$BULK_SANDBOX/route.calls")" -eq 1 ] || fail "IPv6 staging ran $(grep -c ' add ' "$BULK_SANDBOX/route.calls") adds; it replayed the IPv4 lines"
grep -q 'add -inet6 -host 2600::1 ' "$BULK_SANDBOX/route.calls" || fail 'IPv6 staging did not add its own candidate'
rm -rf "$BULK_SANDBOX"

printf 'derp_transaction=PASS\n'
