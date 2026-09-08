#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-install.XXXXXX")
SYMLINK_SANDBOX=
SYSTEM_LINK_SANDBOX=
WRITABLE_PARENT_SANDBOX=
TEMP_SYMLINK_SANDBOX=
ACL_SANDBOX=
RUN_PARENT_SANDBOX=
BYPASS_SANDBOX=
RACE_SANDBOX=
RACE_SOURCE=
RECOVERY_SANDBOX=
LINK_UNINSTALL_SANDBOX=
LOCK_ATTACK_SANDBOX=
UNSAFE_CONTROL_SANDBOX=
MARKER_SYMLINK_SANDBOX=
BACKUP_TRAVERSAL_SANDBOX=
BACKUP_TRAVERSAL_CANARY=
SPACE_SANDBOX=
PURGE_SANDBOX=
STALE_MARKER_SANDBOX=
ROLLBACK_MARKER_SANDBOX=
MANIFEST_ORDER_SANDBOX=
CRASH_WINDOW_SANDBOX=
RESURRECT_SANDBOX=
trap 'rm -rf "$SANDBOX" "${SYMLINK_SANDBOX:-}" "${SYSTEM_LINK_SANDBOX:-}" "${WRITABLE_PARENT_SANDBOX:-}" "${TEMP_SYMLINK_SANDBOX:-}" "${ACL_SANDBOX:-}" "${RUN_PARENT_SANDBOX:-}" "${BYPASS_SANDBOX:-}" "${RACE_SANDBOX:-}" "${RACE_SOURCE:-}" "${RECOVERY_SANDBOX:-}" "${LINK_UNINSTALL_SANDBOX:-}" "${LOCK_ATTACK_SANDBOX:-}" "${UNSAFE_CONTROL_SANDBOX:-}" "${MARKER_SYMLINK_SANDBOX:-}" "${BACKUP_TRAVERSAL_SANDBOX:-}" "${BACKUP_TRAVERSAL_CANARY:-}" "${SPACE_SANDBOX:-}" "${PURGE_SANDBOX:-}" "${STALE_MARKER_SANDBOX:-}" "${ROLLBACK_MARKER_SANDBOX:-}" "${MANIFEST_ORDER_SANDBOX:-}" "${CRASH_WINDOW_SANDBOX:-}" "${RESURRECT_SANDBOX:-}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

! grep -q '"\$KEEPER_TARGET" --deactivate' "$PROJECT_ROOT/scripts/uninstall.sh" || fail 'uninstaller executes an untrusted installed keeper'
! grep -q '"\$KEEPER_TARGET" --deactivate' "$PROJECT_ROOT/scripts/install.sh" || fail 'installer rollback executes a mixed-generation keeper'
! grep -q 'previous installation restored' "$PROJECT_ROOT/scripts/install.sh" || fail 'installer claims rollback before verifying it'
grep -q 'wait_for_healthy_state || status=1' "$PROJECT_ROOT/scripts/install.sh" || fail 'installer rollback does not verify restored service health'
[ "$(grep -c 'stop_loaded_service' "$PROJECT_ROOT/scripts/install.sh")" -ge 3 ] || fail 'installer does not confirm daemon shutdown before replacement and rollback'
grep -q 'stop_loaded_service || return 1' "$PROJECT_ROOT/scripts/install.sh" || fail 'rollback mutates files after daemon shutdown fails'
grep -q 'restore_backup_atomically' "$PROJECT_ROOT/scripts/install.sh" || fail 'rollback restores managed files in place'
grep -q 'launchctl bootout --wait' "$PROJECT_ROOT/scripts/install.sh" || fail 'daemon shutdown does not wait for process termination'
! grep -q 'launchctl kickstart' "$PROJECT_ROOT/scripts/install.sh" || fail 'installer starts two daemon generations during bootstrap'
trap_line=$(awk '/trap finish_install EXIT/ { print NR; exit }' "$PROJECT_ROOT/scripts/install.sh")
bootout_line=$(awk '/could not stop the existing service before upgrade/ { print NR; exit }' "$PROJECT_ROOT/scripts/install.sh")
install_line=$(awk '/\/usr\/bin\/install -m 0755 .*"\$KEEPER_TARGET"/ { print NR; exit }' "$PROJECT_ROOT/scripts/install.sh")
[ -n "$trap_line" ] && [ "$trap_line" -lt "$bootout_line" ] || fail 'rollback is armed after daemon shutdown begins'
[ -n "$bootout_line" ] && [ "$bootout_line" -lt "$install_line" ] || fail 'upgrade can launch a mixed executable generation'
grep -q 'loaded service has no restorable plist' "$PROJECT_ROOT/scripts/install.sh" || fail 'loaded service without a restorable plist is accepted'
grep -q 'launchctl bootout --wait' "$PROJECT_ROOT/scripts/uninstall.sh" || fail 'uninstaller does not wait for daemon termination'
grep -q 'tailnet-keeper-transactions' "$PROJECT_ROOT/scripts/uninstall.sh" || fail 'uninstaller is not serialized with installer'
if DESTDIR=/ "$PROJECT_ROOT/scripts/install.sh" --help >/dev/null 2>&1; then fail 'DESTDIR=/ bypassed live installation safety'; fi
if DESTDIR=/ "$PROJECT_ROOT/scripts/uninstall.sh" --force >/dev/null 2>&1; then fail 'DESTDIR=/ bypassed live uninstall safety'; fi

