#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-route.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/state" "$SANDBOX/run"
: >"$SANDBOX/state/routes"

set +e
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -uo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.1.1
    physical_interface=en0
    checks=0
    route_matches() {
        checks=$((checks + 1))
        if [ "$checks" -gt 1 ]; then /bin/kill -KILL $$; fi
        return 1
    }
    capture_specific_route() { printf "198.51.100.1 en1\n"; }
    route_delete() { return 0; }
    route_add() { return 0; }
    ensure_owned_route -inet 8.8.8.8 192.168.1.1 en0
' _ "$PROJECT_ROOT/bin/tailnet-keeper" >/dev/null 2>&1 &
crash_pid=$!
wait "$crash_pid" 2>/dev/null
crash_status=$?
set -e

[ "$crash_status" -ne 0 ] || {
    printf 'FAIL: crash injection did not terminate the worker\n' >&2
    exit 1
}
expected='8.8.8.8|-inet|192.168.1.1|en0|198.51.100.1|en1|normal'
[ "$(cat "$SANDBOX/state/routes")" = "$expected" ] || {
    printf 'FAIL: route became active before ownership was durable\n' >&2
    exit 1
}

TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    # The owned route is present; deleting it fails.
    owned_route_present() { [ "$3" = 192.168.1.1 ]; }
    route_matches() { return 1; }
    route_delete() { return 1; }
    route_add() { return 0; }
    ! restore_journaled_route 8.8.8.8 -inet 192.168.1.1 en0 198.51.100.1 en1

    # Deleting works; re-adding the displaced route fails.
    route_delete() { return 0; }
    route_add() { return 1; }
    ! restore_journaled_route 8.8.8.8 -inet 192.168.1.1 en0 198.51.100.1 en1

    # Deleting works, re-adding works, and the re-added route reads back.
    restored=
    route_matches() { [ "$3 $4" = "198.51.100.1 en1" ] && [ "$restored" = "198.51.100.1 en1" ]; }
    route_add() { restored="$3 $4"; }
    capture_specific_route() { return 0; }
    restore_journaled_route 8.8.8.8 -inet 192.168.1.1 en0 198.51.100.1 en1
    [ "$restored" = "198.51.100.1 en1" ]

    # Nothing to restore, deletion reports success, but the route is still there.
    owned_route_present() { return 0; }
    route_delete() { return 0; }
    ! restore_journaled_route 8.8.8.8 -inet 192.168.1.1 en0 - -
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: route restoration hid a failure\n' >&2
    exit 1
}

printf '%s\n' '2606:b740:49::/48|-inet6|fe80::1%en0|en0|-|-' >"$SANDBOX/state/routes"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    restore_journaled_route() { return 1; }
    ! retire_owned_route 2606:b740:49::/48
    [ -s "$ROUTE_JOURNAL" ]
    restore_journaled_route() { return 0; }
    retire_owned_route 2606:b740:49::/48
    [ ! -s "$ROUTE_JOURNAL" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: static IPv6 route retirement lost ownership state\n' >&2
    exit 1
}

: >"$SANDBOX/state/routes"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.1.1
    physical_interface=en0
    route_matches() { return 1; }
    capture_specific_route() { return 1; }
    route_delete() { : >"$RUNTIME_DIR/deleted"; }
    ! ensure_owned_route -inet 8.8.8.8 192.168.1.1 en0
    [ ! -e "$RUNTIME_DIR/deleted" ]
    [ ! -s "$ROUTE_JOURNAL" ]
    ! restore_journaled_route 8.8.8.8 -inet 192.168.1.1 en0 - -
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: route inspection failure was treated as confirmed absence\n' >&2
    exit 1
}

printf '%s\n' '8.8.8.8|-inet|192.168.1.1|en0|198.51.100.1|en1' >"$SANDBOX/state/routes"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.2.1
    physical_interface=en0
    route_matches() { return 1; }
    capture_specific_route() { printf "192.168.1.1 en0\n"; }
    route_delete() { return 0; }
    route_add() { return 1; }
    restore_journaled_route() { return 0; }
    ! ensure_owned_route -inet 8.8.8.8 192.168.2.1 en0
    [ "$(cat "$ROUTE_JOURNAL")" = "8.8.8.8|-inet|192.168.1.1|en0|198.51.100.1|en1" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: failed owned-route replacement changed its recovery journal\n' >&2
    exit 1
}

printf '%s\n' '8.8.8.8|-inet|192.168.1.1|en0|198.51.100.1|en1' >"$SANDBOX/state/routes"
chmod 000 "$SANDBOX/state/routes"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -uo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.1.1
    physical_interface=en0
    ! journal_add 9.9.9.9 -inet -
    ! journal_remove 8.8.8.8
    ! retire_owned_route 8.8.8.8
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    chmod 600 "$SANDBOX/state/routes"
    printf 'FAIL: journal read failure was not propagated\n' >&2
    exit 1
}
chmod 600 "$SANDBOX/state/routes"
[ "$(cat "$SANDBOX/state/routes")" = '8.8.8.8|-inet|192.168.1.1|en0|198.51.100.1|en1' ] || {
    printf 'FAIL: journal read failure destroyed ownership records\n' >&2
    exit 1
}

TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    ipv4=$(find_physical_ipv4_route <<EOF
Destination Gateway Flags Netif
default 192.0.2.1 UGR en9
default 192.168.1.1 UGScg en0
EOF
)
    [ "$ipv4" = "192.168.1.1 en0" ]
    ipv6=$(find_physical_ipv6_route <<EOF
Destination Gateway Flags Netif
default fe80::dead%en9 UGR en9
default fe80::1%en0 UGScg en0
EOF
)
    [ "$ipv6" = "fe80::1%en0 en0" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: physical route discovery selected a rejected default\n' >&2
    exit 1
}

ROUTE_DENY_FIXTURE="$SANDBOX/route-deny"
printf '#!/bin/bash\nprintf "   route to: 8.8.8.8\\ndestination: 8.8.8.8\\n    gateway: 198.51.100.1\\n  interface: en1\\n      flags: <UP,GATEWAY,HOST,REJECT,BLACKHOLE,STATIC>\\n"\n' >"$ROUTE_DENY_FIXTURE"
chmod 0755 "$ROUTE_DENY_FIXTURE"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_ROUTE="$ROUTE_DENY_FIXTURE" \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    [ "$(capture_specific_route -inet 8.8.8.8)" = "198.51.100.1 en1 reject+blackhole" ]
    [ "$(route_details 192.200.0.0/24 <<EOF
   destination: 192.200.0.0
          mask: 255.255.255.0
       gateway: 198.51.100.1
     interface: en1
         flags: <UP,GATEWAY,STATIC,REJECT>
EOF
)" = "198.51.100.1 en1 reject unscoped" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: route capture discarded deny policy\n' >&2
    exit 1
}

TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    deleted=0
    restored_policy=
    owned_route_present() { [ "$3" = 192.168.1.1 ]; }
    route_matches() { [ "${5:-normal}" = reject ] && [ "$restored_policy" = reject ]; }
    route_delete() { deleted=1; }
    route_add() { restored_policy=${5:-}; }
    restore_journaled_route 8.8.8.8 -inet 192.168.1.1 en0 198.51.100.1 en1 reject
    [ "$deleted" -eq 1 ] && [ "$restored_policy" = reject ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: prior deny-route policy was not restored\n' >&2
    exit 1
}

# Fail-closed cleanup reads the journal directly. A seven-field entry must keep
# its interface and deny policy distinct, and an unrestored entry must be
# rewritten without corruption.
printf '%s\n' '8.8.8.8|-inet|192.168.1.1|en0|198.51.100.1|en1|reject' >"$SANDBOX/state/routes"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    clear_anchor() { return 0; }
    evidence="$2/restore-arguments"
    restore_journaled_route() {
        printf "%s|%s\n" "${6}" "${7:-missing}" >"$evidence"
        return 1
    }
    ! fail_closed
    [ "$(cat "$2/restore-arguments")" = "en1|reject" ]
    [ "$(cat "$ROUTE_JOURNAL")" = "8.8.8.8|-inet|192.168.1.1|en0|198.51.100.1|en1|reject" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX" || {
    printf 'FAIL: fail-closed cleanup corrupted a deny-policy journal entry\n' >&2
    exit 1
}

# DERP staging records what rollback replays. The captured policy must not be
# stored as the interface.
: >"$SANDBOX/state/routes"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    physical_ipv4_gateway=192.168.1.1
    physical_interface=en0
    printf "8.8.8.8\n" >"$2/candidate"
    classify_candidates() { awk "{ print \$1, 0, 0, \"198.51.100.1\", \"en1\", \"reject\" }" "$2"; }
    route_delete() { return 0; }
    route_add() { return 0; }
    placed_routes_cover() { return 0; }
    stage_candidate_routes -inet "$2/candidate" 192.168.1.1 en0 "$2/touched"
    [ "$(cat "$2/touched")" = "8.8.8.8|-inet|0|1|198.51.100.1|en1|reject" ]

    replayed=
    route_matches() { [ "$3" = 192.168.1.1 ] || [ "${5:-normal}" = reject ]; }
    route_delete() { return 0; }
    route_add() { replayed="${4:-} ${5:-}"; }
    rollback_candidate_routes "$2/touched"
    [ "$replayed" = "en1 reject" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX" || {
    printf 'FAIL: DERP rollback lost the displaced deny policy\n' >&2
    exit 1
}

