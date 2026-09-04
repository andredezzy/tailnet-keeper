#!/usr/bin/env bash
set -euo pipefail
umask 077

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALL_ARG_COUNT=$#
INSTALL_ARGS=("$@")
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
SERVICE_LABEL=io.github.andredezzy.tailnet-keeper
MODULE_DIR="$ROOT/usr/local/libexec/tailnet-keeper"
KEEPER_TARGET="$MODULE_DIR/tailnet-keeper"
PF_TARGET="$ROOT/etc/pf.anchors/tailnet-keeper"
PLIST_TARGET="$ROOT/Library/LaunchDaemons/$SERVICE_LABEL.plist"
CONFIG_TARGET="$ROOT/usr/local/etc/tailnet-keeper.conf"
STATE_DIR="$ROOT/var/db/tailnet-keeper"
MANIFEST_TARGET="$STATE_DIR/install-manifest"
REMOVAL_MARKER="$STATE_DIR/removal-in-progress"
TRANSACTION_CONTROL_DIR="$ROOT/var/db/tailnet-keeper-transactions"
INSTALL_LOCK="$TRANSACTION_CONTROL_DIR/install.lock"
# The snapshot lives in the transaction-control directory rather than in
# STATE_DIR, because
# recovering an interrupted install can remove STATE_DIR entirely and would
# otherwise delete the sources this run still has to publish.
SOURCE_SNAPSHOT_DIR="$TRANSACTION_CONTROL_DIR/sources-$$"
BACKUP_DIR="$STATE_DIR/backups/$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
NEXT_BACKUP_DIR=$BACKUP_DIR
TRANSACTION_DIR="$STATE_DIR/install-transaction"
STAGING_TRANSACTION_DIR="$STATE_DIR/.install-staging-$$"
SOURCE_DIR=$PROJECT_ROOT
ROLLBACK_DIR="$TRANSACTION_DIR/previous-targets"
MODULES=(common.sh routes.sh firewall.sh tailscale.sh derp.sh)
TARGETS=("$KEEPER_TARGET" "$PF_TARGET" "$PLIST_TARGET" "$CONFIG_TARGET")
for module in "${MODULES[@]}"; do TARGETS+=("$MODULE_DIR/$module"); done

ROLLBACK_NEEDED=0
SERVICE_WAS_LOADED=0
STATE_DIR_WAS_PRESENT=0
BOOT_RECOVERY_SETTING=preserve
CONFIG_TEMP=

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --enable-boot-recovery) BOOT_RECOVERY_SETTING=on ;;
        --disable-boot-recovery) BOOT_RECOVERY_SETTING=off ;;
        --help|-h)
            printf 'Usage: sudo scripts/install.sh [--enable-boot-recovery|--disable-boot-recovery]\n'
            exit 0
            ;;
        *) fail "unknown argument: $1" ;;
    esac
    shift
done

if [ -z "$ROOT" ]; then
    [ "$(/usr/bin/uname -s)" = Darwin ] || fail 'tailnet-keeper requires macOS'
    [ "$EUID" -eq 0 ] || fail 'run this installer with sudo'
    /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1 && SERVICE_WAS_LOADED=1 || true
fi
if [ -z "$ROOT" ] && [ "$SERVICE_WAS_LOADED" -eq 1 ]; then
    [ -f "$PLIST_TARGET" ] && [ ! -L "$PLIST_TARGET" ] || fail 'loaded service has no restorable plist'
fi
[ -d "$STATE_DIR" ] && STATE_DIR_WAS_PRESENT=1

validate_source() {
    local path=$1
    local mode=$2
    [ -f "$path" ] && [ ! -L "$path" ] || fail "unsafe source file: $path"
    [ "$(/usr/bin/stat -f %Lp "$path")" = "$mode" ] || fail "unexpected source mode: $path"
}

path_has_acl() {
    /bin/ls -lde "$1" 2>/dev/null |
        /usr/bin/awk 'NR > 1 && $1 ~ /^[0-9]+:/ { found=1 } END { exit !found }'
}

