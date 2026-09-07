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

# A directory created under /var/run inherits that parent's group, and macOS
# ships /var/run as root:daemon. Demanding a wheel group rejected the runtime
# directory the keeper had just created, so the daemon died before it could
# reconcile anything. At 0700 the group grants no access, so owner and mode
# are the invariant that matters.
TAILNET_KEEPER_TESTING=1 bash -c '
    source "$1"
    directory_ownership_is_private root:daemon:700 root || exit 1
    directory_ownership_is_private root:wheel:700 root || exit 1
    ! directory_ownership_is_private root:wheel:750 root || exit 1
    ! directory_ownership_is_private "$(id -un):staff:700" root || exit 1
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: a runtime directory inheriting the /var/run group was rejected\n' >&2
    exit 1
}

DIRECTORY_MODE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-dirmode.XXXXXX")
mkdir -p "$DIRECTORY_MODE_SANDBOX/run"
chmod 0775 "$DIRECTORY_MODE_SANDBOX/run"
TAILNET_KEEPER_TESTING=1 bash -c '
    source "$1"
    prepare_directory "$2/run/tailnet-keeper"
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$DIRECTORY_MODE_SANDBOX" || {
    printf 'FAIL: the keeper could not prepare a directory under a group-writable parent\n' >&2
    exit 1
}
[ "$(stat -f %Lp "$DIRECTORY_MODE_SANDBOX/run/tailnet-keeper")" = 700 ] || {
    printf 'FAIL: the runtime directory is not private\n' >&2
    exit 1
}
rm -rf "$DIRECTORY_MODE_SANDBOX"

# A test that pins the rules file but not the config reads the installed
# /usr/local/etc/tailnet-keeper.conf, which is root-only. The suite then
# passes or fails depending on whether the package happens to be installed on
# the machine running it, which is not a property of the code under test.
for suite in "$PROJECT_ROOT"/tests/*.sh; do
    awk -v name="$(basename "$suite")" '
        /TAILNET_KEEPER_RULES=/ { rules[NR] = 1 }
        /TAILNET_KEEPER_CONFIG=/ { config[NR] = 1 }
        END {
            for (line in rules) {
                found = 0
                for (near = line - 8; near <= line + 8; near++) if (near in config) found = 1
                if (!found) { printf "%s:%d\n", name, line; status = 1 }
            }
            exit status
        }
    ' "$suite" || fail 'a suite reads the installed config instead of a sandboxed one'
done

# lockf without -k unlinks the lock pathname when its child exits. A run cut
# short mid-flight then leaves the kernel lock held against a pathname that no
# longer exists, and every later launch is refused with "already locked" while
# no process holds anything -- a daemon that can never start again.
grep -q 'LOCKF" -t 0 -k' "$PROJECT_ROOT/libexec/common.sh" ||
    fail 'the worker lock does not survive its own release'
LOCK_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-worklock.XXXXXX")
/usr/bin/lockf -t 0 -k "$LOCK_SANDBOX/worker.lock" /usr/bin/true
[ -e "$LOCK_SANDBOX/worker.lock" ] ||
    fail 'the lock pathname vanished after the holder exited'
/usr/bin/lockf -t 0 -k "$LOCK_SANDBOX/worker.lock" /usr/bin/true ||
    fail 'a released lock could not be acquired again'
rm -rf "$LOCK_SANDBOX"

printf 'state_directories=PASS\n'
