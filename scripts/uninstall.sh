#!/usr/bin/env bash
set -euo pipefail
umask 077

if [ -n "${DESTDIR:-}" ]; then
    [ -d "$DESTDIR" ] && [ ! -L "$DESTDIR" ] || {
        printf 'error: unsafe DESTDIR: %s\n' "$DESTDIR" >&2
        exit 1
    }
    ROOT=$(cd "$DESTDIR" && pwd -P)
    [ "$ROOT" != / ] || {
        printf 'error: DESTDIR must not resolve to /\n' >&2
        exit 1
    }
else
    ROOT=
fi
PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
UNINSTALL_ARG_COUNT=$#
UNINSTALL_ARGS=("$@")
SERVICE_LABEL=io.github.andredezzy.tailnet-keeper
MODULE_DIR="$ROOT/usr/local/libexec/tailnet-keeper"
KEEPER_TARGET="$MODULE_DIR/tailnet-keeper"
PF_TARGET="$ROOT/etc/pf.anchors/tailnet-keeper"
PLIST_TARGET="$ROOT/Library/LaunchDaemons/$SERVICE_LABEL.plist"
CONFIG_TARGET="$ROOT/usr/local/etc/tailnet-keeper.conf"
STATE_DIR="$ROOT/var/db/tailnet-keeper"
MANIFEST_TARGET="$STATE_DIR/install-manifest"
TRANSACTION_CONTROL_DIR="$ROOT/var/db/tailnet-keeper-transactions"
INSTALL_LOCK="$TRANSACTION_CONTROL_DIR/install.lock"
MODULES=(common.sh routes.sh firewall.sh tailscale.sh derp.sh)
FORCE=0
PURGE=0

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        --purge) PURGE=1 ;;
        *) fail 'usage: uninstall.sh [--force] [--purge]' ;;
    esac
    shift
done

path_has_acl() {
    /bin/ls -lde "$1" 2>/dev/null |
        /usr/bin/awk 'NR > 1 && $1 ~ /^[0-9]+:/ { found=1 } END { exit !found }'
}

transaction_control_is_safe() {
    local current=$TRANSACTION_CONTROL_DIR boundary=${ROOT:-/} expected_target link_target mode
    while :; do
        if [ -L "$current" ]; then
            case "$current" in
                "$ROOT/var") expected_target=private/var ;;
                *) return 1 ;;
            esac
            link_target=$(/usr/bin/readlink "$current")
            [ "$link_target" = "$expected_target" ] || return 1
            if [ -z "$ROOT" ]; then
                [ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$current")" = root:wheel:755 ] || return 1
            fi
            current="$ROOT/$expected_target"
            continue
        fi
        [ -d "$current" ] || return 1
        ! path_has_acl "$current" || return 1
        mode=$(/usr/bin/stat -f %Lp "$current")
        (( (8#$mode & 0022) == 0 )) || return 1
        if [ "$current" = "$TRANSACTION_CONTROL_DIR" ]; then
            [ "$mode" = 700 ] || return 1
        fi
        if [ -z "$ROOT" ]; then
            [ "$(/usr/bin/stat -f '%Su:%Sg' "$current")" = root:wheel ] || return 1
        fi
        [ "$current" != "$boundary" ] && [ "$current" != / ] || break
        current=$(/usr/bin/dirname "$current")
    done
}

transaction_control_is_safe || fail 'installer lock directory is missing or unsafe'
# `-k` keeps the lock pathname on release. The marker and a busy lock are
# individually caller-forgeable, so the child requires its direct lockf parent
# to have this exact file open as well.
parent_holds_install_lock() {
    [ "$(/bin/ps -p "$PPID" -o comm= | /usr/bin/xargs)" = /usr/bin/lockf ] || return 1
    /usr/sbin/lsof -a -p "$PPID" -- "$INSTALL_LOCK" >/dev/null 2>&1 || return 1
    ! /usr/bin/lockf -t 0 -k "$INSTALL_LOCK" /usr/bin/true 2>/dev/null
}

if [ "${TAILNET_KEEPER_INSTALL_LOCKED:-0}" != 1 ]; then
    if [ "$UNINSTALL_ARG_COUNT" -eq 0 ]; then
        exec /usr/bin/lockf -t 0 -k "$INSTALL_LOCK" /usr/bin/env TAILNET_KEEPER_INSTALL_LOCKED=1 "$0"
    fi
    exec /usr/bin/lockf -t 0 -k "$INSTALL_LOCK" /usr/bin/env TAILNET_KEEPER_INSTALL_LOCKED=1 "$0" "${UNINSTALL_ARGS[@]}"
fi
parent_holds_install_lock || fail 'this process does not own the install lock'

allowed_managed_path() {
    local path=$1
    case "$path" in
        "$KEEPER_TARGET"|"$PF_TARGET"|"$PLIST_TARGET") return 0 ;;
    esac
    local module
    for module in "${MODULES[@]}"; do
        [ "$path" != "$MODULE_DIR/$module" ] || return 0
    done
    return 1
}

# Hashes and textual paths still validate when a managed directory is replaced
# by a symlink, so deletion would follow it outside the managed tree. Every
# ancestor must therefore be a real directory.
#
# macOS ships /etc and /var as root-owned symlinks into /private, so those two
# are recognized explicitly — by exact link target, and by root:wheel 0755
# ownership on a real system — and the walk continues through the target.
managed_ancestors_are_real() {
    local current boundary=${ROOT:-/} expected_target link_target
    current=$(/usr/bin/dirname "$1")
    while :; do
        if [ -L "$current" ]; then
            case "$current" in
                "$ROOT/etc") expected_target=private/etc ;;
                "$ROOT/var") expected_target=private/var ;;
                *) fail "symlinked ancestor of a managed path: $current" ;;
            esac
            link_target=$(/usr/bin/readlink "$current")
            [ "$link_target" = "$expected_target" ] || fail "unexpected system symlink target: $current"
            if [ -z "$ROOT" ]; then
                [ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$current")" = root:wheel:755 ] || fail "unsafe system symlink: $current"
            fi
            current="$ROOT/$expected_target"
            continue
        fi
        [ -d "$current" ] || fail "missing ancestor of a managed path: $current"
        [ "$current" != "$boundary" ] && [ "$current" != / ] || break
        current=$(/usr/bin/dirname "$current")
    done
}