# Missing platform tools must fail before creating transaction state.
mkdir -p "$SANDBOX/missing-lockf"
sed 's|/usr/bin/lockf|/nonexistent/tailnet-keeper-lockf|g' \
    "$PROJECT_ROOT/scripts/install.sh" >"$SANDBOX/install-without-lockf.sh"
set +e
DESTDIR="$SANDBOX/missing-lockf" /bin/bash "$SANDBOX/install-without-lockf.sh" \
    >"$SANDBOX/missing-lockf.log" 2>&1
missing_lockf_status=$?
set -e
[ "$missing_lockf_status" -ne 0 ] || fail 'installer accepted a missing locking tool'
grep -q 'requires macOS 26 or later with /nonexistent/tailnet-keeper-lockf' \
    "$SANDBOX/missing-lockf.log" || fail 'installer did not explain its platform requirement'
[ ! -e "$SANDBOX/missing-lockf/var" ] || fail 'unsupported host received transaction state'

# macOS ships /var/run as root:daemon 0775. Installation must neither reject
# nor chmod that system directory; transaction control belongs in a private
# root-owned directory under /var/db.
RUN_PARENT_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-run-parent.XXXXXX")
mkdir -p "$RUN_PARENT_SANDBOX/var/run"
chmod 0775 "$RUN_PARENT_SANDBOX/var/run"
DESTDIR="$RUN_PARENT_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null || fail 'installer depends on restrictive /var/run permissions'
[ "$(stat -f %Lp "$RUN_PARENT_SANDBOX/var/run")" = 775 ] || fail 'installer changed /var/run permissions'
[ -f "$RUN_PARENT_SANDBOX/var/db/tailnet-keeper-transactions/install.lock" ] || fail 'installer did not place its lock in the private transaction directory'
DESTDIR="$RUN_PARENT_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" --purge >/dev/null || fail 'uninstaller could not use the private transaction lock'

mkdir -p "$SANDBOX/etc/pf.anchors" "$SANDBOX/Library/LaunchDaemons"
printf 'untouched\n' >"$SANDBOX/etc/pf.anchors/unrelated"
printf 'untouched\n' >"$SANDBOX/etc/pf.conf"

DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/install.sh"

[ -x "$SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" ] || fail 'keeper was not installed as executable'
TAILNET_KEEPER_TESTING=1 bash -c 'source "$1"; type refresh_derp_routes >/dev/null' _ "$SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" || fail 'installed keeper cannot load its modules'
[ -f "$SANDBOX/etc/pf.anchors/tailnet-keeper" ] || fail 'PF template was not installed'
[ -f "$SANDBOX/Library/LaunchDaemons/io.github.andredezzy.tailnet-keeper.plist" ] || fail 'LaunchDaemon was not installed'
[ -f "$SANDBOX/usr/local/etc/tailnet-keeper.conf" ] || fail 'default configuration was not installed'
[ "$(cat "$SANDBOX/usr/local/etc/tailnet-keeper.conf")" = 'RESTART_TAILSCALE_AFTER_BOOT=off' ] || fail 'default configuration is unsafe'
[ -s "$SANDBOX/var/db/tailnet-keeper/install-manifest" ] || fail 'install manifest is missing'
awk 'length($1) == 64 && $1 ~ /^[0-9a-f]+$/ { next } { exit 1 }' "$SANDBOX/var/db/tailnet-keeper/install-manifest" || fail 'install manifest does not use SHA-256'
/usr/bin/plutil -lint "$SANDBOX/Library/LaunchDaemons/io.github.andredezzy.tailnet-keeper.plist" >/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$SANDBOX/Library/LaunchDaemons/io.github.andredezzy.tailnet-keeper.plist")" = 300 ] || fail 'safety interval is not five minutes'
[ "$(/usr/libexec/PlistBuddy -c 'Print :Umask' "$SANDBOX/Library/LaunchDaemons/io.github.andredezzy.tailnet-keeper.plist")" = 63 ] || fail 'LaunchDaemon umask is not 077'
[ "$(/usr/libexec/PlistBuddy -c 'Print :WatchPaths:0' "$SANDBOX/Library/LaunchDaemons/io.github.andredezzy.tailnet-keeper.plist")" = /Library/Preferences/SystemConfiguration ] || fail 'SystemConfiguration changes do not trigger reconciliation'
# launchd throttles Background jobs; measured, that made a cold reconciliation
# five times slower and pushed a first install past its health budget.
[ "$(/usr/libexec/PlistBuddy -c 'Print :ProcessType' "$SANDBOX/Library/LaunchDaemons/io.github.andredezzy.tailnet-keeper.plist")" = Standard ] || fail 'LaunchDaemon is throttled as a Background job'


set +e
{
    TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_TEST_KILL_AFTER=pf DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/install.sh"
} >/dev/null 2>&1
kill_status=$?
set -e
[ "$kill_status" -ne 0 ] || fail 'SIGKILL injection did not interrupt installation'
[ -d "$SANDBOX/var/db/tailnet-keeper/install-transaction" ] || fail 'interrupted installation left no durable recovery marker'
DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
[ ! -e "$SANDBOX/var/db/tailnet-keeper/install-transaction" ] || fail 'next installation did not recover the interrupted transaction'
cmp -s "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" || fail 'post-crash retry did not converge to the requested generation'

TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_TEST_HOLD_LOCK=1 DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1 &
lock_holder=$!
for _ in {1..50}; do
    [ -f "$SANDBOX/var/db/tailnet-keeper/install-lock-held" ] && break
    sleep 0.05
done
[ -f "$SANDBOX/var/db/tailnet-keeper/install-lock-held" ] || fail 'installer lock test hook did not start'
if DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1; then
    fail 'concurrent installer acquired the active transaction'
fi
wait "$lock_holder"

DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/install.sh" --enable-boot-recovery
[ "$(cat "$SANDBOX/usr/local/etc/tailnet-keeper.conf")" = 'RESTART_TAILSCALE_AFTER_BOOT=on' ] || fail 'enable flag did not update configuration'
first_hashes=$(find "$SANDBOX/usr/local/libexec" "$SANDBOX/etc/pf.anchors" "$SANDBOX/Library/LaunchDaemons" -type f -exec shasum -a 256 {} + | sort)
DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/install.sh"
second_hashes=$(find "$SANDBOX/usr/local/libexec" "$SANDBOX/etc/pf.anchors" "$SANDBOX/Library/LaunchDaemons" -type f -exec shasum -a 256 {} + | sort)
[ "$first_hashes" = "$second_hashes" ] || fail 'second installation changed managed content'
[ "$(cat "$SANDBOX/usr/local/etc/tailnet-keeper.conf")" = 'RESTART_TAILSCALE_AFTER_BOOT=on' ] || fail 'upgrade replaced operator configuration'
chmod 0777 "$SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper"
if DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1; then
    fail 'installer accepted an unsafe previous executable generation'
fi
chmod 0755 "$SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper"

keeper_before_tamper=$(shasum -a 256 "$SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper")
if TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_TEST_TAMPER_AFTER_INSTALL=1 DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1; then
    fail 'post-install mode tampering was not detected'
fi
[ "$(shasum -a 256 "$SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper")" = "$keeper_before_tamper" ] || fail 'tamper rollback did not restore the prior keeper'
[ "$(stat -f %Lp "$SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper")" = 755 ] || fail 'tamper rollback did not restore keeper mode'

printf 'owner-managed-version\n' >"$SANDBOX/etc/pf.anchors/tailnet-keeper"
manifest_before_failure=$(shasum -a 256 "$SANDBOX/var/db/tailnet-keeper/install-manifest")
if TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_TEST_FAIL_AFTER=pf DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1; then
    fail 'injected install failure reported success'
fi
[ "$(cat "$SANDBOX/etc/pf.anchors/tailnet-keeper")" = 'owner-managed-version' ] || fail 'failed install did not restore replaced PF file'
[ "$(shasum -a 256 "$SANDBOX/var/db/tailnet-keeper/install-manifest")" = "$manifest_before_failure" ] || fail 'failed install changed the active manifest'

DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/install.sh"
printf 'previous anchor\n' >"$SANDBOX/etc/pf.anchors/tailnet-keeper"
DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/install.sh"
find "$SANDBOX/var/db/tailnet-keeper/backups" -type f -exec grep -q 'previous anchor' {} \; -print | grep -q . || fail 'upgrade did not preserve the replaced anchor'

printf 'locally modified\n' >"$SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper"
if DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" >/dev/null 2>&1; then
    fail 'uninstall removed a modified managed file without --force'
fi

cp "$SANDBOX/var/db/tailnet-keeper/install-manifest" "$SANDBOX/var/db/tailnet-keeper/install-manifest.safe"
printf 'deadbeef  %s\n' "$SANDBOX/etc/pf.conf" >>"$SANDBOX/var/db/tailnet-keeper/install-manifest"
if DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" --force >/dev/null 2>&1; then
    fail 'uninstall accepted a path outside its managed allowlist'
fi
[ "$(cat "$SANDBOX/etc/pf.conf")" = untouched ] || fail 'malicious manifest removed unrelated pf.conf'
mv "$SANDBOX/var/db/tailnet-keeper/install-manifest.safe" "$SANDBOX/var/db/tailnet-keeper/install-manifest"

cp "$SANDBOX/var/db/tailnet-keeper/install-manifest" "$SANDBOX/var/db/tailnet-keeper/install-manifest.complete"
manifest_without_newline=$(cat "$SANDBOX/var/db/tailnet-keeper/install-manifest.complete")
printf '%s' "$manifest_without_newline" >"$SANDBOX/var/db/tailnet-keeper/install-manifest"
if DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" --force >/dev/null 2>&1; then
    fail 'uninstall accepted a manifest without a terminating newline'
fi
[ -e "$SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" ] || fail 'unterminated manifest caused partial uninstall'
cp "$SANDBOX/var/db/tailnet-keeper/install-manifest.complete" "$SANDBOX/var/db/tailnet-keeper/install-manifest"
awk 'NR < 8' "$SANDBOX/var/db/tailnet-keeper/install-manifest.complete" >"$SANDBOX/var/db/tailnet-keeper/install-manifest"
if DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" --force >/dev/null 2>&1; then
    fail 'uninstall accepted a truncated manifest'