# Reserved documentation relays must be rejected regardless of spelling.
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    for reserved in 2001:db8::1 2001:DB8::1 2001:0db8::1 2001:0DB8:0000::1 2::1 3::1 20::1 2f::1 200::1 3ff::1 4000::1 1fff::1 fe80::1 fd7a::1 ff00::1; do
        ! valid_derp_ipv6 "$reserved" || exit 1
    done
    valid_derp_ipv6 2606:b740::1
    valid_derp_ipv6 2001:db80::1
    valid_derp_ipv6 3fff::1
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: reserved IPv6 documentation relay was accepted\n' >&2
    exit 1
}

# macOS answers `route -n get <host>` with the default route when no specific
# route exists, and always echoes IPv6 in compressed form, so the matcher must
# compare the destination canonically.
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    # The table prints only what is placed; a host without its own route has
    # no line, and route_matches reads the table.
    fallback="default            192.168.0.1        UGScg                 en0"
    specific="203.0.113.77       192.168.0.1        UGHS                  en0"
    ! table_route_matches 203.0.113.77 192.168.0.1 en0 normal unscoped <<<"$fallback"
    table_route_matches 203.0.113.77 192.168.0.1 en0 normal unscoped <<<"$specific"

    # The journal key is expanded; the kernel prints compressed.
    compressed="2607:f740:f::3d7                        fe80::1%en0                             UGHS                  en0"
    table_route_matches 2607:f740:f:0:0:0:0:3d7 "fe80::1%en0" en0 normal unscoped <<<"$compressed"
    ! table_route_matches 2607:f740:f:0:0:0:0:3d8 "fe80::1%en0" en0 normal unscoped <<<"$compressed"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf "FAIL: host matcher mishandled fallback or compressed IPv6\n" >&2
    exit 1
}

# capture_specific_route reads the same compressed kernel spelling from the
# route lookup, and an absent host falls through to its covering prefix.
ROUTE_V6_FIXTURE="$SANDBOX/route-v6"
cat >"$ROUTE_V6_FIXTURE" <<'FIXTURE'
#!/bin/bash
case "$*" in
    *3d7) printf '   route to: 2607:f740:f::3d7\ndestination: 2607:f740:f::3d7\n    gateway: fe80::1%%en0\n  interface: en0\n      flags: <UP,GATEWAY,HOST,STATIC>\n' ;;
    *) printf '   route to: 2607:f740:f::3d8\ndestination: 2607:f740:f::\n       mask: ffff:ffff:ffff::\n    gateway: fe80::1%%en0\n  interface: en0\n      flags: <UP,GATEWAY,STATIC,PRCLONING>\n' ;;
esac
FIXTURE
chmod 0755 "$ROUTE_V6_FIXTURE"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_ROUTE="$ROUTE_V6_FIXTURE" \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    captured=$(capture_specific_route -inet6 2607:f740:f:0:0:0:0:3d7)
    [ "$captured" = "fe80::1%en0 en0 normal" ]
    absent=$(capture_specific_route -inet6 2607:f740:f:0:0:0:0:3d8)
    [ -z "$absent" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf "FAIL: expanded journal key did not find its compressed kernel route\n" >&2
    exit 1
}

# Real kernel output shapes captured from macOS 26.6.2: a host bound to a
# point-to-point interface prints no gateway line, and some host routes
# carry an explicit /32 mask.
ROUTE_SHAPES="$SANDBOX/route-shapes"
cat >"$ROUTE_SHAPES" <<'FIXTURE'
#!/bin/bash
case "$*" in
    *8.8.8.8) printf '   route to: 8.8.8.8\ndestination: 8.8.8.8\n  interface: utun5\n      flags: <UP,HOST,DONE,STATIC>\n' ;;
    *198.51.100.77) printf '   route to: 198.51.100.77\ndestination: 198.51.100.77/32\n    gateway: 192.168.0.1\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,STATIC>\n' ;;
    *) exit 1 ;;
esac
FIXTURE
chmod 0755 "$ROUTE_SHAPES"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_ROUTE="$ROUTE_SHAPES" \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"

    # A point-to-point gateway is an interface reference, not an address.
    [ "$(capture_specific_route -inet 8.8.8.8)" = "interface#utun5 utun5 normal" ]

    # A /32 host spelling must still match the bare host it displaced.
    [ "$(capture_specific_route -inet 198.51.100.77)" = "192.168.0.1 en0 normal" ]

    # An interface route prints no gateway line: a legitimate shape, not an error.
    details=$(route_details 192.200.0.0/24 <<EOF
   destination: 192.200.0.0
          mask: 255.255.255.0
     interface: utun4
         flags: <UP,DONE,CLONING>
EOF
)
    [ "$details" = "interface#utun4 utun4 normal unscoped" ]

    # The same p2p route must match from the table, where netstat prints the
    # interface reference in the gateway column.
    table_route_matches 8.8.8.8 "interface#utun5" utun5 normal unscoped <<<"8.8.8.8            utun5              UHS                 utun5"
    table_route_matches 8.8.8.8 "interface#utun5" utun5 normal unscoped <<<"8.8.8.8            link#22            UHS                 utun5"

    # Restoring an interface-scoped route must use -interface, never pass the
    # interface name where an address belongs.
    replayed=
    route_add_command() { replayed="$*"; }
    route_add -inet 8.8.8.8 "interface#utun5" utun5
    case "$replayed" in
        *"-interface utun5"*) ;;
        *) exit 1 ;;
    esac
    case "$replayed" in
        *"add -host 8.8.8.8 utun5"*) exit 1 ;;
    esac
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: real kernel route shapes were mishandled\n' >&2
    exit 1
}

