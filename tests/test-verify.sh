#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERIFY="$PROJECT_ROOT/scripts/verify.sh"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-verify-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[ -x "$VERIFY" ] || fail 'verify.sh is missing or not executable'
help=$($VERIFY --help)
grep -q -- '--target HOST' <<<"$help" || fail 'verify help omits target option'
grep -q -- '--ports PORTS' <<<"$help" || fail 'verify help omits ports option'
grep -q -- '--check-orbstack' <<<"$help" || fail 'verify help omits OrbStack option'
trust_line=$(awk '/validate_tailscale_cli/ { print NR; exit }' "$VERIFY")
status_line=$(awk '/status --json/ { print NR; exit }' "$VERIFY")
[ -n "$trust_line" ] && [ "$trust_line" -lt "$status_line" ] || fail 'verify executes Tailscale before trust validation'
grep -Fq "{64}" "$VERIFY" && grep -Fq 'shasum -a 256 "$path"' "$VERIFY" || fail 'verify does not validate SHA-256 manifest entries'
grep -q 'kickstart -kp' "$VERIFY" && grep -q 'health_value process_id' "$VERIFY" || fail 'verify does not bind health to the kicked process'

if "$VERIFY" --target '-unsafe' >/dev/null 2>&1; then fail 'verify accepted option-like target'; fi
if "$VERIFY" --ports '22,70000' >/dev/null 2>&1; then fail 'verify accepted invalid port'; fi
if "$VERIFY" --ports '22' >/dev/null 2>&1; then fail 'verify accepted ports without target'; fi

TAILNET_KEEPER_VERIFY_TESTING=1 bash -c '
    set -euo pipefail
    source "$1"
    health_is_fresh healthy 100 100 old-inode new-inode 123 123
    if health_is_fresh healthy 100 100 old-inode new-inode 123 124; then exit 1; fi
    if health_is_fresh healthy 99 100 old-inode new-inode 123 123; then exit 1; fi
    if health_is_fresh healthy 100 100 same-inode same-inode 123 123; then exit 1; fi
    if health_is_fresh degraded 100 100 old-inode new-inode 123 123; then exit 1; fi

    manifest=$2/manifest
    expected_manifest_paths >"$manifest"
    digest=$(printf "0%.0s" {1..64})
    awk -v digest="$digest" "{ print digest \"  \" \$0 }" "$manifest" >"$manifest.valid"
    manifest_declares_exact_paths "$manifest.valid"
    printf "%s  %s\n" "$digest" "$MODULE_DIR/tailnet-keeper" >>"$manifest.valid"
    if manifest_declares_exact_paths "$manifest.valid"; then exit 1; fi

    [ "$(managed_path_mode "$MODULE_DIR/tailnet-keeper")" = 755 ]
    [ "$(managed_path_mode "$MODULE_DIR/common.sh")" = 644 ]
    [ "$(managed_path_mode "$PF_RULES")" = 644 ]

    acl_path="$2/acl-path"
    mkdir "$acl_path"
    chmod +a "everyone allow write" "$acl_path"
    path_has_acl "$acl_path"
    chmod -N "$acl_path"
    ! path_has_acl "$acl_path"

    VERIFY_TMPDIR=$2/cleanup
    mkdir "$VERIFY_TMPDIR"
    cleanup_verify_tmpdir
    [ ! -e "$VERIFY_TMPDIR" ]

    # /etc and /var are root-owned symlinks into /private on macOS.
    managed_ancestors_are_safe /etc/pf.anchors/tailnet-keeper
    managed_ancestors_are_safe /var/log/anything

    unsafe_root=$2/unsafe
    mkdir -p "$unsafe_root/dir"
    chmod 0777 "$unsafe_root/dir"
    if managed_ancestors_are_safe "$unsafe_root/dir/file"; then exit 1; fi
    chmod 0755 "$unsafe_root/dir"
    ln -s "$unsafe_root/dir" "$unsafe_root/link"
    if managed_ancestors_are_safe "$unsafe_root/link/file"; then exit 1; fi

    # Root executes these, so a user-writable replacement must be rejected.
    trusted_external_executable /bin/ls
    writable_tool=$2/writable-tool
    printf "#!/bin/sh\nexit 0\n" >"$writable_tool"
    chmod 0777 "$writable_tool"
    if trusted_external_executable "$writable_tool"; then exit 1; fi
    if trusted_external_executable "$2/missing-tool"; then exit 1; fi

    if [ -L /usr/local/bin/mullvad ]; then
        signed_cli_link_is_expected /usr/local/bin/mullvad \
            "/Applications/Mullvad VPN.app/Contents/Resources/mullvad" \
            "/Applications/Mullvad VPN.app" net.mullvad.vpn CKG9MXH72F
    fi
    if [ -L /usr/local/bin/orb ] && [ -L /usr/local/bin/docker ]; then
        signed_cli_link_is_expected /usr/local/bin/orb \
            /Applications/OrbStack.app/Contents/MacOS/bin/orb \
            /Applications/OrbStack.app dev.kdrag0n.MacVirt HUAQ24HBR6
        signed_cli_link_is_expected /usr/local/bin/docker \
            /Applications/OrbStack.app/Contents/MacOS/xbin/docker \
            /Applications/OrbStack.app dev.kdrag0n.MacVirt HUAQ24HBR6
    fi