fi
[ -e "$SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" ] || fail 'truncated manifest caused partial uninstall'
cp "$SANDBOX/var/db/tailnet-keeper/install-manifest.complete" "$SANDBOX/var/db/tailnet-keeper/install-manifest"
awk 'NR == 1 { print } { print }' "$SANDBOX/var/db/tailnet-keeper/install-manifest.complete" >"$SANDBOX/var/db/tailnet-keeper/install-manifest"
if DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" --force >/dev/null 2>&1; then
    fail 'uninstall accepted duplicate manifest entries'
fi
mv "$SANDBOX/var/db/tailnet-keeper/install-manifest.complete" "$SANDBOX/var/db/tailnet-keeper/install-manifest"

mv "$SANDBOX/usr/local/libexec/tailnet-keeper/common.sh" "$SANDBOX/usr/local/libexec/tailnet-keeper/common.sh.missing"
if DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" --force >/dev/null 2>&1; then
    fail 'force uninstall accepted a missing managed file'
fi
mv "$SANDBOX/usr/local/libexec/tailnet-keeper/common.sh.missing" "$SANDBOX/usr/local/libexec/tailnet-keeper/common.sh"

DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" --force

[ ! -e "$SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" ] || fail 'keeper survived uninstall'
[ ! -d "$SANDBOX/usr/local/libexec/tailnet-keeper" ] || [ -z "$(find "$SANDBOX/usr/local/libexec/tailnet-keeper" -type f -print -quit)" ] || fail 'keeper modules survived uninstall'
[ ! -e "$SANDBOX/etc/pf.anchors/tailnet-keeper" ] || fail 'PF template survived uninstall'
[ ! -e "$SANDBOX/Library/LaunchDaemons/io.github.andredezzy.tailnet-keeper.plist" ] || fail 'LaunchDaemon survived uninstall'
[ -f "$SANDBOX/usr/local/etc/tailnet-keeper.conf" ] || fail 'ordinary uninstall removed configuration'
[ -d "$SANDBOX/var/db/tailnet-keeper/backups" ] || fail 'ordinary uninstall removed backups'
[ "$(cat "$SANDBOX/etc/pf.anchors/unrelated")" = untouched ] || fail 'uninstall modified an unrelated PF anchor'
[ "$(cat "$SANDBOX/etc/pf.conf")" = untouched ] || fail 'uninstall modified pf.conf'

if DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" --force --purge >/dev/null 2>&1; then
    fail 'force uninstall proceeded without an install manifest'
fi
DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
DESTDIR="$SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" --force --purge
[ ! -e "$SANDBOX/usr/local/etc/tailnet-keeper.conf" ] || fail 'purge preserved configuration'
[ ! -e "$SANDBOX/var/db/tailnet-keeper" ] || fail 'purge preserved state'

SYMLINK_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-symlink.XXXXXX")
mkdir -p "$SYMLINK_SANDBOX/usr/local/libexec" "$SYMLINK_SANDBOX/escape"
ln -s "$SYMLINK_SANDBOX/escape" "$SYMLINK_SANDBOX/usr/local/libexec/tailnet-keeper"
if DESTDIR="$SYMLINK_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1; then
    fail 'installer followed a symlinked destination directory'
fi
[ -z "$(find "$SYMLINK_SANDBOX/escape" -type f -print -quit)" ] || fail 'installer wrote through a symlinked destination directory'

SYSTEM_LINK_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-system-links.XXXXXX")
mkdir -p "$SYSTEM_LINK_SANDBOX/private/etc" "$SYSTEM_LINK_SANDBOX/private/var"
ln -s private/etc "$SYSTEM_LINK_SANDBOX/etc"
ln -s private/var "$SYSTEM_LINK_SANDBOX/var"
DESTDIR="$SYSTEM_LINK_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
[ -f "$SYSTEM_LINK_SANDBOX/private/etc/pf.anchors/tailnet-keeper" ] || fail 'installer did not support the standard /etc symlink'
[ -f "$SYSTEM_LINK_SANDBOX/private/var/db/tailnet-keeper/install-manifest" ] || fail 'installer did not support the standard /var symlink'
# Every real macOS install sits behind those two symlinks, so removal has to
# work there too.
DESTDIR="$SYSTEM_LINK_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" >/dev/null || fail 'uninstaller did not support the standard /etc and /var symlinks'
[ ! -e "$SYSTEM_LINK_SANDBOX/private/etc/pf.anchors/tailnet-keeper" ] || fail 'uninstall behind the /etc symlink left the PF template'
[ ! -e "$SYSTEM_LINK_SANDBOX/private/var/db/tailnet-keeper/install-manifest" ] || fail 'uninstall behind the /var symlink left the manifest'
DESTDIR="$SYSTEM_LINK_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null

WRITABLE_PARENT_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-writable-parent.XXXXXX")
mkdir -p "$WRITABLE_PARENT_SANDBOX/usr/local"
chmod 0777 "$WRITABLE_PARENT_SANDBOX/usr/local"
if DESTDIR="$WRITABLE_PARENT_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1; then
    fail 'installer accepted a writable ancestor of the root executable'