# A bypass route must be visible to an ordinary socket. The Tailscale daemon
# opens plain sockets, and the kernel only consults an interface-scoped route
# (-ifscope) for a socket that is itself bound to that interface. A scoped
# bypass is therefore invisible to the very client it exists for: the socket
# falls through to the tunnel's default route and the relay is never reached.
# curl --interface binds its socket and hides this, so only a plain socket
# proves it. Bypass routes are added unscoped, and an unscoped route with
# the right gateway and interface is what the matcher accepts.
SCOPE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-scope.XXXXXX")
cat >"$SCOPE_SANDBOX/route" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$SCOPE_LOG"
exit 0
STUB
chmod +x "$SCOPE_SANDBOX/route"
SCOPE_LOG="$SCOPE_SANDBOX/calls" TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_ROUTE="$SCOPE_SANDBOX/route" \
    /bin/bash -c '
        TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
        route_add -inet 172.237.61.190 192.168.0.1 en0
        route_add -inet6 2606:b740:1::104 fe80::1%en0 en0
        route_add -inet 192.200.0.0/24 192.168.0.1 en0
        route_delete -inet 172.237.61.190
        route_matches -inet 172.237.61.190 192.168.0.1 en0 || true
        capture_specific_route -inet 172.237.61.190 || true
    ' _ "$PROJECT_ROOT/bin/tailnet-keeper"
if grep -- ' add ' "$SCOPE_SANDBOX/calls" | grep -q -- '-ifscope'; then
    printf 'FAIL: bypass routes are added interface-scoped and invisible to an ordinary socket\n' >&2
    exit 1
fi
if grep -- ' get ' "$SCOPE_SANDBOX/calls" | grep -q -- '-ifscope'; then
    printf 'FAIL: route lookups are scoped and would miss the unscoped route the keeper places\n' >&2
    exit 1
fi
grep -q -- '-host 172.237.61.190' "$SCOPE_SANDBOX/calls" || {
    printf 'FAIL: an IPv4 host bypass was not added as a host route\n' >&2
    exit 1
}
grep -q -- 'add -inet6 -host 2606:b740:1::104' "$SCOPE_SANDBOX/calls" || {
    printf 'FAIL: an IPv6 host bypass was not added as a host route\n' >&2
    exit 1
}
rm -rf "$SCOPE_SANDBOX"

# A scoped route is removable only through its own scope; an unscoped delete
# leaves it in place silently, and a host with both a scoped and an unscoped
# route refuses a plain socket outright. Deletion reads the route's actual
# scope from the kernel and names it, so a route an earlier version placed
# is removed rather than doubled.
DELETE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-delete.XXXXXX")
# The kernel answers an UNscoped lookup for a scoped-only host with the
# tunnel's default route, so the scope cannot be read that way; the table
# is what reveals it. Fixture: 190 is scoped-only, 194 unscoped.
cat >"$DELETE_SANDBOX/route" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$DELETE_LOG"
case "$*" in
    *get*-ifscope*172.237.61.190*) printf '   route to: 172.237.61.190\ndestination: 172.237.61.190\n    gateway: 192.168.0.1\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,STATIC,IFSCOPE>\n' ;;
    *get*172.237.61.190*) printf '   route to: 172.237.61.190\ndestination: default\n       mask: default\n    gateway: 10.0.0.1\n  interface: utun3\n      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>\n' ;;
    *get*172.237.61.194*) printf '   route to: 172.237.61.194\ndestination: 172.237.61.194\n    gateway: 192.168.0.1\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,STATIC>\n' ;;
esac
exit 0
STUB
cat >"$DELETE_SANDBOX/netstat" <<'STUB'
#!/bin/bash
printf '%s\n' \
  'default            10.0.0.1           UGScg               utun3' \
  'default            192.168.0.1        UGScIg                en0' \
  '172.237.61.190     192.168.0.1        UGHSI                 en0' \
  '172.237.61.194     192.168.0.1        UGHS                  en0'