installed_file_is_safe() {
    local path=$1
    local mode=$2
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    ! path_has_acl "$path" || return 1
    [ "$(/usr/bin/stat -f %Lp "$path")" = "$mode" ] || return 1
    [ -n "$ROOT" ] || [ "$(/usr/bin/stat -f '%Su:%Sg' "$path")" = root:wheel ]
}

validate_installed() {
    local path=$1
    local mode=$2
    installed_file_is_safe "$path" "$mode" || fail "unsafe installed file, owner, or mode: $path"
}

managed_target_mode() {
    case "$1" in
        "$KEEPER_TARGET") printf '755\n' ;;
        "$CONFIG_TARGET") printf '600\n' ;;
        "$PF_TARGET"|"$PLIST_TARGET"|"$MODULE_DIR"/*.sh) printf '644\n' ;;
        *) return 1 ;;
    esac
}

validate_destination_path() {
    local current=$1
    local boundary=${ROOT:-/}
    local link_target expected_target
    while :; do
        if [ -L "$current" ]; then
            case "$current" in
                "$ROOT/etc") expected_target=private/etc ;;
                "$ROOT/var") expected_target=private/var ;;
                *) fail "symlinked destination directory: $current" ;;
            esac
            link_target=$(/usr/bin/readlink "$current")
            [ "$link_target" = "$expected_target" ] || fail "unexpected system symlink target: $current"
            if [ -z "$ROOT" ]; then
                [ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$current")" = root:wheel:755 ] || fail "unsafe system symlink: $current"
            fi
            current="$ROOT/$expected_target"
            continue
        fi
        [ ! -e "$current" ] || [ -d "$current" ] || fail "non-directory destination component: $current"
        if [ -d "$current" ]; then
            local directory_mode
            ! path_has_acl "$current" || fail "ACL on destination ancestor: $current"
            directory_mode=$(/usr/bin/stat -f %Lp "$current")
            (( (8#$directory_mode & 0022) == 0 )) || fail "writable destination ancestor: $current"
            if [ -z "$ROOT" ]; then
                [ "$(/usr/bin/stat -f '%Su:%Sg' "$current")" = root:wheel ] || fail "unsafe destination ancestor owner: $current"
            fi
        fi
        [ "$current" != "$boundary" ] && [ "$current" != / ] || break
        current=$(/usr/bin/dirname "$current")
    done
}

validate_installed_directory() {
    local path=$1
    local mode=$2
    [ -d "$path" ] && [ ! -L "$path" ] || fail "unsafe installed directory: $path"
    ! path_has_acl "$path" || fail "unexpected installed directory ACL: $path"
    [ "$(/usr/bin/stat -f %Lp "$path")" = "$mode" ] || fail "unexpected installed directory mode: $path"
    if [ -z "$ROOT" ]; then
        [ "$(/usr/bin/stat -f '%Su:%Sg' "$path")" = root:wheel ] || fail "unexpected installed directory owner: $path"
    fi
}

validate_source "$PROJECT_ROOT/bin/tailnet-keeper" 755
for module in "${MODULES[@]}"; do validate_source "$PROJECT_ROOT/libexec/$module" 644; done
validate_source "$PROJECT_ROOT/tailnet-keeper.pf" 644
validate_source "$PROJECT_ROOT/launchd/$SERVICE_LABEL.plist" 644
validate_source "$PROJECT_ROOT/tailnet-keeper.conf.example" 644

# Copies every source into a private snapshot and validates the copies.
# Everything installed afterwards is read from the snapshot, so a source
# rewritten while the installer holds the lock cannot reach a privileged
# target. Callable only after the lock is held.
snapshot_sources() {
    /bin/rm -rf "$SOURCE_SNAPSHOT_DIR"
    /usr/bin/install -d -m 0700 "$SOURCE_SNAPSHOT_DIR/bin" "$SOURCE_SNAPSHOT_DIR/libexec" "$SOURCE_SNAPSHOT_DIR/launchd"
    /usr/bin/install -m 0755 "$PROJECT_ROOT/bin/tailnet-keeper" "$SOURCE_SNAPSHOT_DIR/bin/tailnet-keeper"
    local module
    for module in "${MODULES[@]}"; do
        /usr/bin/install -m 0644 "$PROJECT_ROOT/libexec/$module" "$SOURCE_SNAPSHOT_DIR/libexec/$module"
    done
    /usr/bin/install -m 0644 "$PROJECT_ROOT/tailnet-keeper.pf" "$SOURCE_SNAPSHOT_DIR/tailnet-keeper.pf"
    /usr/bin/install -m 0644 "$PROJECT_ROOT/launchd/$SERVICE_LABEL.plist" "$SOURCE_SNAPSHOT_DIR/launchd/$SERVICE_LABEL.plist"
    /usr/bin/install -m 0644 "$PROJECT_ROOT/tailnet-keeper.conf.example" "$SOURCE_SNAPSHOT_DIR/tailnet-keeper.conf.example"

    SOURCE_DIR=$SOURCE_SNAPSHOT_DIR
    validate_source "$SOURCE_DIR/bin/tailnet-keeper" 755
    for module in "${MODULES[@]}"; do validate_source "$SOURCE_DIR/libexec/$module" 644; done
    validate_source "$SOURCE_DIR/tailnet-keeper.pf" 644
    validate_source "$SOURCE_DIR/launchd/$SERVICE_LABEL.plist" 644
    validate_source "$SOURCE_DIR/tailnet-keeper.conf.example" 644
    /bin/bash -n "$SOURCE_DIR/bin/tailnet-keeper" "$SOURCE_DIR"/libexec/*.sh
    /usr/bin/plutil -lint "$SOURCE_DIR/launchd/$SERVICE_LABEL.plist" >/dev/null
}

validate_destination_path "$STATE_DIR"
validate_destination_path "$MODULE_DIR"
validate_destination_path "$(/usr/bin/dirname "$PF_TARGET")"
validate_destination_path "$(/usr/bin/dirname "$PLIST_TARGET")"
validate_destination_path "$(/usr/bin/dirname "$CONFIG_TARGET")"
validate_destination_path "$TRANSACTION_CONTROL_DIR"
/usr/bin/install -d -m 0700 "$TRANSACTION_CONTROL_DIR"
validate_installed_directory "$TRANSACTION_CONTROL_DIR" 700
# `lockf -k` keeps the lock pathname on exit. Without it the file is unlinked
# at release, so a second installer can create and lock a fresh inode while the
# first still runs, and two privileged transactions overlap.
#
# The marker and a busy lock are individually caller-forgeable. The child also
# requires its direct lockf parent to have this exact file open.
parent_holds_install_lock() {
    [ "$(/bin/ps -p "$PPID" -o comm= | /usr/bin/xargs)" = /usr/bin/lockf ] || return 1
    /usr/sbin/lsof -a -p "$PPID" -- "$INSTALL_LOCK" >/dev/null 2>&1 || return 1
    ! /usr/bin/lockf -t 0 -k "$INSTALL_LOCK" /usr/bin/true 2>/dev/null
}

if [ "${TAILNET_KEEPER_INSTALL_LOCKED:-0}" != 1 ]; then
    if [ "$INSTALL_ARG_COUNT" -eq 0 ]; then
        exec /usr/bin/lockf -t 0 -k "$INSTALL_LOCK" /usr/bin/env TAILNET_KEEPER_INSTALL_LOCKED=1 "$0"
    fi
    exec /usr/bin/lockf -t 0 -k "$INSTALL_LOCK" /usr/bin/env TAILNET_KEEPER_INSTALL_LOCKED=1 "$0" "${INSTALL_ARGS[@]}"
fi
parent_holds_install_lock || fail 'this process does not own the install lock'
/usr/bin/install -d -m 0700 "$STATE_DIR"
validate_installed_directory "$STATE_DIR" 700
snapshot_sources
if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ] && [ "${TAILNET_KEEPER_TEST_HOLD_LOCK:-0}" = 1 ]; then
    : >"$STATE_DIR/install-lock-held"
    /bin/sleep 2
    /bin/rm -f "$STATE_DIR/install-lock-held"
fi

backup_if_changed() {
    local source=$1
    local target=$2
    local relative destination
    [ -f "$target" ] || return 0
    /usr/bin/cmp -s "$source" "$target" && return 0
    relative=${target#"$ROOT"/}
    destination="$BACKUP_DIR/$relative"
    /usr/bin/install -d -m 0700 "$(/usr/bin/dirname "$destination")"
    /bin/cp -p "$target" "$destination"
}

wait_for_healthy_state() {
    local status
    for _ in {1..60}; do
        if [ -f "$STATE_DIR/health" ] && [ ! -L "$STATE_DIR/health" ]; then
            if [ -n "$ROOT" ] || [ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$STATE_DIR/health")" = root:wheel:600 ]; then
                status=$(/usr/bin/awk -F= '$1 == "status" { print $2; exit }' "$STATE_DIR/health" 2>/dev/null || true)
                [ "$status" != healthy ] || return 0
                [ "$status" != degraded ] || return 1
            fi
        fi
        /bin/sleep 2
    done
    return 1
}

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

restore_backup_atomically() {
    local backup=$1
    local target=$2
    local temporary
    temporary=$(/usr/bin/mktemp "$target.rollback.XXXXXX") || return 1
    if ! /bin/cp -p "$backup" "$temporary"; then
        /bin/rm -f "$temporary"
        return 1
    fi
    if ! /bin/mv "$temporary" "$target"; then
        /bin/rm -f "$temporary"
        return 1
    fi
    /usr/bin/cmp -s "$backup" "$target"
}

rollback_install() {
    local target relative backup status=0
    [ -z "$CONFIG_TEMP" ] || /bin/rm -f "$CONFIG_TEMP" || status=1
    if [ -z "$ROOT" ]; then
        stop_loaded_service || return 1
        TAILNET_KEEPER_STATE_DIR="$STATE_DIR" \
        TAILNET_KEEPER_RUNTIME_DIR=/var/run/tailnet-keeper \
        TAILNET_KEEPER_RULES="$PF_TARGET" \
        TAILNET_KEEPER_CONFIG="$CONFIG_TARGET" \
            "$SOURCE_DIR/bin/tailnet-keeper" --deactivate >/dev/null 2>&1 || status=1
    fi

    for target in "${TARGETS[@]}"; do
        relative=${target#"$ROOT"/}
        backup="$ROLLBACK_DIR/$relative"
        if [ -f "$backup" ]; then
            /usr/bin/install -d -m 0755 "$(/usr/bin/dirname "$target")" || status=1
            restore_backup_atomically "$backup" "$target" || status=1
        elif /usr/bin/grep -Fxq "$target" "$TRANSACTION_DIR/new-targets"; then
            /bin/rm -f "$target" || status=1
        fi
    done
    if [ -f "$TRANSACTION_DIR/previous-manifest" ]; then
        restore_backup_atomically "$TRANSACTION_DIR/previous-manifest" "$MANIFEST_TARGET" || status=1
    else
        /bin/rm -f "$MANIFEST_TARGET" || status=1
    fi
    if [ -f "$TRANSACTION_DIR/previous-removal-marker" ]; then
        restore_backup_atomically "$TRANSACTION_DIR/previous-removal-marker" "$REMOVAL_MARKER" || status=1
    else
        /bin/rm -f "$REMOVAL_MARKER" || status=1
    fi
    for target in "${TARGETS[@]}"; do
        relative=${target#"$ROOT"/}
        backup="$ROLLBACK_DIR/$relative"
        [ ! -f "$backup" ] || installed_file_is_safe "$target" "$(managed_target_mode "$target")" || status=1
    done
    if [ "$status" -eq 0 ] && [ -z "$ROOT" ] && [ "$SERVICE_WAS_LOADED" -eq 1 ] && [ -f "$PLIST_TARGET" ]; then
        /bin/rm -f "$STATE_DIR/health" || status=1
        if /bin/launchctl bootstrap system "$PLIST_TARGET" >/dev/null 2>&1; then
            wait_for_healthy_state || status=1
        else
            status=1
        fi
    fi
    if [ "$status" -eq 0 ]; then
        /bin/rm -rf "$BACKUP_DIR" "$TRANSACTION_DIR"
        [ "$STATE_DIR_WAS_PRESENT" -eq 1 ] || /bin/rm -rf "$STATE_DIR"
    fi
    return "$status"
}

finish_install() {
    local result=$?
    if [ "$ROLLBACK_NEEDED" -eq 1 ] && [ "$result" -ne 0 ]; then
        if ! rollback_install; then
            printf 'error: install failed and rollback is incomplete; backups remain at %s\n' "$BACKUP_DIR" >&2
            result=2
        fi
    fi
    /bin/rm -rf "$SOURCE_SNAPSHOT_DIR"
    trap - EXIT
    exit "$result"
}

recover_interrupted_install() {
    [ -d "$TRANSACTION_DIR" ] && [ ! -L "$TRANSACTION_DIR" ] || fail 'unsafe interrupted install marker'
    validate_installed_directory "$TRANSACTION_DIR" 700
    local metadata value backup_name
    for metadata in service-was-loaded state-dir-was-present backup-dir new-targets; do
        [ -f "$TRANSACTION_DIR/$metadata" ] && [ ! -L "$TRANSACTION_DIR/$metadata" ] || fail "incomplete interrupted install marker: $metadata"
    done
    value=$(/bin/cat "$TRANSACTION_DIR/service-was-loaded")
    case "$value" in 0|1) SERVICE_WAS_LOADED=$value ;; *) fail 'invalid interrupted service state' ;; esac
    value=$(/bin/cat "$TRANSACTION_DIR/state-dir-was-present")
    case "$value" in 0|1) STATE_DIR_WAS_PRESENT=$value ;; *) fail 'invalid interrupted directory state' ;; esac
    BACKUP_DIR=$(/bin/cat "$TRANSACTION_DIR/backup-dir")
    case "$BACKUP_DIR" in "$STATE_DIR/backups/"*) ;; *) fail 'invalid interrupted backup path' ;; esac
    backup_name=${BACKUP_DIR#"$STATE_DIR/backups/"}
    [[ "$backup_name" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || fail 'invalid interrupted backup path'
    rollback_install || fail "interrupted install recovery failed; backups remain at $BACKUP_DIR"
    BACKUP_DIR=$NEXT_BACKUP_DIR
    /usr/bin/install -d -m 0700 "$STATE_DIR"
    validate_installed_directory "$STATE_DIR" 700
    SERVICE_WAS_LOADED=0
    if [ -z "$ROOT" ]; then
        /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1 && SERVICE_WAS_LOADED=1 || true
    fi
}

stage_install_transaction() {
    /bin/rm -rf "$STAGING_TRANSACTION_DIR"
    /usr/bin/install -d -m 0700 "$STAGING_TRANSACTION_DIR/previous-targets"
    : >"$STAGING_TRANSACTION_DIR/new-targets"
    local target previous
    for target in "${TARGETS[@]}"; do
        if [ -e "$target" ]; then
            validate_installed "$target" "$(managed_target_mode "$target")"
            previous="$STAGING_TRANSACTION_DIR/previous-targets/${target#"$ROOT"/}"
            /usr/bin/install -d -m 0700 "$(/usr/bin/dirname "$previous")"
            /bin/cp -p "$target" "$previous"
        else
            [ ! -L "$target" ] || fail "unsafe existing target: $target"
            printf '%s\n' "$target" >>"$STAGING_TRANSACTION_DIR/new-targets"
        fi
    done
    [ ! -f "$MANIFEST_TARGET" ] || /bin/cp -p "$MANIFEST_TARGET" "$STAGING_TRANSACTION_DIR/previous-manifest"
    # A fresh manifest supersedes an interrupted removal, so the marker is
    # cleared on success. Rollback restores the manifest, so it must restore
    # the marker too or the interrupted removal becomes unresumable.
    [ ! -f "$REMOVAL_MARKER" ] || /bin/cp -p "$REMOVAL_MARKER" "$STAGING_TRANSACTION_DIR/previous-removal-marker"
    printf '%s\n' "$SERVICE_WAS_LOADED" >"$STAGING_TRANSACTION_DIR/service-was-loaded"
    printf '%s\n' "$STATE_DIR_WAS_PRESENT" >"$STAGING_TRANSACTION_DIR/state-dir-was-present"
    printf '%s\n' "$BACKUP_DIR" >"$STAGING_TRANSACTION_DIR/backup-dir"
    /bin/mv "$STAGING_TRANSACTION_DIR" "$TRANSACTION_DIR"
}

if [ -e "$TRANSACTION_DIR" ]; then recover_interrupted_install; fi
/bin/rm -rf "$STATE_DIR"/.install-staging-*
for stale_snapshot in "$TRANSACTION_CONTROL_DIR"/sources-*; do
    [ -e "$stale_snapshot" ] || continue
    [ "$stale_snapshot" = "$SOURCE_SNAPSHOT_DIR" ] || /bin/rm -rf "$stale_snapshot"
done
/bin/rm -f "$CONFIG_TARGET".tailnet-keeper-install.*
stage_install_transaction
ROLLBACK_NEEDED=1
trap finish_install EXIT

backup_if_changed "$SOURCE_DIR/bin/tailnet-keeper" "$KEEPER_TARGET"
for module in "${MODULES[@]}"; do backup_if_changed "$SOURCE_DIR/libexec/$module" "$MODULE_DIR/$module"; done
backup_if_changed "$SOURCE_DIR/tailnet-keeper.pf" "$PF_TARGET"
backup_if_changed "$SOURCE_DIR/launchd/$SERVICE_LABEL.plist" "$PLIST_TARGET"
if [ "$BOOT_RECOVERY_SETTING" != preserve ] && [ -f "$CONFIG_TARGET" ]; then
    config_backup="$BACKUP_DIR/${CONFIG_TARGET#"$ROOT"/}"
    /usr/bin/install -d -m 0700 "$(/usr/bin/dirname "$config_backup")"
    /bin/cp -p "$CONFIG_TARGET" "$config_backup"
fi

if [ -z "$ROOT" ] && [ "$SERVICE_WAS_LOADED" -eq 1 ]; then
    stop_loaded_service || fail 'could not stop the existing service before upgrade'
fi

/usr/bin/install -d -m 0755 "$MODULE_DIR" "$(/usr/bin/dirname "$PF_TARGET")" "$(/usr/bin/dirname "$PLIST_TARGET")" "$(/usr/bin/dirname "$CONFIG_TARGET")"
validate_installed_directory "$MODULE_DIR" 755
/usr/bin/install -m 0755 "$SOURCE_DIR/bin/tailnet-keeper" "$KEEPER_TARGET"
for module in "${MODULES[@]}"; do /usr/bin/install -m 0644 "$SOURCE_DIR/libexec/$module" "$MODULE_DIR/$module"; done
/usr/bin/install -m 0644 "$SOURCE_DIR/tailnet-keeper.pf" "$PF_TARGET"
if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ] && [ "${TAILNET_KEEPER_TEST_KILL_AFTER:-}" = pf ]; then /bin/kill -KILL $$; fi
if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ] && [ "${TAILNET_KEEPER_TEST_FAIL_AFTER:-}" = pf ]; then false; fi
/usr/bin/install -m 0644 "$SOURCE_DIR/launchd/$SERVICE_LABEL.plist" "$PLIST_TARGET"
if [ "$BOOT_RECOVERY_SETTING" = preserve ]; then
    if [ ! -e "$CONFIG_TARGET" ]; then /usr/bin/install -m 0600 "$SOURCE_DIR/tailnet-keeper.conf.example" "$CONFIG_TARGET"; fi
else
    CONFIG_TEMP=$(/usr/bin/mktemp "$CONFIG_TARGET.tailnet-keeper-install.XXXXXX")
    if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ] && [ "${TAILNET_KEEPER_TEST_KILL_AFTER:-}" = config-temp ]; then /bin/kill -KILL $$; fi
    printf 'RESTART_TAILSCALE_AFTER_BOOT=%s\n' "$BOOT_RECOVERY_SETTING" >"$CONFIG_TEMP"
    /bin/chmod 0600 "$CONFIG_TEMP"
    /bin/mv "$CONFIG_TEMP" "$CONFIG_TARGET"
    CONFIG_TEMP=
fi

if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ] && [ "${TAILNET_KEEPER_TEST_TAMPER_AFTER_INSTALL:-0}" = 1 ]; then
    /bin/chmod 0777 "$KEEPER_TARGET"
fi
validate_installed "$KEEPER_TARGET" 755
for module in "${MODULES[@]}"; do validate_installed "$MODULE_DIR/$module" 644; done
validate_installed "$PF_TARGET" 644
validate_installed "$PLIST_TARGET" 644
validate_installed "$CONFIG_TARGET" 600

{
    /usr/bin/shasum -a 256 "$KEEPER_TARGET"
    for module in "${MODULES[@]}"; do /usr/bin/shasum -a 256 "$MODULE_DIR/$module"; done
    /usr/bin/shasum -a 256 "$PF_TARGET"
    /usr/bin/shasum -a 256 "$PLIST_TARGET"
} >"$MANIFEST_TARGET.new"
/bin/mv "$MANIFEST_TARGET.new" "$MANIFEST_TARGET"
/bin/chmod 0600 "$MANIFEST_TARGET"
# A fresh manifest supersedes any interrupted removal. Left behind, its marker
# would make every later uninstall accept missing managed files as expected.
/bin/rm -f "$REMOVAL_MARKER"

if [ -n "$ROOT" ]; then
    ROLLBACK_NEEDED=0
    /bin/rm -rf "$TRANSACTION_DIR" "$SOURCE_SNAPSHOT_DIR"
    printf 'Installed into %s\n' "$ROOT"
    exit 0
fi

[ ! -e "$CONFIG_TARGET" ] || [ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$CONFIG_TARGET")" = root:wheel:600 ] || fail 'unsafe configuration ownership or mode'
[ ! -L "$STATE_DIR/derp-ipv4" ] || fail 'unsafe IPv4 DERP cache'
[ ! -L "$STATE_DIR/derp-ipv6" ] || fail 'unsafe IPv6 DERP cache'
[ -f "$STATE_DIR/derp-ipv4" ] || : >"$STATE_DIR/derp-ipv4"
[ -f "$STATE_DIR/derp-ipv6" ] || : >"$STATE_DIR/derp-ipv6"
/bin/chmod 0600 "$STATE_DIR/derp-ipv4" "$STATE_DIR/derp-ipv6"
/sbin/pfctl -nf "$PF_TARGET" >/dev/null 2>&1 || fail 'PF template validation failed'
/bin/rm -f "$STATE_DIR/health"
/bin/launchctl bootstrap system "$PLIST_TARGET"
wait_for_healthy_state || fail 'new service did not reach healthy state'

ROLLBACK_NEEDED=0
/bin/rm -rf "$TRANSACTION_DIR" "$SOURCE_SNAPSHOT_DIR"
printf 'Installed %s\n' "$SERVICE_LABEL"