fi
[ ! -e "$WRITABLE_PARENT_SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" ] || fail 'installer wrote through a writable ancestor'

TEMP_SYMLINK_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-temp-link.XXXXXX")
DESTDIR="$TEMP_SYMLINK_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
printf 'sentinel\n' >"$TEMP_SYMLINK_SANDBOX/sentinel"
# Production names its temporary file tailnet-keeper.conf.tailnet-keeper-install.*
# and sweeps that pattern on the next run, so the planted symlink must use it.
ln -s "$TEMP_SYMLINK_SANDBOX/sentinel" "$TEMP_SYMLINK_SANDBOX/usr/local/etc/tailnet-keeper.conf.tailnet-keeper-install.planted"
DESTDIR="$TEMP_SYMLINK_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" --enable-boot-recovery >/dev/null
[ "$(cat "$TEMP_SYMLINK_SANDBOX/sentinel")" = sentinel ] || fail 'temporary config symlink target was modified'
[ ! -e "$TEMP_SYMLINK_SANDBOX/usr/local/etc/tailnet-keeper.conf.tailnet-keeper-install.planted" ] || fail 'planted config temp symlink survived installation'
[ -f "$TEMP_SYMLINK_SANDBOX/usr/local/etc/tailnet-keeper.conf" ] && [ ! -L "$TEMP_SYMLINK_SANDBOX/usr/local/etc/tailnet-keeper.conf" ] || fail 'installer did not atomically replace the configuration'
grep -qx 'RESTART_TAILSCALE_AFTER_BOOT=on' "$TEMP_SYMLINK_SANDBOX/usr/local/etc/tailnet-keeper.conf" || fail 'installer wrote the wrong boot recovery setting'
set +e
{
    TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_TEST_KILL_AFTER=config-temp DESTDIR="$TEMP_SYMLINK_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" --disable-boot-recovery
} >/dev/null 2>&1
config_kill_status=$?
set -e
[ "$config_kill_status" -ne 0 ] || fail 'config temp SIGKILL injection did not interrupt installation'
config_residue=$(find "$TEMP_SYMLINK_SANDBOX/usr/local/etc" -name 'tailnet-keeper.conf.tailnet-keeper-install.*' -print -quit)
[ -n "$config_residue" ] || fail 'config temp crash left no reproducible residue'
DESTDIR="$TEMP_SYMLINK_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" --disable-boot-recovery >/dev/null
[ -z "$(find "$TEMP_SYMLINK_SANDBOX/usr/local/etc" -name 'tailnet-keeper.conf.tailnet-keeper-install.*' -print -quit)" ] || fail 'config temp residue survived recovery'

ACL_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-acl.XXXXXX")
mkdir -p "$ACL_SANDBOX/usr/local"
chmod 0700 "$ACL_SANDBOX/usr/local"
chmod +a 'everyone allow write' "$ACL_SANDBOX/usr/local"
if DESTDIR="$ACL_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1; then
    fail 'installer accepted a writable ACL on an executable ancestor'
fi
grep -q 'lockf -t 0 -k' "$PROJECT_ROOT/scripts/install.sh" || fail 'installer lock does not keep the lock pathname across release'

# The re-exec marker is caller-settable, so it must not be accepted as proof
# that the lock is held.
BYPASS_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-lock-bypass.XXXXXX")
set +e
TAILNET_KEEPER_INSTALL_LOCKED=1 DESTDIR="$BYPASS_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1
bypass_status=$?
set -e
[ "$bypass_status" -ne 0 ] || fail 'installer trusted the lock marker without holding the lock'
[ ! -e "$BYPASS_SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" ] || fail 'lock bypass reached a privileged publication'

# Seeing a busy lock is not proof that this process owns it. An unrelated
# holder must not make the caller-settable marker authoritative.
LOCK_ATTACK_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-lock-owner.XXXXXX")
mkdir -p "$LOCK_ATTACK_SANDBOX/var/db/tailnet-keeper-transactions"
/usr/bin/lockf -t 0 -k "$LOCK_ATTACK_SANDBOX/var/db/tailnet-keeper-transactions/install.lock" /bin/sleep 5 &
lock_holder=$!
/bin/sleep 0.1
set +e
TAILNET_KEEPER_INSTALL_LOCKED=1 DESTDIR="$LOCK_ATTACK_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1
lock_owner_status=$?
set -e
/bin/kill "$lock_holder" 2>/dev/null || true
wait "$lock_holder" 2>/dev/null || true
[ "$lock_owner_status" -ne 0 ] || fail 'installer accepted an unrelated lock holder as ownership proof'
[ ! -e "$LOCK_ATTACK_SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" ] || fail 'unrelated lock holder enabled privileged publication'