STUB
chmod +x "$DELETE_SANDBOX/netstat"
chmod +x "$DELETE_SANDBOX/route"
DELETE_LOG="$DELETE_SANDBOX/calls" TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_ROUTE="$DELETE_SANDBOX/route" TAILNET_KEEPER_NETSTAT="$DELETE_SANDBOX/netstat" \
    /bin/bash -c '
        TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
        route_delete -inet 172.237.61.190
        route_delete -inet 172.237.61.194
    ' _ "$PROJECT_ROOT/bin/tailnet-keeper"
grep -q -- 'delete -inet -host -ifscope en0 172.237.61.190' "$DELETE_SANDBOX/calls" || {
    printf 'FAIL: a scoped route was deleted without its scope and stays in place\n' >&2
    exit 1
}
grep -q -- 'delete -inet -host 172.237.61.194' "$DELETE_SANDBOX/calls" || {
    printf 'FAIL: an unscoped route was not deleted plainly\n' >&2
    exit 1
}
if grep -- 'delete' "$DELETE_SANDBOX/calls" | grep -q -- '-ifscope en0 172.237.61.194'; then
    printf 'FAIL: an unscoped route was deleted with a scope it does not have\n' >&2
    exit 1
fi
rm -rf "$DELETE_SANDBOX"

# Retiring a journaled route must succeed when the route in the table is the
# one the journal says was placed, whether or not an earlier version placed
# it interface-scoped. The journal is the record of ownership; refusing to
# retire a scoped entry strands every route from the previous version and
# fails deactivation and uninstall outright.
RETIRE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-retire.XXXXXX")
mkdir -p "$RETIRE_SANDBOX/state" "$RETIRE_SANDBOX/run"
printf '172.237.61.190|-inet|192.168.0.1|en0|-|-|-\n' >"$RETIRE_SANDBOX/state/routes"
# The kernel removes a scoped route only through a scoped delete; a plain
# delete answers "not in table" and changes nothing.
cat >"$RETIRE_SANDBOX/route" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$RETIRE_LOG"
case "$*" in
    *delete*-ifscope*) : >"$RETIRE_GONE" ;;
    *delete*) exit 1 ;;
    *get*)
        if [ -e "$RETIRE_GONE" ]; then
            printf '   route to: 172.237.61.190\ndestination: default\n       mask: default\n    gateway: 10.0.0.1\n  interface: utun3\n      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING>\n'
        else
            printf '   route to: 172.237.61.190\ndestination: 172.237.61.190\n    gateway: 192.168.0.1\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,STATIC,IFSCOPE>\n'
        fi ;;
esac
exit 0
STUB
cat >"$RETIRE_SANDBOX/netstat" <<'STUB'
#!/bin/bash
printf 'default            192.168.0.1        UGScg                 en0\n'
[ -e "$RETIRE_GONE" ] || printf '172.237.61.190     192.168.0.1        UGHSI                 en0\n'
STUB
chmod +x "$RETIRE_SANDBOX/route" "$RETIRE_SANDBOX/netstat"
RETIRE_LOG="$RETIRE_SANDBOX/calls" RETIRE_GONE="$RETIRE_SANDBOX/gone" \
    TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_ROUTE="$RETIRE_SANDBOX/route" TAILNET_KEEPER_NETSTAT="$RETIRE_SANDBOX/netstat" \
    TAILNET_KEEPER_STATE_DIR="$RETIRE_SANDBOX/state" TAILNET_KEEPER_RUNTIME_DIR="$RETIRE_SANDBOX/run" \
    /bin/bash -c '
        TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
        physical_interface=en0; physical_ipv4_gateway=192.168.0.1; physical_ipv6_gateway=
        retire_owned_route 172.237.61.190
    ' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: a journaled route placed scoped by an earlier version could not be retired\n' >&2
    exit 1
}
grep -q -- 'delete -inet -host -ifscope en0 172.237.61.190' "$RETIRE_SANDBOX/calls" || {
    printf 'FAIL: the scoped route was not deleted through its scope\n' >&2
    exit 1
}
[ ! -s "$RETIRE_SANDBOX/state/routes" ] || {
    printf 'FAIL: the retired route stayed in the journal\n' >&2
    exit 1
}
rm -rf "$RETIRE_SANDBOX"

