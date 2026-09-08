#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-cleanup.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/state" "$SANDBOX/run"

run_case() {
    local clear_result=$1
    local restore_result=$2
    local expected_status=$3
    local expected_journal=$4
    printf '8.8.8.8|-inet|192.168.1.1|en0|-|-\n' >"$SANDBOX/state/routes"
    TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
    TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
    bash -c '
        set -euo pipefail
        source "$1"
        clear_status=$2
        restore_status=$3
        clear_anchor() { return "$clear_status"; }
        restore_journaled_route() { return "$restore_status"; }
        status=0
        fail_closed || status=$?
        [ "$status" -eq "$4" ]
        [ "$(cat "$ROUTE_JOURNAL")" = "$5" ]
    ' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$clear_result" "$restore_result" "$expected_status" "$expected_journal"
}

# A retained six-field entry is upgraded to its canonical seven-field form.
route='8.8.8.8|-inet|192.168.1.1|en0|-|-|normal'
run_case 1 0 1 '' || { printf 'FAIL: PF cleanup failure was hidden\n' >&2; exit 1; }
run_case 0 1 1 "$route" || { printf 'FAIL: failed route restore lost ownership evidence\n' >&2; exit 1; }
run_case 0 0 0 '' || { printf 'FAIL: successful cleanup did not commit\n' >&2; exit 1; }

# A journal that cannot be read must not look like an empty one: replacing the
# live journal after zero restores would destroy every ownership record.
printf '8.8.8.8|-inet|192.168.1.1|en0|-|-|normal\n' >"$SANDBOX/state/routes"
chmod 000 "$SANDBOX/state/routes"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -uo pipefail
    source "$1"
    clear_anchor() { return 0; }
    restore_journaled_route() { printf restored >"$2/unexpected-restore"; return 0; }
    ! fail_closed
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX" || {
    chmod 600 "$SANDBOX/state/routes"
    printf 'FAIL: an unreadable journal was treated as an empty one\n' >&2
    exit 1
}
chmod 600 "$SANDBOX/state/routes"
[ ! -e "$SANDBOX/unexpected-restore" ] || { printf 'FAIL: cleanup restored from an unreadable journal\n' >&2; exit 1; }
[ "$(cat "$SANDBOX/state/routes")" = '8.8.8.8|-inet|192.168.1.1|en0|-|-|normal' ] || {
    printf 'FAIL: an unreadable journal was erased\n' >&2
    exit 1
}
/bin/rm -f deactivation_cleanup_failed.health deactivated.health

TAILNET_KEEPER_TESTING=1 bash -c '
    set -euo pipefail
    source "$1"
    output=$2
    fail_closed() { return 1; }
    log_error() { printf "%s\n" "$1" >"$output"; }
    fail_safely source_rules_missing
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX/failure-detail"
[ "$(cat "$SANDBOX/failure-detail")" = source_rules_missing_cleanup_failed ] || {
    printf 'FAIL: cleanup failure did not reach health detail\n' >&2
    exit 1
}

TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    fail_closed() { return 1; }
    write_health() { printf "%s:%s\n" "$1" "$2" >"$2.health"; }
    log_error() { write_health degraded "$1"; }
    status=0
    main --deactivate || status=$?
    [ "$status" -ne 0 ]
    [ -f deactivation_cleanup_failed.health ]
    [ ! -f deactivated.health ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: failed deactivation reported inactive\n' >&2
    exit 1
}
/bin/rm -f deactivation_cleanup_failed.health deactivated.health