# Interrupted metadata is persistent input. A lexical backups/ prefix containing
# parent traversal must not let rollback delete an arbitrary directory.
BACKUP_TRAVERSAL_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-backup-path.XXXXXX")
BACKUP_TRAVERSAL_CANARY=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-backup-canary.XXXXXX")
backup_root=$(cd "$BACKUP_TRAVERSAL_SANDBOX" && pwd -P)
backup_canary=$(cd "$BACKUP_TRAVERSAL_CANARY" && pwd -P)
backup_transaction="$backup_root/var/db/tailnet-keeper/install-transaction"
mkdir -p "$backup_transaction" "$backup_root/var/db/tailnet-keeper/backups"
printf '0\n' >"$backup_transaction/service-was-loaded"
printf '1\n' >"$backup_transaction/state-dir-was-present"
: >"$backup_transaction/new-targets"
backup_relative=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1],sys.argv[2]))' "$backup_canary" "$backup_root/var/db/tailnet-keeper/backups")
printf '%s\n' "$backup_root/var/db/tailnet-keeper/backups/$backup_relative" >"$backup_transaction/backup-dir"
chmod 0700 "$backup_transaction"
printf 'sentinel\n' >"$backup_canary/witness"
set +e
DESTDIR="$backup_root" "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1
backup_traversal_status=$?
set -e
[ "$backup_traversal_status" -ne 0 ] || fail 'installer accepted a traversing interrupted backup path'
[ -f "$backup_canary/witness" ] || fail 'interrupted backup path escaped rollback state'

# Sources are snapshotted under the lock; a source rewritten mid-transaction
# must not reach the target.
RACE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-source-race.XXXXXX")
RACE_SOURCE=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-source-copy.XXXXXX")
cp -R "$PROJECT_ROOT/." "$RACE_SOURCE/"
snapshot_digest=$(shasum -a 256 "$RACE_SOURCE/bin/tailnet-keeper" | awk '{ print $1 }')
(
    TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_TEST_HOLD_LOCK=1 DESTDIR="$RACE_SANDBOX" \
        "$RACE_SOURCE/scripts/install.sh" >/dev/null 2>&1
) &
race_pid=$!
for _ in {1..100}; do
    [ -e "$RACE_SANDBOX/var/db/tailnet-keeper/install-lock-held" ] && break
    sleep 0.1
done
printf '#!/bin/bash\n# tampered\n' >"$RACE_SOURCE/bin/tailnet-keeper"
chmod 0755 "$RACE_SOURCE/bin/tailnet-keeper"
wait "$race_pid" || fail 'source race installation failed'
installed_digest=$(shasum -a 256 "$RACE_SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" | awk '{ print $1 }')
[ "$installed_digest" = "$snapshot_digest" ] || fail 'a source rewritten under the lock reached the installed target'
[ -z "$(find "$RACE_SANDBOX/var/db/tailnet-keeper-transactions" -maxdepth 1 -name 'sources-*' -print -quit)" ] || fail 'source snapshot survived a successful installation'
rm -rf "$RACE_SOURCE"

# Recovering an interrupted install can remove the whole state directory, so
# the source snapshot must not live inside it.
RECOVERY_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-snapshot-recovery.XXXXXX")
set +e
TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_TEST_KILL_AFTER=pf DESTDIR="$RECOVERY_SANDBOX" \
    "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1
set -e
DESTDIR="$RECOVERY_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null || fail 'install after an interrupted run could not reach its own sources'
[ -f "$RECOVERY_SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" ] || fail 'recovered install published no keeper'
[ -z "$(find "$RECOVERY_SANDBOX/var/db/tailnet-keeper-transactions" -maxdepth 1 -name 'sources-*' -print -quit)" ] || fail 'source snapshot survived a recovered installation'

# Hashes and textual paths still validate when a managed directory is swapped
# for a symlink, so the uninstaller must reject the ancestor rather than delete
# through it.
LINK_UNINSTALL_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-uninstall-link.XXXXXX")
DESTDIR="$LINK_UNINSTALL_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
moved_modules="$LINK_UNINSTALL_SANDBOX/moved-modules"
mv "$LINK_UNINSTALL_SANDBOX/usr/local/libexec/tailnet-keeper" "$moved_modules"
ln -s "$moved_modules" "$LINK_UNINSTALL_SANDBOX/usr/local/libexec/tailnet-keeper"
set +e
DESTDIR="$LINK_UNINSTALL_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" >/dev/null 2>&1
link_uninstall_status=$?
set -e
[ "$link_uninstall_status" -ne 0 ] || fail 'uninstaller followed a symlinked ancestor'
[ -f "$moved_modules/tailnet-keeper" ] || fail 'uninstaller deleted through a symlinked ancestor'
rm "$LINK_UNINSTALL_SANDBOX/usr/local/libexec/tailnet-keeper"
mv "$moved_modules" "$LINK_UNINSTALL_SANDBOX/usr/local/libexec/tailnet-keeper"

# Lock serialization is trustworthy only while its private directory remains
# non-writable to unprivileged users.
UNSAFE_CONTROL_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-control-mode.XXXXXX")
DESTDIR="$UNSAFE_CONTROL_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
chmod 0777 "$UNSAFE_CONTROL_SANDBOX/var/db/tailnet-keeper-transactions"
set +e
DESTDIR="$UNSAFE_CONTROL_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" --force >/dev/null 2>&1
unsafe_control_status=$?
set -e
[ "$unsafe_control_status" -ne 0 ] || fail 'uninstaller accepted a writable transaction-control directory'
[ -f "$UNSAFE_CONTROL_SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" ] || fail 'unsafe transaction directory allowed managed deletion'

