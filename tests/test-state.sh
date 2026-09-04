#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-state.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
mkdir "$SANDBOX/target"
chmod 0755 "$SANDBOX/target"
ln -s "$SANDBOX/target" "$SANDBOX/run"

TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    source "$1"
    ! prepare_directories
    [ "$(stat -f %Lp "$2/target")" = 755 ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX" || {
    printf 'FAIL: state preparation followed an untrusted symlink\n' >&2
    exit 1
}

rm "$SANDBOX/run"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -euo pipefail
    source "$1"
    prepare_directories
    prepare_runtime_state
    physical_interface=en0
    physical_ipv4_gateway=192.0.2.1
    physical_ipv6_gateway=
    tailscale_interface=utun0
    write_health healthy test
    grep -qx "process_id=$$" "$HEALTH_STATE"
    [ "$(stat -f %Lp "$STATE_DIR")" = 700 ]
    [ "$(stat -f %Lp "$RUNTIME_DIR")" = 700 ]
    printf rules >"$2/rules"
    chmod 0644 "$2/rules"
    trusted_root_file "$2/rules" 644
    chmod 0666 "$2/rules"
    ! trusted_root_file "$2/rules" 644
    ln -s "$2/rules" "$2/rules-link"
    ! trusted_root_file "$2/rules-link" 644

    prepare_state_file "$2/state/new-cache"
    [ "$(stat -f %Lp "$2/state/new-cache")" = 600 ]
    ln -s "$2/target" "$2/state/cache-link"
    ! prepare_state_file "$2/state/cache-link"

    : >"$2/empty-config"
    file_has_terminating_newline "$2/empty-config"
    printf "key=value\n" >"$2/terminated-config"
    file_has_terminating_newline "$2/terminated-config"
    printf "key=value" >"$2/unterminated-config"
    ! file_has_terminating_newline "$2/unterminated-config"

    lock="$2/worker.lock"
    with_lock "$lock" /bin/sleep 2 &
    holder=$!
    /bin/sleep 0.2
    ! with_lock "$lock" /usr/bin/true 2>/dev/null
    wait "$holder"
    with_lock "$lock" /usr/bin/true
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX" || {
    printf 'FAIL: state preparation rejected safe directories\n' >&2
    exit 1
}

prepare_state_line=$(awk '/prepare_runtime_state/ { print NR; exit }' "$PROJECT_ROOT/bin/tailnet-keeper")
load_config_line=$(awk '/if ! load_config/ { print NR; exit }' "$PROJECT_ROOT/bin/tailnet-keeper")
[ -n "$prepare_state_line" ] && [ "$prepare_state_line" -lt "$load_config_line" ] || {
    printf 'FAIL: runtime state is not prepared before reconciliation\n' >&2
    exit 1
}

printf 'state_directories=PASS\n'