# Placing a route on top of a scoped leftover from an earlier version must
# remove the leftover first. An unscoped lookup never reveals it -- the kernel
# answers with a cloned entry -- so the plain delete reports "not in table",
# the add succeeds, and the host now carries both a scoped and an unscoped
# route: the lookup returns the scoped one, the matcher rejects it, and every
# relay after the first fails to stage. The table is where the leftover is
# visible, and it is consulted before the add.
STACK_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-stack.XXXXXX")
mkdir -p "$STACK_SANDBOX/state" "$STACK_SANDBOX/run"
: >"$STACK_SANDBOX/state/routes"
# Kernel model: a scoped route exists; an unscoped lookup returns a clone.
# After the scoped delete the host is clean; after the add it is unscoped.
cat >"$STACK_SANDBOX/route" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$STACK_LOG"
state=$(cat "$STACK_STATE")
case "$*" in
    *delete*-ifscope*) echo clean >"$STACK_STATE" ;;
    *delete*) [ "$state" = unscoped ] && echo clean >"$STACK_STATE" ;;
    *add*) [ "$state" = clean ] && echo unscoped >"$STACK_STATE" || echo both >"$STACK_STATE" ;;
    *get*)
        case "$state" in
            scoped) printf '   route to: 172.237.61.190\ndestination: 172.237.61.190\n    gateway: 192.168.0.1\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,WASCLONED,IFSCOPE,IFREF,GLOBAL>\n' ;;
            both) printf '   route to: 172.237.61.190\ndestination: 172.237.61.190\n    gateway: 192.168.0.1\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,STATIC,IFSCOPE>\n' ;;
            unscoped) printf '   route to: 172.237.61.190\ndestination: 172.237.61.190\n    gateway: 192.168.0.1\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,STATIC>\n' ;;
            clean) printf '   route to: 172.237.61.190\ndestination: default\n       mask: default\n    gateway: 10.0.0.1\n  interface: utun3\n      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>\n' ;;
        esac ;;
esac
exit 0
STUB
cat >"$STACK_SANDBOX/netstat" <<'STUB'
#!/bin/bash
state=$(cat "$STACK_STATE")
printf 'default            192.168.0.1        UGScg                 en0\n'
case "$state" in
    scoped|both) printf '172.237.61.190     192.168.0.1        UGHSI                 en0\n' ;;
esac
case "$state" in
    unscoped|both) printf '172.237.61.190     192.168.0.1        UGHS                  en0\n' ;;
esac
STUB
chmod +x "$STACK_SANDBOX/route" "$STACK_SANDBOX/netstat"
echo scoped >"$STACK_SANDBOX/kernel"
STACK_LOG="$STACK_SANDBOX/calls" STACK_STATE="$STACK_SANDBOX/kernel" \
    TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_ROUTE="$STACK_SANDBOX/route" TAILNET_KEEPER_NETSTAT="$STACK_SANDBOX/netstat" \
    TAILNET_KEEPER_STATE_DIR="$STACK_SANDBOX/state" TAILNET_KEEPER_RUNTIME_DIR="$STACK_SANDBOX/run" \
    /bin/bash -c '
        TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
        ensure_owned_route -inet 172.237.61.190 192.168.0.1 en0 ""
    ' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: placing a route over a scoped leftover failed instead of replacing it\n' >&2
    exit 1
}
[ "$(cat "$STACK_SANDBOX/kernel")" = unscoped ] || {
    printf 'FAIL: the scoped leftover was not removed; the host carries %s routes\n' "$(cat "$STACK_SANDBOX/kernel")" >&2
    exit 1
}
rm -rf "$STACK_SANDBOX"

# The IPv6 table carries link-local rows with a zone suffix, fe80::1%awdl0,
# next to the routes being looked for. The canonical form is the expanded
# lower-case spelling, used only as a comparison key, and it keeps the zone:
# it is part of the address, and the uplink gateway is written the same way.
# An unparseable row must not fail the whole table read either: under
# pipefail one bad row would report every placed route as missing.
ZONE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-zone.XXXXXX")
TAILNET_KEEPER_TESTING=1 /bin/bash -c '
    TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
    [ "$(canonical_ipv6 "fe80::f478:b3ff:fe9c:8cf1%awdl0")" = "fe80:0:0:0:f478:b3ff:fe9c:8cf1%awdl0" ] || exit 1
    [ "$(canonical_ipv6 "FE80::1%en0")" = "fe80:0:0:0:0:0:0:1%en0" ] || exit 2
    out=$(printf "%s\n" \
        "fe80::f478:b3ff:fe9c:8cf1%awdl0 f6:78:b3:9c:8c:f1 awdl0 UHLSI" \
        "fe80::zz:1 x y z" \
        "2001:19f0:c000:c564:5400:4ff:fe26:2ba8 fe80::1%en0 en0 UGHS" | canonical_address_stream_keyed) || exit 3
    [ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" -eq 2 ] || exit 4
    printf "%s\n" "$out" | grep -q "^2001:19f0:c000:c564:5400:4ff:fe26:2ba8 " || exit 5
' _ "$PROJECT_ROOT/bin/tailnet-keeper" && zone_status=0 || zone_status=$?
case $zone_status in
    0) ;;
    1) printf 'FAIL: a zoned link-local address was not canonicalised\n' >&2; exit 1 ;;
    2) printf 'FAIL: a zoned address was not lower-cased and compressed\n' >&2; exit 1 ;;
    3) printf 'FAIL: one unparseable table row failed the whole stream\n' >&2; exit 1 ;;
    4) printf 'FAIL: the keyed stream dropped or duplicated rows around a zoned address\n' >&2; exit 1 ;;
    5) printf 'FAIL: the placed route after a zoned row was lost\n' >&2; exit 1 ;;
