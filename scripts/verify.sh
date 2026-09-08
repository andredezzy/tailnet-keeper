#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly SERVICE_LABEL=io.github.andredezzy.tailnet-keeper
readonly MODULE_DIR=/usr/local/libexec/tailnet-keeper
readonly KEEPER="$MODULE_DIR/tailnet-keeper"
readonly PF_RULES=/etc/pf.anchors/tailnet-keeper
readonly CONFIG=/usr/local/etc/tailnet-keeper.conf
readonly INSTALL_MANIFEST=/var/db/tailnet-keeper/install-manifest
readonly VERIFY_STATE_DIR=/var/db/tailnet-keeper
readonly HEALTH="$VERIFY_STATE_DIR/health"
readonly DERP4="$VERIFY_STATE_DIR/derp-ipv4"
readonly DERP6="$VERIFY_STATE_DIR/derp-ipv6"
readonly VERIFY_ANCHOR=com.apple/io.github.andredezzy.tailnet-keeper
readonly TAILSCALE=/Applications/Tailscale.app/Contents/MacOS/Tailscale
readonly MULLVAD=/usr/local/bin/mullvad
readonly ORB=/usr/local/bin/orb
readonly DOCKER=/usr/local/bin/docker
readonly MULLVAD_TARGET='/Applications/Mullvad VPN.app/Contents/Resources/mullvad'
readonly MULLVAD_APP='/Applications/Mullvad VPN.app'
readonly ORB_TARGET=/Applications/OrbStack.app/Contents/MacOS/bin/orb
readonly DOCKER_TARGET=/Applications/OrbStack.app/Contents/MacOS/xbin/docker
readonly ORBSTACK_APP=/Applications/OrbStack.app
VERIFY_TMPDIR=
CONSOLE_USER=

usage() {
    printf '%s\n' 'Usage: sudo scripts/verify.sh [--target HOST --ports PORTS] [--check-orbstack]'
    printf '%s\n' '  --target HOST       Tailnet host or IP to probe'
    printf '%s\n' '  --ports PORTS       Comma-separated TCP ports for --target'
    printf '%s\n' '  --check-orbstack    Require OrbStack, Docker, and an unchanged Internet Sharing anchor'
}

fail() {
    printf 'FAIL %s\n' "$1" >&2
    exit 1
}

# PF prints IPv6 in its own canonical spelling, so a table read back from the
# kernel never matches a cached address byte for byte. The keeper already
# solves this; the verifier borrows that implementation instead of keeping a
# second copy that can drift out of agreement with it.
canonical_addresses() {
    TAILNET_KEEPER_SOURCE_ONLY=1 /bin/bash -c '
        TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"
        canonical_address_set
    ' _ "$KEEPER"
}

health_value() {
    local key=$1
    /usr/bin/awk -F= -v key="$key" '$1 == key { print $2; exit }' "$HEALTH"
}

health_is_fresh() {
    local status=$1
    local modified_at=$2
    local started_at=$3
    local previous_inode=$4
    local current_inode=$5
    local expected_process_id=$6
    local actual_process_id=$7
    [[ "$expected_process_id" =~ ^[0-9]+$ ]] &&
        [ "$status" = healthy ] &&
        [ "$modified_at" -ge "$started_at" ] &&
        [ "$current_inode" != "$previous_inode" ] &&
        [ "$actual_process_id" = "$expected_process_id" ]
}

allowed_manifest_path() {
    case "$1" in
        "$MODULE_DIR/tailnet-keeper"|"$MODULE_DIR/common.sh"|"$MODULE_DIR/routes.sh"|"$MODULE_DIR/firewall.sh"|"$MODULE_DIR/tailscale.sh"|"$MODULE_DIR/derp.sh"|"$PF_RULES"|"/Library/LaunchDaemons/$SERVICE_LABEL.plist") return 0 ;;
        *) return 1 ;;
    esac
}

path_has_acl() {
    /bin/ls -lde "$1" 2>/dev/null |
        /usr/bin/awk 'NR > 1 && $1 ~ /^[0-9]+:/ { found=1 } END { exit !found }'
}

