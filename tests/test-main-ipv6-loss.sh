#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-ipv6-loss.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/state" "$SANDBOX/run"
: >"$SANDBOX/rules"
printf '8.8.8.8\n' >"$SANDBOX/state/derp-ipv4"
: >"$SANDBOX/state/derp-ipv6"
printf '192.168.1.1  en0\n' >"$SANDBOX/state/gateway"
: >"$SANDBOX/state/routes"

TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_SOURCE_RULES="$SANDBOX/rules" \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -uo pipefail
    source "$1"
    load_config() { return 0; }
    trusted_root_file() { return 0; }
    pf_enabled() { return 0; }
    find_physical_ipv4_route() { printf "192.168.1.1 en0\n"; }
    find_physical_ipv6_route() { return 0; }
    ensure_owned_route() { return 0; }
    retire_owned_route() { printf "%s\n" "$1" >>"$RUNTIME_DIR/retired"; }
    find_tailscale_interface() { return 1; }
    load_anchor() { return 0; }
    routes_complete() { return 0; }
    reconcile_vpn_after_boot() { return 0; }
    write_health() { return 0; }
    main
    cat >"$RUNTIME_DIR/expected" <<EOF
2606:b740:49::/48
2606:b740:1::/48
EOF
    if ! cmp -s "$RUNTIME_DIR/expected" "$RUNTIME_DIR/retired"; then
        printf "expected:\n" >&2
        cat "$RUNTIME_DIR/expected" >&2
        printf "actual:\n" >&2
        cat "$RUNTIME_DIR/retired" >&2
        exit 1
    fi
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: IPv6 gateway loss retained static bypass routes\n' >&2
    exit 1
}

rm -f "$SANDBOX/run/retired"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_SOURCE_RULES="$SANDBOX/rules" \
TAILNET_KEEPER_STATE_DIR="$SANDBOX/state" \
TAILNET_KEEPER_RUNTIME_DIR="$SANDBOX/run" \
bash -c '
    set -uo pipefail
    source "$1"
    load_config() { return 0; }
    trusted_root_file() { return 0; }
    pf_enabled() { return 0; }
    find_physical_ipv4_route() { printf "192.168.1.1 en0\n"; }
    find_physical_ipv6_route() { return 2; }
    ensure_owned_route() { return 0; }
    retire_owned_route() { : >"$RUNTIME_DIR/retired"; }
    refresh_derp_routes() { return 0; }
    routes_complete() { return 0; }
    find_tailscale_interface() { return 1; }
    load_anchor() { return 0; }
    reconcile_vpn_after_boot() { return 0; }
    write_health() { return 0; }
    fail_safely() { : >"$RUNTIME_DIR/failed-closed"; }
    ! main
    [ -e "$RUNTIME_DIR/failed-closed" ]
    [ ! -e "$RUNTIME_DIR/retired" ]
' _ "$PROJECT_ROOT/bin/tailnet-keeper" || {
    printf 'FAIL: IPv6 inspection failure was treated as absence\n' >&2
    exit 1
}

printf 'main_ipv6_loss=PASS\n'