# The resumable-removal marker is a privileged write target and must never be
# followed when replaced by a symlink.
MARKER_SYMLINK_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-removal-marker.XXXXXX")
DESTDIR="$MARKER_SYMLINK_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
printf 'sentinel\n' >"$MARKER_SYMLINK_SANDBOX/sentinel"
ln -s "$MARKER_SYMLINK_SANDBOX/sentinel" "$MARKER_SYMLINK_SANDBOX/var/db/tailnet-keeper/removal-in-progress"
set +e
DESTDIR="$MARKER_SYMLINK_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" --force >/dev/null 2>&1
marker_symlink_status=$?
set -e
[ "$marker_symlink_status" -ne 0 ] || fail 'uninstaller followed a symlinked removal marker'
[ "$(cat "$MARKER_SYMLINK_SANDBOX/sentinel")" = sentinel ] || fail 'symlinked removal marker truncated another file'
[ -f "$MARKER_SYMLINK_SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" ] || fail 'symlinked removal marker allowed managed deletion'

# A partial removal must stay resumable: rerunning finishes the job.
chflags uchg "$LINK_UNINSTALL_SANDBOX/etc/pf.anchors/tailnet-keeper"
set +e
DESTDIR="$LINK_UNINSTALL_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" >/dev/null 2>&1
partial_status=$?
set -e
[ "$partial_status" -ne 0 ] || fail 'uninstaller reported success despite an undeletable file'
[ -f "$LINK_UNINSTALL_SANDBOX/var/db/tailnet-keeper/install-manifest" ] || fail 'partial uninstall discarded the manifest'
chflags nouchg "$LINK_UNINSTALL_SANDBOX/etc/pf.anchors/tailnet-keeper"
DESTDIR="$LINK_UNINSTALL_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" >/dev/null
[ ! -e "$LINK_UNINSTALL_SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" ] || fail 'resumed uninstall left managed files behind'
[ ! -e "$LINK_UNINSTALL_SANDBOX/var/db/tailnet-keeper/install-manifest" ] || fail 'resumed uninstall left the manifest behind'

# The manifest separates a fixed-width hash from one path, so a managed path
# containing spaces must stay installable and removable.
SPACE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet keeper space.XXXXXX")
DESTDIR="$SPACE_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
[ -f "$SPACE_SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" ] || fail 'install failed under a path containing spaces'
DESTDIR="$SPACE_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" >/dev/null || fail 'uninstall failed under a path containing spaces'
[ ! -e "$SPACE_SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" ] || fail 'uninstall left managed files under a path containing spaces'

# A purge must not strand the private transaction directory and its lock.
PURGE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-purge.XXXXXX")
DESTDIR="$PURGE_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
DESTDIR="$PURGE_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" --purge >/dev/null
[ ! -e "$PURGE_SANDBOX/var/db/tailnet-keeper" ] || fail 'purge left state behind'
[ ! -e "$PURGE_SANDBOX/var/db/tailnet-keeper-transactions" ] || fail 'purge left the transaction directory behind'

# A reinstall supersedes an interrupted removal. A surviving marker would make
# every later uninstall accept missing managed files as expected.
STALE_MARKER_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-stale-marker.XXXXXX")
DESTDIR="$STALE_MARKER_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
chflags uchg "$STALE_MARKER_SANDBOX/etc/pf.anchors/tailnet-keeper"
set +e
DESTDIR="$STALE_MARKER_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" >/dev/null 2>&1
set -e
chflags nouchg "$STALE_MARKER_SANDBOX/etc/pf.anchors/tailnet-keeper"
[ -f "$STALE_MARKER_SANDBOX/var/db/tailnet-keeper/removal-in-progress" ] || fail 'interrupted removal did not record its marker'
DESTDIR="$STALE_MARKER_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
[ ! -e "$STALE_MARKER_SANDBOX/var/db/tailnet-keeper/removal-in-progress" ] || fail 'reinstall kept a stale removal marker'
rm "$STALE_MARKER_SANDBOX/usr/local/libexec/tailnet-keeper/derp.sh"
set +e
DESTDIR="$STALE_MARKER_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" >/dev/null 2>&1
stale_marker_status=$?
set -e
[ "$stale_marker_status" -ne 0 ] || fail 'stale removal marker disabled missing-file tamper detection'

# Rollback restores the manifest, so it must restore the removal marker too:
# otherwise a failed reinstall leaves an interrupted removal unresumable.
ROLLBACK_MARKER_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-rollback-marker.XXXXXX")
DESTDIR="$ROLLBACK_MARKER_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
chflags uchg "$ROLLBACK_MARKER_SANDBOX/etc/pf.anchors/tailnet-keeper"
set +e
DESTDIR="$ROLLBACK_MARKER_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" >/dev/null 2>&1
set -e
chflags nouchg "$ROLLBACK_MARKER_SANDBOX/etc/pf.anchors/tailnet-keeper"
[ -f "$ROLLBACK_MARKER_SANDBOX/var/db/tailnet-keeper/removal-in-progress" ] || fail 'interrupted removal did not record its marker'
set +e
TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_TEST_KILL_AFTER=pf \
    DESTDIR="$ROLLBACK_MARKER_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1