expected_managed_paths() {
    printf '%s\n' "$KEEPER_TARGET" "$PF_TARGET" "$PLIST_TARGET"
    local module
    for module in "${MODULES[@]}"; do printf '%s\n' "$MODULE_DIR/$module"; done
}

# `shasum` writes "<hash>  <path>", and a managed path may contain spaces, so
# the hash is a fixed-width prefix and everything after the separator is one
# path. Field splitting would silently truncate it.
manifest_paths() {
    /usr/bin/awk '{ print substr($0, 67) }' "$1"
}

manifest_declares_exact_paths() {
    local manifest=$1 declared expected
    declared=$(manifest_paths "$manifest" | /usr/bin/sort)
    expected=$(expected_managed_paths | /usr/bin/sort)
    [ "$declared" = "$expected" ]
}

manifest_has_terminating_newline() {
    [ "$(/usr/bin/tail -c 1 "$1" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ]
}

validate_project_source() {
    local source mode expected_mode module
    local -a project_sources=("$PROJECT_ROOT/bin/tailnet-keeper")
    for module in "${MODULES[@]}"; do project_sources+=("$PROJECT_ROOT/libexec/$module"); done
    for source in "${project_sources[@]}"; do
        [ -f "$source" ] && [ ! -L "$source" ] || fail "unsafe project source: $source"
        expected_mode=644
        [ "$source" != "$PROJECT_ROOT/bin/tailnet-keeper" ] || expected_mode=755
        mode=$(/usr/bin/stat -f '%Lp' "$source")
        [ "$mode" = "$expected_mode" ] || fail "unsafe project source mode: $source"
    done
}

# Written before the first deletion and cleared only once every managed file is
# gone. While it exists, a previous removal was interrupted, and already-absent
# managed files are expected rather than evidence of tampering.
REMOVAL_MARKER="$STATE_DIR/removal-in-progress"
RESUMING_REMOVAL=0
FINISHING_REMOVAL=0
if [ -e "$REMOVAL_MARKER" ] || [ -L "$REMOVAL_MARKER" ]; then
    [ -f "$REMOVAL_MARKER" ] && [ ! -L "$REMOVAL_MARKER" ] || fail 'removal marker is unsafe'
    ! path_has_acl "$REMOVAL_MARKER" || fail 'removal marker has an ACL'
    [ "$(/usr/bin/stat -f %Lp "$REMOVAL_MARKER")" = 600 ] || fail 'removal marker has an unsafe mode'
    if [ -z "$ROOT" ]; then
        [ "$(/usr/bin/stat -f '%Su:%Sg' "$REMOVAL_MARKER")" = root:wheel ] || fail 'removal marker has an unsafe owner'
    fi
    RESUMING_REMOVAL=1
fi

if [ ! -s "$MANIFEST_TARGET" ]; then
    # A marker without a manifest is the crash window between the two final
    # deletions: the managed files are already gone. Finish the removal rather
    # than reporting the package as absent, which no flag could recover from.
    [ "$RESUMING_REMOVAL" -eq 1 ] || fail "install manifest not found: $MANIFEST_TARGET"
    FINISHING_REMOVAL=1
else
    [ ! -L "$MANIFEST_TARGET" ] || fail 'install manifest must not be a symlink'
    if [ -z "$ROOT" ]; then
        [ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$MANIFEST_TARGET")" = root:wheel:600 ] || fail 'unsafe install manifest ownership or mode'
    fi
    manifest_has_terminating_newline "$MANIFEST_TARGET" || fail 'install manifest is missing its terminating newline'
    manifest_declares_exact_paths "$MANIFEST_TARGET" || fail 'install manifest does not declare the exact managed file set'

    while read -r line; do
        expected=${line:0:64}
        path=${line:66}
        [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail 'invalid install manifest hash'
        [ -n "$path" ] || fail 'invalid install manifest entry'
        allowed_managed_path "$path" || fail "unmanaged path in install manifest: $path"
        managed_ancestors_are_real "$path"
        # Outside a resumed removal, an absent managed file means the
        # installation no longer matches its manifest and must be inspected.
        if [ ! -e "$path" ] && [ ! -L "$path" ] && [ "$RESUMING_REMOVAL" -eq 1 ]; then
            continue
        fi
        [ -f "$path" ] && [ ! -L "$path" ] || fail "managed file is missing or unsafe: $path"
        if [ "$FORCE" -eq 0 ]; then
            actual=$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{ print $1 }')
            [ "$actual" = "$expected" ] || fail "managed file changed; inspect it or rerun with --force: $path"
        fi
    done <"$MANIFEST_TARGET"
fi

stop_loaded_service() {
    /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1 || return 0
    /bin/launchctl bootout --wait "system/$SERVICE_LABEL" >/dev/null 2>&1 &
    local bootout_pid=$! watchdog_pid result
    (
        /bin/sleep 60
        /bin/kill -TERM "$bootout_pid" 2>/dev/null || exit 0
        /bin/sleep 2
        /bin/kill -KILL "$bootout_pid" 2>/dev/null || true
    ) &
    watchdog_pid=$!
    if wait "$bootout_pid"; then result=0; else result=$?; fi
    /bin/kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    [ "$result" -eq 0 ] || return "$result"
    /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1 && return 1
    return 0
}

if [ -z "$ROOT" ]; then
    [ "$(/usr/bin/uname -s)" = Darwin ] || fail 'tailnet-keeper requires macOS'
    [ "$EUID" -eq 0 ] || fail 'run this uninstaller with sudo'
fi
# Finishing a crashed removal only deletes the marker: the managed files and
# the keeper it would run are already gone.
if [ -z "$ROOT" ] && [ "$FINISHING_REMOVAL" -eq 0 ]; then
    validate_project_source
    stop_loaded_service || fail 'could not stop the installed service'
    TAILNET_KEEPER_STATE_DIR="$STATE_DIR" \
    TAILNET_KEEPER_RUNTIME_DIR=/var/run/tailnet-keeper \
    TAILNET_KEEPER_RULES="$PF_TARGET" \
    TAILNET_KEEPER_CONFIG="$ROOT/usr/local/etc/tailnet-keeper.conf" \
        "$PROJECT_ROOT/bin/tailnet-keeper" --deactivate
    /bin/rm -rf /var/run/tailnet-keeper
fi

# Keep going after a failed deletion so one undeletable file cannot strand the
# rest, then report. The manifest is removed only when every file is gone, so a
# retry still sees the full file set.
removal_status=0
if [ "$RESUMING_REMOVAL" -eq 0 ]; then
    REMOVAL_MARKER_TEMP="$STATE_DIR/.removal-in-progress-$$"
    printf 'in-progress\n' >"$REMOVAL_MARKER_TEMP" || fail 'could not create removal marker'
    /bin/chmod 0600 "$REMOVAL_MARKER_TEMP" || fail 'could not protect removal marker'
    /bin/mv -f "$REMOVAL_MARKER_TEMP" "$REMOVAL_MARKER" || fail 'could not publish removal marker'
fi
if [ "$FINISHING_REMOVAL" -eq 0 ]; then
    while read -r line; do
        path=${line:66}
        /bin/rm -f "$path" 2>/dev/null || removal_status=1
        [ ! -e "$path" ] || removal_status=1
    done <"$MANIFEST_TARGET"
    [ "$removal_status" -eq 0 ] || fail 'some managed files could not be removed; resolve them and rerun the uninstaller'
    # Either deletion order leaves a recoverable crash window, so the entry gate
    # above accepts a marker without a manifest and finishes the removal.
    /bin/rm -f "$MANIFEST_TARGET" || fail 'the install manifest could not be removed; resolve it and rerun the uninstaller'
fi
/bin/rm -f "$REMOVAL_MARKER" || fail 'the removal marker could not be removed; resolve it and rerun the uninstaller'
# A crashed install leaves interrupted-install state behind. The installer
# adopts any it finds, so a later failed install would roll back onto a host
# this uninstall deliberately cleared. Removal ends that transaction too.
/bin/rm -rf "$STATE_DIR/install-transaction" || fail 'interrupted install state could not be removed; resolve it and rerun the uninstaller'
/bin/rmdir "$MODULE_DIR" 2>/dev/null || true

if [ "$PURGE" -eq 1 ]; then
    /bin/rm -f "$CONFIG_TARGET"
    /bin/rm -rf "$STATE_DIR"
    # The lock is held by this process's own lockf parent, so the inode stays
    # alive until it exits; removing the pathname completes the purge.
    /bin/rm -rf "$TRANSACTION_CONTROL_DIR"
fi
printf 'Removed %s\n' "$SERVICE_LABEL"
