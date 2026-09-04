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

printf 'cleanup_transaction=PASS\n'
