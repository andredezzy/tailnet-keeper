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
    route_matches() { [ "$3" = 192.168.1.1 ]; }
    route_delete() { return 1; }
    route_add() { return 0; }
    ! restore_journaled_route 8.8.8.8 -inet 192.168.1.1 en0 198.51.100.1 en1

    route_delete() { return 0; }
    route_add() { return 1; }
    ! restore_journaled_route 8.8.8.8 -inet 192.168.1.1 en0 198.51.100.1 en1

    restored=
    route_matches() { [ "$3 $4" = "198.51.100.1 en1" ] && [ "$restored" = "198.51.100.1 en1" ]; }
    route_add() { restored="$3 $4"; }
    capture_specific_route() { return 0; }
    restore_journaled_route 8.8.8.8 -inet 192.168.1.1 en0 198.51.100.1 en1
    [ "$restored" = "198.51.100.1 en1" ]

    route_matches() { return 0; }
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

NETSTAT_FIXTURE="$SANDBOX/netstat-fixture"
printf '#!/bin/bash\nprintf "8.8.8.8 198.51.100.1 UGHRB en1\\n"\n' >"$NETSTAT_FIXTURE"
chmod 0755 "$NETSTAT_FIXTURE"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_NETSTAT="$NETSTAT_FIXTURE" \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    [ "$(capture_specific_route -inet 8.8.8.8)" = "198.51.100.1 en1 reject+blackhole" ]
    [ "$(network_route_details 192.200.0.0/24 <<EOF
   destination: 192.200.0.0
          mask: 255.255.255.0
       gateway: 198.51.100.1
     interface: en1
         flags: <UP,GATEWAY,STATIC,REJECT>
EOF
)" = "198.51.100.1 en1 reject" ]
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
    route_matches() {
        if [ "$3" = 192.168.1.1 ]; then return 0; fi
        [ "${5:-normal}" = reject ] && [ "$restored_policy" = reject ]
    }
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
    capture_specific_route() { printf "198.51.100.1 en1 reject\n"; }
    route_matches() { return 1; }
    ensure_owned_route() { return 0; }
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
    fallback="   route to: 203.0.113.77
destination: default
       mask: default
    gateway: 192.168.0.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC>"
    specific="   route to: 203.0.113.77
destination: 203.0.113.77
    gateway: 192.168.0.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC>"
    ! route_output_matches 203.0.113.77 192.168.0.1 en0 <<<"$fallback"
    route_output_matches 203.0.113.77 192.168.0.1 en0 <<<"$specific"

    # The journal key is expanded; the kernel replies compressed.
    compressed="   route to: 2607:f740:f::3d7
destination: 2607:f740:f::3d7
    gateway: fe80::1%en0
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC>"
    route_output_matches 2607:f740:f:0:0:0:0:3d7 "fe80::1%en0" en0 <<<"$compressed"
    ! route_output_matches 2607:f740:f:0:0:0:0:3d8 "fe80::1%en0" en0 <<<"$compressed"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf "FAIL: host matcher mishandled fallback or compressed IPv6\n" >&2
    exit 1
}

# capture_specific_route reads the same kernel spelling out of netstat.
NETSTAT_V6_FIXTURE="$SANDBOX/netstat-v6"
printf '#!/bin/bash\nprintf "2607:f740:f::3d7 fe80::1%%%%en0 UGHS en0\\n"\n' >"$NETSTAT_V6_FIXTURE"
chmod 0755 "$NETSTAT_V6_FIXTURE"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_NETSTAT="$NETSTAT_V6_FIXTURE" \
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

# Real kernel output shapes captured from macOS 26.6.2: a point-to-point
# gateway prints as "index: N ifname", an interface route prints no gateway
# line at all, and netstat renders some host routes with a /32 mask.
NETSTAT_SHAPES="$SANDBOX/netstat-shapes"
printf '#!/bin/bash\nprintf "8.8.8.8 utun5 UGHS utun5\\n198.51.100.77/32 192.168.0.1 UGHS en0\\n192.200.0.0/24 link#41 UCS utun4\\n"\n' >"$NETSTAT_SHAPES"
chmod 0755 "$NETSTAT_SHAPES"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_NETSTAT="$NETSTAT_SHAPES" \
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
    details=$(network_route_details 192.200.0.0/24 <<EOF
   destination: 192.200.0.0
          mask: 255.255.255.0
     interface: utun4
         flags: <UP,DONE,CLONING>
EOF
)
    [ "$details" = "interface#utun4 utun4 normal" ]

    # The same p2p route must match through route -n get, whose gateway line
    # carries the index prefix.
    route_output_matches 8.8.8.8 "interface#utun5" utun5 <<EOF
   route to: 8.8.8.8
destination: 8.8.8.8
    gateway: index: 42 utun5
  interface: utun5
      flags: <UP,GATEWAY,DONE,STATIC>
EOF

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

printf 'route_transaction=PASS\n'