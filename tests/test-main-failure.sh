#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-main.XXXXXX")
trap 'chmod -R u+w "$SANDBOX" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/state" "$SANDBOX/run"
: >"$SANDBOX/rules.pf"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
TAILNET_KEEPER_RULES="$SANDBOX/rules.pf" \
TAILNET_KEEPER_CONFIG="$SANDBOX/absent.conf" \
bash -c '
    set -uo pipefail
    source "$1"
    pf_enabled() { return 0; }
    find_physical_ipv4_route() { cat >/dev/null; printf "192.168.0.1 en0\n"; }
    find_physical_ipv6_route() { cat >/dev/null; return 0; }
    ensure_calls=0
    ensure_owned_route() {
        ensure_calls=$((ensure_calls + 1))
        [ "$ensure_calls" -lt 2 ]
    }
    fail_closed() { printf called >"$STATE_DIR/fail-closed"; }
    log_error() { printf "%s\n" "$1" >"$HEALTH_STATE"; }

    main
    result=$?
    [ "$result" -eq 24 ]
    [ -f "$STATE_DIR/fail-closed" ]
    [ "$(cat "$HEALTH_STATE")" = infrastructure_route_failed ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'infrastructure route failure was not fail-closed'

TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
TAILNET_KEEPER_RULES="$SANDBOX/rules.pf" \
TAILNET_KEEPER_CONFIG="$SANDBOX/absent.conf" \
bash -c '
    set -uo pipefail
    source "$1"
    prepare_runtime_state() { return 0; }
    load_config() { return 0; }
    pf_enabled() { return 0; }
    find_physical_ipv4_route() { cat >/dev/null; printf "192.168.0.1 en0\n"; }
    find_physical_ipv6_route() { cat >/dev/null; return 0; }
    ensure_owned_route() { return 0; }
    retire_owned_route() { return 0; }
    find_tailscale_interface() { printf utun0; }
    load_anchor() { return 0; }
    refresh_derp_routes() { return 2; }
    routes_complete() { return 0; }
    fail_closed() { : >"$STATE_DIR/incomplete-rollback-closed"; }
    log_error() { printf "%s\n" "$1" >"$HEALTH_STATE"; }
    main
    result=$?
    [ "$result" -eq 26 ]
    [ -f "$STATE_DIR/incomplete-rollback-closed" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'incomplete DERP rollback was treated as last-known-good'

TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
TAILNET_KEEPER_RULES="$SANDBOX/rules.pf" \
TAILNET_KEEPER_CONFIG="$SANDBOX/absent.conf" \
bash -c '
    set -uo pipefail
    source "$1"
    prepare_runtime_state() { return 0; }
    load_config() { return 0; }
    pf_enabled() { return 0; }
    find_physical_ipv4_route() { cat >/dev/null; printf "192.168.0.1 en0\n"; }
    find_physical_ipv6_route() { cat >/dev/null; return 0; }
    ensure_owned_route() { return 0; }
    retire_owned_route() { return 0; }
    find_tailscale_interface() { printf utun0; }
    load_anchor() { return 0; }
    refresh_derp_routes() { return 1; }
    routes_complete() { return 0; }
    reconcile_vpn_after_boot() { : >"$STATE_DIR/vpn-reconciled"; return 0; }
    log_error() { printf "%s\n" "$1" >"$HEALTH_STATE"; }
    main
    result=$?
    [ "$result" -eq 27 ]
    [ -f "$STATE_DIR/vpn-reconciled" ]
    [ "$(cat "$HEALTH_STATE")" = derp_refresh_failed_using_last_known_good ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'recoverable DERP failure skipped VPN reconciliation'
rm -f "$SANDBOX/state/vpn-reconciled"

TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
TAILNET_KEEPER_RULES="$SANDBOX/rules.pf" \
TAILNET_KEEPER_CONFIG="$SANDBOX/absent.conf" \
bash -c '
    set -uo pipefail
    source "$1"
    prepare_runtime_state() { return 0; }
    load_config() { return 0; }
    pf_enabled() { return 0; }
    find_physical_ipv4_route() { cat >/dev/null; printf "192.168.0.1 en0\n"; }
    find_physical_ipv6_route() { cat >/dev/null; return 0; }
    ensure_owned_route() { return 0; }
    retire_owned_route() { return 0; }
    find_tailscale_interface() { printf utun0; }
    load_anchor() { return 0; }
    refresh_derp_routes() { return 1; }
    routes_complete() { return 0; }
    reconcile_vpn_after_boot() { return 10; }
    write_health() { printf "%s|%s\n" "$1" "$2" >"$HEALTH_STATE"; }
    main
    [ "$?" -eq 0 ]
    [ "$(cat "$HEALTH_STATE")" = "recovering|tailscale_boot_recovery_derp_refresh_failed_using_last_known_good" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'VPN recovery hid degraded DERP refresh'

TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
TAILNET_KEEPER_RULES="$SANDBOX/rules.pf" \
TAILNET_KEEPER_CONFIG="$SANDBOX/absent.conf" \
TAILNET_KEEPER_CONFIG="$SANDBOX/config" \
bash -c '
    set -uo pipefail
    source "$1"
    prepare_runtime_state() { return 0; }
    load_config() { return 0; }
    pf_enabled() { return 0; }
    find_physical_ipv4_route() { cat >/dev/null; printf "192.168.0.1 en0\n"; }
    find_physical_ipv6_route() { cat >/dev/null; return 0; }
    ensure_owned_route() { return 0; }
    retire_owned_route() { return 0; }
    find_tailscale_interface() { printf utun0; }
    load_anchor() { return 0; }
    refresh_derp_routes() { return 1; }
    routes_complete() { return 0; }
    reconcile_vpn_after_boot() { return 11; }
    write_health() { printf "%s|%s\n" "$1" "$2" >"$HEALTH_STATE"; }
    main
    [ "$?" -eq 0 ]
    [ "$(cat "$HEALTH_STATE")" = "recovering|tailscale_boot_retry_derp_refresh_failed_using_last_known_good" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'active VPN retry was reported as terminal or hid DERP degradation'

TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
TAILNET_KEEPER_RULES="$SANDBOX/rules.pf" \
TAILNET_KEEPER_CONFIG="$SANDBOX/absent.conf" \
bash -c '
    set -uo pipefail
    source "$1"
    prepare_runtime_state() { return 0; }
    load_config() { return 0; }
    pf_enabled() { return 0; }
    find_physical_ipv4_route() { cat >/dev/null; printf "192.168.0.1 en0\n"; }
    find_physical_ipv6_route() { cat >/dev/null; return 0; }
    ensure_owned_route() { return 0; }
    retire_owned_route() { return 0; }
    find_tailscale_interface() { printf utun0; }
    load_anchor() { return 0; }
    refresh_derp_routes() { return 1; }
    routes_complete() { return 0; }
    reconcile_vpn_after_boot() { return 1; }
    log_error() { printf "%s\n" "$1" >"$HEALTH_STATE"; }
    main
    [ "$?" -eq 28 ]
    [ "$(cat "$HEALTH_STATE")" = tailscale_boot_recovery_failed_derp_refresh_failed_using_last_known_good ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'terminal VPN failure hid simultaneous DERP degradation'

# Health lives in the state directory this path cannot trust, so a stale
# healthy record must not survive an unsafe-runtime exit.
printf 'status=healthy\n' >"$SANDBOX/state/health"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
TAILNET_KEEPER_RULES="$SANDBOX/rules.pf" \
TAILNET_KEEPER_CONFIG="$SANDBOX/absent.conf" \
bash -c '
    set -uo pipefail
    source "$1"
    prepare_runtime_state() { return 1; }
    clear_anchor() { return 0; }
    main
    [ "$?" -eq 19 ]
    [ ! -e "$HEALTH_STATE" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'unsafe runtime state left a stale healthy record'

TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
TAILNET_KEEPER_RULES="$SANDBOX/rules.pf" \
TAILNET_KEEPER_CONFIG="$SANDBOX/absent.conf" \
bash -c '
    set -uo pipefail
    source "$1"
    prepare_runtime_state() { return 1; }
    clear_anchor() { printf called >"$RUNTIME_DIR/anchor-cleared"; }
    main
    [ "$?" -eq 19 ]
    [ -f "$RUNTIME_DIR/anchor-cleared" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'unsafe runtime state left the PF bypass active'

mkdir -p "$SANDBOX/untrusted-state"
printf 'status=healthy\ndetail=reconciled\n' >"$SANDBOX/untrusted-state/health"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/untrusted-state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
TAILNET_KEEPER_RULES="$SANDBOX/rules.pf" \
TAILNET_KEEPER_CONFIG="$SANDBOX/absent.conf" \
bash -c '
    set -uo pipefail
    source "$1"
    prepare_directories() { return 1; }
    marker="$2/startup-anchor-cleared"
    clear_anchor() { : >"$marker"; }
    result=0
    run_locked || result=$?
    [ "$result" -eq 70 ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" "$SANDBOX" \
    || fail 'startup directory failure returned the wrong status'
[ -e "$SANDBOX/startup-anchor-cleared" ] || fail 'startup directory failure left the PF bypass active'
[ ! -e "$SANDBOX/untrusted-state/health" ] || fail 'untrusted state directory left a stale health record'

rm -f "$SANDBOX/run/anchor-cleared"
chmod 0500 "$SANDBOX/state"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
TAILNET_KEEPER_RULES="$SANDBOX/rules.pf" \
TAILNET_KEEPER_CONFIG="$SANDBOX/absent.conf" \
bash -c '
    set -uo pipefail
    source "$1"
    clear_anchor() { printf called >"$RUNTIME_DIR/anchor-cleared"; }
    ! fail_closed 2>/dev/null
    [ -f "$RUNTIME_DIR/anchor-cleared" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'fail-closed left PF active when cleanup journal creation failed'
chmod 0700 "$SANDBOX/state"

journal_entry='8.8.8.8|-inet|192.168.0.1|en0|-|-'
printf '%s\n' "$journal_entry" >"$SANDBOX/state/routes"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
TAILNET_KEEPER_RULES="$SANDBOX/rules.pf" \
TAILNET_KEEPER_CONFIG="$SANDBOX/absent.conf" \
bash -c '
    set -uo pipefail
    source "$1"
    clear_anchor() { return 0; }
    restore_journaled_route() { chmod 0400 "$ROUTE_JOURNAL.cleanup"; return 1; }
    ! fail_closed 2>/dev/null
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || fail 'fail-closed reported success after replacement journal write failed'
chmod 0600 "$SANDBOX/state/routes" "$SANDBOX/state/routes.cleanup" 2>/dev/null || true
[ "$(cat "$SANDBOX/state/routes")" = "$journal_entry" ] || fail 'fail-closed replaced the journal after an entry write failed'

printf 'main_failure=PASS\n'