# Deactivation removes every route the keeper is responsible for, not only the
# ones the journal still lists. An interrupted transaction can leave a placed
# relay route in the kernel with no journal entry: the journal was rewritten
# before the route was, or the route survived a rollback that did not know
# its scope. Those routes are the cached relay addresses through the uplink
# gateway, and leaving them behind strands the relay set on a stale gateway
# after the next network change while nothing owns them any more.
ORPHAN_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-orphan.XXXXXX")
mkdir -p "$ORPHAN_SANDBOX/state" "$ORPHAN_SANDBOX/run"
: >"$ORPHAN_SANDBOX/state/routes"
printf '172.237.61.190\n172.237.61.194\n' >"$ORPHAN_SANDBOX/state/derp-ipv4"
printf '2606:b740:1::104\n' >"$ORPHAN_SANDBOX/state/derp-ipv6"
cat >"$ORPHAN_SANDBOX/table-inet" <<'TABLE'
default            192.168.0.1        UGScg                 en0
172.237.61.190     192.168.0.1        UGHSI                 en0
172.237.61.194     192.168.0.1        UGHS                  en0
192.168.0.7        a:b:c:d:e:f        UHLWI                 en0
TABLE
cat >"$ORPHAN_SANDBOX/table-inet6" <<'TABLE'
default                                 fe80::1%en0                             UGcg                  en0
2606:b740:1::104                        fe80::1%en0                             UGHSI                 en0
TABLE
printf '#!/bin/bash\ncase "$*" in *inet6*) cat "%s/table-inet6" ;; *) cat "%s/table-inet" ;; esac\n' \
    "$ORPHAN_SANDBOX" "$ORPHAN_SANDBOX" >"$ORPHAN_SANDBOX/netstat"
cat >"$ORPHAN_SANDBOX/route" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$ORPHAN_LOG"
case "$*" in
    *get*172.237.61.190*) printf '   route to: 172.237.61.190\ndestination: 172.237.61.190\n    gateway: 192.168.0.1\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,STATIC,IFSCOPE>\n' ;;
    *get*172.237.61.194*) printf '   route to: 172.237.61.194\ndestination: 172.237.61.194\n    gateway: 192.168.0.1\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,STATIC>\n' ;;
    *get*2606:b740:1::104*) printf '   route to: 2606:b740:1::104\ndestination: 2606:b740:1::104\n    gateway: fe80::1%%en0\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,STATIC,IFSCOPE>\n' ;;
esac
exit 0
STUB
chmod 0755 "$ORPHAN_SANDBOX/netstat" "$ORPHAN_SANDBOX/route"
ORPHAN_LOG="$ORPHAN_SANDBOX/calls" TAILNET_KEEPER_TESTING=1 \
    TAILNET_KEEPER_NETSTAT="$ORPHAN_SANDBOX/netstat" TAILNET_KEEPER_ROUTE="$ORPHAN_SANDBOX/route" \
    TAILNET_KEEPER_PFCTL=/usr/bin/true \
    TAILNET_KEEPER_STATE_DIR="$ORPHAN_SANDBOX/state" TAILNET_KEEPER_RUNTIME_DIR="$ORPHAN_SANDBOX/run" \
    bash -c '
        source "$1"
        physical_interface=en0
        physical_ipv4_gateway=192.168.0.1
        physical_ipv6_gateway="fe80::1%en0"
        fail_closed
    ' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: deactivation failed with orphaned relay routes in the table\n' >&2
    exit 1
}
grep -q -- 'delete -inet -host -ifscope en0 172.237.61.190' "$ORPHAN_SANDBOX/calls" || {
    printf 'FAIL: a scoped orphan relay route was not removed on deactivation\n' >&2
    exit 1
}
grep -q -- 'delete -inet -host 172.237.61.194' "$ORPHAN_SANDBOX/calls" || {
    printf 'FAIL: an unscoped orphan relay route was not removed on deactivation\n' >&2
    exit 1
}
grep -q -- 'delete -inet6 -host -ifscope en0 2606:b740:1::104' "$ORPHAN_SANDBOX/calls" || {
    printf 'FAIL: an IPv6 orphan relay route was not removed on deactivation\n' >&2
    exit 1
}
if grep -- 'delete' "$ORPHAN_SANDBOX/calls" | grep -q '192.168.0.7'; then
    printf 'FAIL: deactivation removed a neighbour entry the keeper never placed\n' >&2
    exit 1
fi
rm -rf "$ORPHAN_SANDBOX"

printf 'cleanup_transaction=PASS\n'