esac
rm -rf "$ZONE_SANDBOX"

# Traffic to a host clones a per-interface cache entry beside the placed
# route (netstat -a shows UGHdW3Ig with an expiry), and `route -n get`
# answers with the clone while it lives. That answer says nothing about
# whether the placed route is present, and a plain socket still uses the
# placed route. The matcher therefore reads the table, where the placed
# static route is visible regardless of what has been cloned around it.
CLONE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-clone.XXXXXX")
cat >"$CLONE_SANDBOX/route" <<'STUB'
#!/bin/bash
printf '   route to: 102.67.165.36\ndestination: 102.67.165.36\n    gateway: 172.20.10.1\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,WASCLONED,IFSCOPE,IFREF,GLOBAL>\n'
STUB
cat >"$CLONE_SANDBOX/netstat" <<'STUB'
#!/bin/bash
printf '%s\n' \
  'default            172.20.10.1        UGScg                 en0' \
  '102.67.165.36      172.20.10.1        UGHS                  en0' \
  '102.67.165.36      172.20.10.1        UGHdW3Ig              en0    140' \
  '102.67.165.36      utun7              UGHdW3Ig            utun7    124'
STUB
chmod +x "$CLONE_SANDBOX/route" "$CLONE_SANDBOX/netstat"
TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_ROUTE="$CLONE_SANDBOX/route" TAILNET_KEEPER_NETSTAT="$CLONE_SANDBOX/netstat" \
    /bin/bash -c '
        TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
        route_matches -inet 102.67.165.36 172.20.10.1 en0
    ' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: a placed route was reported missing because a cloned cache entry answered the lookup\n' >&2
    exit 1
}
# Without the placed route the clones alone must not count as present.
sed -i '' '/UGHS  /d' "$CLONE_SANDBOX/netstat"
if TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_ROUTE="$CLONE_SANDBOX/route" TAILNET_KEEPER_NETSTAT="$CLONE_SANDBOX/netstat" \
    /bin/bash -c '
        TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
        route_matches -inet 102.67.165.36 172.20.10.1 en0
    ' _ "$PROJECT_ROOT/bin/tailnet-keeper"; then
    printf 'FAIL: cloned cache entries counted as a placed route\n' >&2
    exit 1
fi
rm -rf "$CLONE_SANDBOX"

# The matcher accepts the route the keeper places: static, through the uplink
# gateway on the uplink interface, no scope. A scoped route with the same
# gateway and interface is not a match: a plain socket never consults it, so
# accepting it leaves a bypass in place that the client cannot use. An
# earlier version placed scoped routes, and they have to be replaced.
placed='172.237.61.190     192.168.0.1        UGHS                  en0'
scoped='172.237.61.190     192.168.0.1        UGHSI                 en0'
TAILNET_KEEPER_TESTING=1 /bin/bash -c '
    TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
    table_route_matches 172.237.61.190 192.168.0.1 en0 normal unscoped <<<"$2"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$placed" || {
    printf 'FAIL: the bypass route the keeper places was rejected by its own matcher\n' >&2
    exit 1
}
if TAILNET_KEEPER_TESTING=1 /bin/bash -c '
    TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
    table_route_matches 172.237.61.190 192.168.0.1 en0 normal unscoped <<<"$2"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$scoped"; then
    printf 'FAIL: a scoped bypass route was accepted, and a plain socket cannot use it\n' >&2
    exit 1
fi

# A query for a host that has no route of its own answers with the covering
# route. That is a confirmed absence, not a failure to inspect, and treating
# it as an error stops the keeper from ever creating the route it owns.
ABSENCE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-absence.XXXXXX")
printf '#!/bin/bash\nprintf "   route to: 192.200.0.5\\ndestination: default\\n       mask: default\\n    gateway: 10.0.0.1\\n  interface: utun3\\n      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING>\\n"\n' >"$ABSENCE_SANDBOX/route"
chmod +x "$ABSENCE_SANDBOX/route"
absent=$(TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_ROUTE="$ABSENCE_SANDBOX/route" \
    /bin/bash -c '
        TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
        capture_specific_route -inet 192.200.0.0/24
    ' _ "$PROJECT_ROOT/bin/tailnet-keeper") || {
    printf 'FAIL: an absent route was reported as an inspection failure\n' >&2
    exit 1
}
[ -z "$absent" ] || {
    printf 'FAIL: an absent route reported a prior route\n' >&2
    exit 1
}
rm -rf "$ABSENCE_SANDBOX"