# Walks every ancestor of a managed path and requires each one to be
# root-owned, not group- or world-writable, and free of ACLs.
#
# macOS ships /etc and /var as root-owned symlinks into /private, so a
# symlinked ancestor cannot be rejected outright. A symlink is accepted only
# when the link itself is root-owned and safe, and the walk then continues
# through its resolved target so the real directories are checked too.
managed_ancestors_are_safe() {
    local current mode resolved
    current=$(/usr/bin/dirname "$1")
    while :; do
        [ "$(/usr/bin/stat -f '%Su:%Sg' "$current")" = root:wheel ] || return 1
        mode=$(/usr/bin/stat -f %Lp "$current")
        (( (8#$mode & 0022) == 0 )) || return 1
        ! path_has_acl "$current" || return 1

        if [ -L "$current" ]; then
            resolved=$(cd -P -- "$current" 2>/dev/null && pwd -P) || return 1
            [ "$resolved" != "$current" ] || return 1
            current=$resolved
            continue
        fi

        [ -d "$current" ] || return 1
        [ "$current" != / ] || break
        current=$(/usr/bin/dirname "$current")
    done
}

expected_manifest_paths() {
    printf '%s\n' \
        "$MODULE_DIR/tailnet-keeper" \
        "$MODULE_DIR/common.sh" \
        "$MODULE_DIR/routes.sh" \
        "$MODULE_DIR/firewall.sh" \
        "$MODULE_DIR/tailscale.sh" \
        "$MODULE_DIR/derp.sh" \
        "$PF_RULES" \
        "/Library/LaunchDaemons/$SERVICE_LABEL.plist"
}

# `shasum` writes "<hash>  <path>", and a managed path may contain spaces, so
# the hash is a fixed-width prefix and the remainder is one path.
manifest_paths() {
    /usr/bin/awk '{ print substr($0, 67) }' "$1"
}

manifest_declares_exact_paths() {
    local manifest=$1 declared expected
    declared=$(manifest_paths "$manifest" | /usr/bin/sort)
    expected=$(expected_manifest_paths | /usr/bin/sort)
    [ "$declared" = "$expected" ]
}

manifest_has_terminating_newline() {
    [ "$(/usr/bin/tail -c 1 "$1" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ]
}

managed_path_mode() {
    case "$1" in
        "$MODULE_DIR/tailnet-keeper") printf '755\n' ;;
        "$MODULE_DIR"/*.sh|"$PF_RULES"|"/Library/LaunchDaemons/$SERVICE_LABEL.plist") printf '644\n' ;;
        *) return 1 ;;
    esac
}

# The verifier runs as root, so any third-party CLI it executes must first be
# proven to be a root-owned, non-writable, ACL-free real file whose ancestors
# are equally safe. Tailscale additionally gets signature validation.
trusted_external_executable() {
    local path=$1 mode
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    [ "$(/usr/bin/stat -f '%Su:%Sg' "$path")" = root:wheel ] || return 1
    mode=$(/usr/bin/stat -f %Lp "$path")
    (( (8#$mode & 0022) == 0 )) || return 1
    (( (8#$mode & 0100) != 0 )) || return 1
    ! path_has_acl "$path" || return 1
    managed_ancestors_are_safe "$path"
}

require_trusted_executable() {
    trusted_external_executable "$1" || fail "untrusted executable: $1"
}

signed_bundle_is_expected() {
    local application=$1 expected_identifier=$2 expected_team=$3
    /usr/bin/codesign --verify --deep --strict "$application" >/dev/null 2>&1 || return 1
    /usr/bin/codesign -dv "$application" 2>&1 |
        /usr/bin/awk -v identifier="$expected_identifier" -v team="$expected_team" '
            $0 == "Identifier=" identifier { id=1 }
            $0 == "TeamIdentifier=" team { signer=1 }
            END { exit !(id && signer) }
        '
}

# Homebrew-style links are expected for these app CLIs. The link itself must
# be root-controlled and point to the exact vendor path; the containing bundle
# must carry the expected valid signature. The command is still executed as
# the console user, which removes the verify-to-execute privilege race for
# user-managed applications.
signed_cli_link_is_expected() {
    local path=$1 expected_target=$2 application=$3 expected_identifier=$4 expected_team=$5 mode
    [ -L "$path" ] && [ -x "$path" ] || return 1
    [ "$(/usr/bin/readlink "$path")" = "$expected_target" ] || return 1
    [ "$(/usr/bin/stat -f '%Su:%Sg' "$path")" = root:wheel ] || return 1
    mode=$(/usr/bin/stat -f %Lp "$path")
    (( (8#$mode & 0022) == 0 )) || return 1
    ! path_has_acl "$path" || return 1
    managed_ancestors_are_safe "$path" || return 1
    signed_bundle_is_expected "$application" "$expected_identifier" "$expected_team"
}

select_console_user() {
    local user uid
    user=$(/usr/bin/stat -f %Su /dev/console) || return 1
    [ -n "$user" ] && [ "$user" != root ] && [ "$user" != loginwindow ] || return 1
    uid=$(/usr/bin/id -u "$user") || return 1
    [ "$uid" -ge 501 ] || return 1
    CONSOLE_USER=$user
}

run_as_console_user() {
    [ -n "$CONSOLE_USER" ] || return 1
    /usr/bin/sudo -n -u "$CONSOLE_USER" -- "$@"
}

cleanup_verify_tmpdir() {
    [ -z "$VERIFY_TMPDIR" ] || /bin/rm -rf "$VERIFY_TMPDIR"
}

verify_manifest() {
    local expected path actual mode
    [ -f "$INSTALL_MANIFEST" ] && [ ! -L "$INSTALL_MANIFEST" ] || return 1
    [ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$INSTALL_MANIFEST")" = root:wheel:600 ] || return 1
    ! path_has_acl "$INSTALL_MANIFEST" || return 1
    managed_ancestors_are_safe "$INSTALL_MANIFEST" || return 1
    manifest_has_terminating_newline "$INSTALL_MANIFEST" || return 1
    manifest_declares_exact_paths "$INSTALL_MANIFEST" || return 1
    while read -r line; do
        expected=${line:0:64}
        path=${line:66}
        [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
        [ -n "$path" ] || return 1
        allowed_manifest_path "$path" || return 1
        [ -f "$path" ] && [ ! -L "$path" ] || return 1
        mode=$(managed_path_mode "$path") || return 1
        [ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$path")" = "root:wheel:$mode" ] || return 1
        ! path_has_acl "$path" || return 1
        managed_ancestors_are_safe "$path" || return 1
        actual=$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{ print $1 }')
        [ "$actual" = "$expected" ] || return 1
    done <"$INSTALL_MANIFEST"
}

wait_for_fresh_health() {
    local started_at=$1
    local previous_inode=$2
    local expected_process_id=$3
    local status modified_at current_inode actual_process_id
    # `kickstart -k` restarts the daemon, so the reconciliation being waited on
    # is a cold one: it reinstalls and verifies one bypass route per DERP relay
    # in both families, measured at 34s. The budget clears that, or the
    # verifier reports failure against a daemon that is working correctly.
    for _ in {1..90}; do
        if [ -f "$HEALTH" ] && [ ! -L "$HEALTH" ]; then
            status=$(health_value status)
            modified_at=$(/usr/bin/stat -f %m "$HEALTH")
            current_inode=$(/usr/bin/stat -f %i "$HEALTH")
            actual_process_id=$(health_value process_id)
            if health_is_fresh "$status" "$modified_at" "$started_at" "$previous_inode" "$current_inode" "$expected_process_id" "$actual_process_id"; then
                return 0
            fi
        fi
        /bin/sleep 2
    done
    return 1
}

main() {
    local target='' ports='' check_orbstack=0
    local started_at previous_health_inode kicked_process_id status physical_interface physical_ipv4_gateway physical_ipv6_gateway tailscale_interface
    local expected_rules loaded_rules expected4 loaded4 expected6 loaded6
    local orb_anchor_before='' orb_anchor_after='' rule_count='' port route mullvad_status
    local -a port_list=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h) usage; return 0 ;;
            --target) [ "$#" -ge 2 ] || fail 'missing target'; target=$2; shift ;;
            --ports) [ "$#" -ge 2 ] || fail 'missing ports'; ports=$2; shift ;;
            --check-orbstack) check_orbstack=1 ;;
            *) fail "unknown argument: $1" ;;
        esac
        shift
    done

    if [ -n "$target" ]; then
        [[ "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || fail 'invalid target'
    fi
    if [ -n "$ports" ]; then
        [ -n "$target" ] || fail 'ports require --target'
        IFS=',' read -r -a port_list <<<"$ports"
        [ "${#port_list[@]}" -gt 0 ] || fail 'empty ports'
        for port in "${port_list[@]}"; do
            [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fail "invalid port: $port"
        done
    fi

    [ "$(/usr/bin/uname -s)" = Darwin ] || fail 'macOS required'
    [ "$EUID" -eq 0 ] || fail 'run with sudo'
    select_console_user || fail 'no logged-in console user is available for app checks'
    verify_manifest || fail 'installation manifest or managed file is invalid'
    [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || fail 'configuration is missing or unsafe'
    [ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$CONFIG")" = root:wheel:600 ] || fail 'configuration ownership or mode is invalid'
    [ -f "$HEALTH" ] && [ ! -L "$HEALTH" ] || fail 'health file is missing or unsafe'
    [ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$HEALTH")" = root:wheel:600 ] || fail 'health ownership or mode is invalid'
    /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1 || fail 'LaunchDaemon is not loaded'

    VERIFY_TMPDIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-verify.XXXXXX")
    trap cleanup_verify_tmpdir EXIT

    if [ "$check_orbstack" -eq 1 ]; then
        [ -x "$ORB" ] && [ -x "$DOCKER" ] || fail 'OrbStack or Docker CLI is missing'
        signed_cli_link_is_expected "$ORB" "$ORB_TARGET" "$ORBSTACK_APP" dev.kdrag0n.MacVirt HUAQ24HBR6 || fail 'OrbStack CLI identity is invalid'
        signed_cli_link_is_expected "$DOCKER" "$DOCKER_TARGET" "$ORBSTACK_APP" dev.kdrag0n.MacVirt HUAQ24HBR6 || fail 'Docker CLI identity is invalid'
        [ "$(run_as_console_user "$ORB" status)" = Running ] || fail 'OrbStack is not running'
        run_as_console_user "$DOCKER" info >/dev/null 2>&1 || fail 'OrbStack Docker API is unavailable'
        /sbin/pfctl -a com.apple.internet-sharing -sr >"$VERIFY_TMPDIR/orb-before" 2>/dev/null
        [ -s "$VERIFY_TMPDIR/orb-before" ] || fail 'OrbStack Internet Sharing anchor is unavailable'
        orb_anchor_before=$(/usr/bin/shasum "$VERIFY_TMPDIR/orb-before" | /usr/bin/awk '{ print $1 }')
    fi

    previous_health_inode=$(/usr/bin/stat -f %i "$HEALTH")
    started_at=$(/bin/date +%s)
    kicked_process_id=$(/bin/launchctl kickstart -kp "system/$SERVICE_LABEL" 2>/dev/null) || fail 'could not start a fresh reconciliation'
    [[ "$kicked_process_id" =~ ^[0-9]+$ ]] || fail 'launchctl returned an invalid process id'
    wait_for_fresh_health "$started_at" "$previous_health_inode" "$kicked_process_id" || fail 'fresh reconciliation did not reach healthy state'

    export TAILNET_KEEPER_SOURCE_ONLY=1
    # shellcheck source=../bin/tailnet-keeper
    source "$KEEPER"
    validate_tailscale_cli || fail 'Tailscale app signature, ownership, or mode is invalid'

    status=$(health_value status)
    physical_interface=$(health_value physical_interface)
    physical_ipv4_gateway=$(health_value physical_ipv4_gateway)
    physical_ipv6_gateway=$(health_value physical_ipv6_gateway)
    tailscale_interface=$(health_value tailscale_interface)
    [ "$status" = healthy ] || fail 'keeper health is not healthy'
    [ -n "$physical_interface" ] && [ -n "$physical_ipv4_gateway" ] || fail 'health omits the physical IPv4 path'

    render_rules "$physical_interface" "$tailscale_interface" "$PF_RULES" >"$VERIFY_TMPDIR/expected.pf"

    /sbin/pfctl -s info 2>/dev/null | /usr/bin/grep -q '^Status: Enabled' || fail 'PF is disabled'
    /sbin/pfctl -sr 2>/dev/null | /usr/bin/grep -q 'anchor "com.apple/\*"' || fail 'Apple wildcard anchor is absent'
    expected_rules=$(/sbin/pfctl -nvf "$VERIFY_TMPDIR/expected.pf" 2>/dev/null | rules_without_tables)
    loaded_rules=$(/sbin/pfctl -a "$VERIFY_ANCHOR" -sr 2>/dev/null)
    [ "$expected_rules" = "$loaded_rules" ] || fail 'keeper PF rules differ from the rendered template'
    rule_count=$(printf '%s\n' "$loaded_rules" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')
    [ "$rule_count" -gt 0 ] || fail 'keeper PF anchor is empty'

    expected4=$(/usr/bin/sort -u "$DERP4")
    loaded4=$(/sbin/pfctl -a "$VERIFY_ANCHOR" -t tailscale_derp -T show 2>/dev/null | /usr/bin/awk '{$1=$1; print}' | /usr/bin/sort -u)
    [ -n "$expected4" ] && [ "$expected4" = "$loaded4" ] || fail 'IPv4 DERP table differs from cache'
    # An empty IPv6 relay family is legitimate, so compare cache and table
    # rather than requiring the table to be populated.
    expected6=$(canonical_addresses <"$DERP6")
    loaded6=$(/sbin/pfctl -a "$VERIFY_ANCHOR" -t tailscale_derp6 -T show 2>/dev/null | /usr/bin/awk '{$1=$1; print}' | canonical_addresses)
    [ "$expected6" = "$loaded6" ] || fail 'IPv6 DERP table differs from cache'

    route_matches -inet "$CONTROL_IPV4" "$physical_ipv4_gateway" "$physical_interface" || fail 'IPv4 coordination route is wrong'
    route_matches -inet "$LOGGING_IPV4" "$physical_ipv4_gateway" "$physical_interface" || fail 'IPv4 logging route is wrong'
    while read -r route; do
        route_matches -inet "$route" "$physical_ipv4_gateway" "$physical_interface" || fail 'an IPv4 DERP route is wrong'
    done <"$DERP4"
    if [ -n "$physical_ipv6_gateway" ]; then
        route_matches -inet6 "$CONTROL_IPV6" "$physical_ipv6_gateway" "$physical_interface" || fail 'IPv6 coordination route is wrong'
        route_matches -inet6 "$LOGGING_IPV6" "$physical_ipv6_gateway" "$physical_interface" || fail 'IPv6 logging route is wrong'
        while read -r route; do
            route_matches -inet6 "$route" "$physical_ipv6_gateway" "$physical_interface" || fail 'an IPv6 DERP route is wrong'
        done <"$DERP6"
    fi

    run_as_console_user "$TAILSCALE" status --json >"$VERIFY_TMPDIR/tailscale.json" || fail 'Tailscale status is unavailable'
    [ "$(/usr/bin/plutil -extract BackendState raw -o - "$VERIFY_TMPDIR/tailscale.json")" = Running ] || fail 'Tailscale backend is not running'
    [ "$(/usr/bin/plutil -extract Self.Online raw -o - "$VERIFY_TMPDIR/tailscale.json")" = true ] || fail 'Tailscale is offline'
    signed_cli_link_is_expected "$MULLVAD" "$MULLVAD_TARGET" "$MULLVAD_APP" net.mullvad.vpn CKG9MXH72F || fail 'Mullvad CLI identity is invalid'
    mullvad_status=$(run_as_console_user "$MULLVAD" status) || fail 'Mullvad status is unavailable'
    /usr/bin/grep -q '^Connected' <<<"$mullvad_status" || fail 'Mullvad is not connected'

    if [ -n "$target" ]; then
        [ -n "$tailscale_interface" ] || fail 'health omits the Tailscale interface'
        /sbin/route -n get "$target" 2>/dev/null | /usr/bin/awk -v interface="$tailscale_interface" '
            $1 == "interface:" { actual = $2 }
            END { exit !(actual == interface) }
        ' || fail 'target does not use the current Tailscale interface'
        # Tailnet addresses are sensitive, so failures name the port only.
        # Bash 3.2 treats an empty array under `set -u` as unbound, and a
        # target without ports is a supported routing-only check.
        for port in ${port_list[@]+"${port_list[@]}"}; do
            /usr/bin/nc -z -w 3 "$target" "$port" >/dev/null 2>&1 || fail "target port $port is unreachable"
        done
    fi

    if [ "$check_orbstack" -eq 1 ]; then
        [ "$(run_as_console_user "$ORB" status)" = Running ] || fail 'OrbStack stopped during reconciliation'
        run_as_console_user "$DOCKER" info >/dev/null 2>&1 || fail 'OrbStack Docker API failed after reconciliation'
        /sbin/pfctl -a com.apple.internet-sharing -sr >"$VERIFY_TMPDIR/orb-after" 2>/dev/null
        [ -s "$VERIFY_TMPDIR/orb-after" ] || fail 'OrbStack Internet Sharing anchor disappeared'
        orb_anchor_after=$(/usr/bin/shasum "$VERIFY_TMPDIR/orb-after" | /usr/bin/awk '{ print $1 }')
        [ "$orb_anchor_after" = "$orb_anchor_before" ] || fail 'OrbStack Internet Sharing anchor changed during reconciliation'
    fi

    printf 'PASS keeper=fresh pf_rules=%s derp_ipv4=%s derp_ipv6=%s tailscale=online mullvad=connected\n' \
        "$rule_count" "$(/usr/bin/wc -l <"$DERP4" | /usr/bin/tr -d ' ')" "$(/usr/bin/wc -l <"$DERP6" | /usr/bin/tr -d ' ')"
}

if [ "${TAILNET_KEEPER_VERIFY_TESTING:-0}" != 1 ]; then
    main "$@"
fi