set -e
[ -f "$ROLLBACK_MARKER_SANDBOX/var/db/tailnet-keeper/removal-in-progress" ] || fail 'rollback did not restore the removal marker'
DESTDIR="$ROLLBACK_MARKER_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
[ ! -e "$ROLLBACK_MARKER_SANDBOX/var/db/tailnet-keeper/removal-in-progress" ] || fail 'recovered install kept a stale removal marker'

# The marker is what makes already-deleted files expected on a rerun, so it
# must never outlive the manifest: that leaves removal unresumable, and the
# failure is not bypassable with --force.
MANIFEST_ORDER_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-manifest-order.XXXXXX")
DESTDIR="$MANIFEST_ORDER_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
chflags uchg "$MANIFEST_ORDER_SANDBOX/var/db/tailnet-keeper/install-manifest"
set +e
DESTDIR="$MANIFEST_ORDER_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" >/dev/null 2>&1
manifest_order_status=$?
set -e
chflags nouchg "$MANIFEST_ORDER_SANDBOX/var/db/tailnet-keeper/install-manifest"
[ "$manifest_order_status" -ne 0 ] || fail 'uninstall reported success despite an undeletable manifest'
[ -f "$MANIFEST_ORDER_SANDBOX/var/db/tailnet-keeper/removal-in-progress" ] || fail 'the removal marker did not outlast a failed manifest removal'
DESTDIR="$MANIFEST_ORDER_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" >/dev/null || fail 'removal could not be resumed after an undeletable manifest'
[ ! -e "$MANIFEST_ORDER_SANDBOX/var/db/tailnet-keeper/install-manifest" ] || fail 'resumed removal left the manifest behind'

# Either deletion order leaves a crash window, so a marker without a manifest
# must finish the removal rather than report the package as absent.
CRASH_WINDOW_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-crash-window.XXXXXX")
DESTDIR="$CRASH_WINDOW_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
printf 'in-progress\n' >"$CRASH_WINDOW_SANDBOX/var/db/tailnet-keeper/removal-in-progress"
chmod 0600 "$CRASH_WINDOW_SANDBOX/var/db/tailnet-keeper/removal-in-progress"
chflags uchg "$CRASH_WINDOW_SANDBOX/var/db/tailnet-keeper/removal-in-progress"
set +e
DESTDIR="$CRASH_WINDOW_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" >/dev/null 2>&1
crash_window_first=$?
set -e
chflags nouchg "$CRASH_WINDOW_SANDBOX/var/db/tailnet-keeper/removal-in-progress"
[ "$crash_window_first" -ne 0 ] || fail 'uninstall reported success despite an undeletable marker'
[ ! -e "$CRASH_WINDOW_SANDBOX/var/db/tailnet-keeper/install-manifest" ] || fail 'the manifest survived a marker-only failure'
[ -f "$CRASH_WINDOW_SANDBOX/var/db/tailnet-keeper/removal-in-progress" ] || fail 'the crash window did not retain its marker'
DESTDIR="$CRASH_WINDOW_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" --purge >/dev/null || fail 'a marker without a manifest could not finish the removal'
[ ! -e "$CRASH_WINDOW_SANDBOX/var/db/tailnet-keeper" ] || fail 'the finished removal left state behind'
[ ! -e "$CRASH_WINDOW_SANDBOX/usr/local/etc/tailnet-keeper.conf" ] || fail 'the finished removal could not purge the config'

# A crashed install leaves interrupted-install state that the installer adopts
# on its next run. If an uninstall does not end that transaction, a later failed
# install rolls the removed package back onto the host.
RESURRECT_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-resurrect.XXXXXX")
DESTDIR="$RESURRECT_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null
set +e
TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_TEST_KILL_AFTER=pf \
    DESTDIR="$RESURRECT_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1
set -e
[ -e "$RESURRECT_SANDBOX/var/db/tailnet-keeper/install-transaction" ] ||
    fail 'the interrupted install left no transaction to test with'
DESTDIR="$RESURRECT_SANDBOX" "$PROJECT_ROOT/scripts/uninstall.sh" >/dev/null
[ ! -e "$RESURRECT_SANDBOX/var/db/tailnet-keeper/install-transaction" ] ||
    fail 'uninstall left interrupted install state that can resurrect the package'
set +e
TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_TEST_FAIL_AFTER=pf \
    DESTDIR="$RESURRECT_SANDBOX" "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1
set -e
[ ! -e "$RESURRECT_SANDBOX/usr/local/libexec/tailnet-keeper/tailnet-keeper" ] ||
    fail 'a failed install resurrected the uninstalled package'

# Both the installer and the verifier wait on a cold reconciliation, which
# installs and verifies a bypass route per DERP relay in both families:
# 34s measured on a full relay list. Either budget falling short reports
# failure against a daemon that is working correctly.
for script in install verify; do
    budget=$(awk -F= '$1 == "readonly HEALTHY_STATE_TIMEOUT_SECONDS" { print $2; exit }' "$PROJECT_ROOT/scripts/$script.sh")
    [ -n "$budget" ] || fail "$script.sh does not name its health wait budget"
    [ "$budget" -ge 120 ] || fail "$script.sh allows ${budget}s, which cannot cover a cold reconciliation"
done

printf 'install_lifecycle=PASS\n'