# Capturing the prior route asks the kernel for one lookup. A scoped query
# for a present host answers with the HOST flag; for an absent host it falls
# through to the covering prefix, which is a confirmed absence rather than a
# route to record. Shapes captured from macOS 26.6.2.
ROUTE_HOST_FIXTURE="$SANDBOX/route-host"
cat >"$ROUTE_HOST_FIXTURE" <<'FIXTURE'
#!/bin/bash
case "$*" in
    *"-host 172.237.61.190")
        printf '   route to: 172.237.61.190\ndestination: 172.237.61.190\n    gateway: 192.168.0.1\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,STATIC>\n' ;;
    *"-host 172.237.61.194")
        printf '   route to: 172.237.61.194\ndestination: default\n       mask: default\n    gateway: 192.168.0.1\n  interface: en0\n      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,IFSCOPE,GLOBAL>\n' ;;
    # The kernel resolves any spelling of an address; the answer is canonical.
    *"-host 2606:b740:1::104"|*"-host 2606:b740:1:0:0:0:0:104")
        printf '   route to: 2606:b740:1::104\ndestination: 2606:b740:1::104\n    gateway: fe80::1%%en0\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,STATIC>\n' ;;
    *"-host 2606:b740:1::105")
        printf '   route to: 2606:b740:1::105\ndestination: 2606:b740:1::\n       mask: ffff:ffff:ffff::\n    gateway: fe80::1%%en0\n  interface: en0\n      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,IFSCOPE>\n' ;;
    *"-host 8.8.8.8")
        printf '   route to: 8.8.8.8\ndestination: 8.8.8.8\n  interface: utun5\n      flags: <UP,HOST,DONE,STATIC>\n' ;;
    *"-host 198.51.100.1")
        printf '   route to: 198.51.100.1\ndestination: 198.51.100.1\n    gateway: 192.168.0.1\n  interface: en0\n      flags: <UP,GATEWAY,HOST,REJECT,BLACKHOLE,STATIC>\n' ;;
    # Traffic to a neighbour clones a host entry out of the covering route.
    # It carries HOST but not STATIC: the kernel owns it, the keeper does not.
    *"-host 2001:19f0:c000:c564:5400:4ff:fe26:2ba8")
        printf '   route to: 2001:19f0:c000:c564:5400:4ff:fe26:2ba8\ndestination: 2001:19f0:c000:c564:5400:4ff:fe26:2ba8\n    gateway: fe80::1%%en0\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,WASCLONED,IFSCOPE,IFREF,GLOBAL>\n' ;;
    *) exit 1 ;;
esac
FIXTURE
chmod 0755 "$ROUTE_HOST_FIXTURE"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_ROUTE="$ROUTE_HOST_FIXTURE" \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    [ "$(capture_specific_route -inet 172.237.61.190)" = "192.168.0.1 en0 normal" ]
    [ -z "$(capture_specific_route -inet 172.237.61.194)" ]
    [ "$(capture_specific_route -inet6 2606:b740:1::104)" = "fe80::1%en0 en0 normal" ]
    [ -z "$(capture_specific_route -inet6 2606:b740:1::105)" ]
    [ "$(capture_specific_route -inet 8.8.8.8)" = "interface#utun5 utun5 normal" ]
    [ "$(capture_specific_route -inet 198.51.100.1)" = "192.168.0.1 en0 reject+blackhole" ]
    # A compressed journal key must still find its expanded kernel spelling.
    [ "$(capture_specific_route -inet6 2606:b740:1:0:0:0:0:104)" = "fe80::1%en0 en0 normal" ]
    # A failed lookup is an inspection error, never absence.
    if capture_specific_route -inet 203.0.113.9; then exit 1; fi
    # A cloned neighbour entry is not a route the keeper placed.
    [ -z "$(capture_specific_route -inet6 2001:19f0:c000:c564:5400:4ff:fe26:2ba8)" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: prior-route capture misread a kernel lookup\n' >&2
    exit 1
}

# A journal that has not been created yet holds no entries. On a first run
# that is the ordinary state, not a failure to read it, and reporting an error
# there stops the keeper before it can create the very first route it owns.
JOURNAL_ABSENCE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-journal.XXXXXX")
TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_STATE_DIR="$JOURNAL_ABSENCE_SANDBOX/state" \
    TAILNET_KEEPER_RUNTIME_DIR="$JOURNAL_ABSENCE_SANDBOX/run" \
    /bin/bash -c '
        TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
        journal_entry 192.200.0.0/24 >/dev/null 2>&1
        [ "$?" = 1 ] || exit 1
    ' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: an absent journal was reported as unreadable\n' >&2
    exit 1
}
rm -rf "$JOURNAL_ABSENCE_SANDBOX"

printf 'route_transaction=PASS\n'