' _ "$VERIFY" "$TEST_TMP" || fail 'verify manifest, metadata, or cleanup contract failed'

for command in TAILSCALE MULLVAD ORB DOCKER; do
    grep -q "run_as_console_user \"\\\$$command\"" "$VERIFY" || fail "verify executes $command with root privileges"
done
! grep -q 'MULLVAD.*|.*grep' "$VERIFY" || fail 'verify exposes Mullvad status to pipefail SIGPIPE'

# TAILNET_KEEPER_TESTING makes tool paths environment-overridable, so the root
# verifier must not use it merely to suppress the keeper's auto-run.
! grep -q 'export TAILNET_KEEPER_TESTING=1' "$VERIFY" || fail 'verify enables environment-overridable tool paths'
grep -q 'export TAILNET_KEEPER_SOURCE_ONLY=1' "$VERIFY" || fail 'verify does not suppress the keeper auto-run safely'
grep -q 'TAILNET_KEEPER_SOURCE_ONLY' "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'keeper does not honour a side-effect-free source'
TAILNET_KEEPER_SOURCE_ONLY=1 bash -c '
    set -euo pipefail
    source "$1"
    [ "$CODESIGN" = /usr/bin/codesign ] || exit 1
    [ "$ROUTE" = /sbin/route ] || exit 1
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'source-only mode still honours tool path overrides'
TAILNET_KEEPER_SOURCE_ONLY=1 TAILNET_KEEPER_CODESIGN=/usr/bin/true bash -c '
    set -euo pipefail
    source "$1"
    [ "$CODESIGN" = /usr/bin/codesign ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'a codesign override survived source-only mode'

# An empty IPv6 relay family is a supported healthy state, so verify must
# compare cache and table instead of requiring a populated table.
! grep -q '\[ -n "\$expected6" \]' "$VERIFY" || fail 'verify fails a legitimately empty IPv6 relay set'
grep -q 'run_as_console_user "\$TAILSCALE" status --json .* || fail' "$VERIFY" || fail 'verify can exit without reporting a Tailscale failure'

# Stock macOS ships bash 3.2, where an empty array under `set -u` is unbound.
# A target without ports is a supported routing-only check.
grep -q 'for port in \${port_list\[@\]+"\${port_list\[@\]}"}' "$VERIFY" || fail 'verify crashes on a target without ports'
/bin/bash -c '
    set -euo pipefail
    port_list=()
    for port in ${port_list[@]+"${port_list[@]}"}; do :; done
' || fail 'the empty-port expansion is not bash 3.2 safe'

grep -q 'target port $port is unreachable' "$VERIFY" || fail 'verify probe failure discloses the tailnet target'

# The reconciliation that writes health runs in a lockf child, so health must
# record the launchd-visible pid or verify's freshness binding can never match.
grep -q 'TAILNET_KEEPER_SERVICE_PID' "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'keeper does not carry the launchd-visible pid into its locked child'
grep -q 'TAILNET_KEEPER_SERVICE_PID' "$PROJECT_ROOT/libexec/common.sh" || fail 'health records the child pid instead of the service pid'
TAILNET_KEEPER_PID_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-pid.XXXXXX")
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$TAILNET_KEEPER_PID_SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$TAILNET_KEEPER_PID_SANDBOX/run" \
TAILNET_KEEPER_SERVICE_PID=4242 \
bash -c '
    set -euo pipefail
    source "$1"
    mkdir -p "$STATE_DIR" "$RUNTIME_DIR"
    write_health healthy reconciled
    [ "$(awk -F= "\$1 == \"process_id\" { print \$2 }" "$HEALTH_STATE")" = 4242 ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'health did not record the launchd-visible pid'
rm -rf "$TAILNET_KEEPER_PID_SANDBOX"

printf 'verify_cli=PASS\n'
