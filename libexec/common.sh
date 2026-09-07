# Shared constants and state.
if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ]; then
    readonly PFCTL=${TAILNET_KEEPER_PFCTL:-/sbin/pfctl}
    readonly ROUTE=${TAILNET_KEEPER_ROUTE:-/sbin/route}
else
    readonly PFCTL=/sbin/pfctl
    readonly ROUTE=/sbin/route
fi
readonly IFCONFIG=/sbin/ifconfig
if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ]; then
    readonly NETSTAT=${TAILNET_KEEPER_NETSTAT:-/usr/sbin/netstat}
else
    readonly NETSTAT=/usr/sbin/netstat
fi
if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ]; then
    readonly SCUTIL=${TAILNET_KEEPER_SCUTIL:-/usr/sbin/scutil}
    readonly SYSCTL=${TAILNET_KEEPER_SYSCTL:-/usr/sbin/sysctl}
else
    readonly SCUTIL=/usr/sbin/scutil
    readonly SYSCTL=/usr/sbin/sysctl
fi
readonly LOGGER=/usr/bin/logger
readonly LOCKF=/usr/bin/lockf
readonly PLUTIL=/usr/bin/plutil
readonly XMLLINT=/usr/bin/xmllint
if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ]; then
    readonly CODESIGN=${TAILNET_KEEPER_CODESIGN:-/usr/bin/codesign}
else
    readonly CODESIGN=/usr/bin/codesign
fi
readonly AWK=/usr/bin/awk
readonly SED=/usr/bin/sed
readonly GREP=/usr/bin/grep
readonly SORT=/usr/bin/sort
readonly COMM=/usr/bin/comm
readonly STAT=/usr/bin/stat
readonly DATE=/bin/date
readonly CAT=/bin/cat
readonly MKDIR=/bin/mkdir

if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ]; then
    readonly MV=${TAILNET_KEEPER_MV:-/bin/mv}
else
    readonly MV=/bin/mv
fi
readonly RM=/bin/rm
readonly CP=/bin/cp
readonly CHMOD=/bin/chmod
readonly KILL=/bin/kill

readonly SLEEP=/bin/sleep
if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ]; then
    readonly CURL=${TAILNET_KEEPER_CURL:-/usr/bin/curl}
else
    readonly CURL=/usr/bin/curl
fi
if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ]; then
    readonly NETWORKSETUP=${TAILNET_KEEPER_NETWORKSETUP:-/usr/sbin/networksetup}
else
    readonly NETWORKSETUP=/usr/sbin/networksetup
fi
readonly TAILSCALE_APP=/Applications/Tailscale.app
if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ]; then
    readonly TAILSCALE_CLI=${TAILNET_KEEPER_TAILSCALE_CLI:-"$TAILSCALE_APP/Contents/MacOS/Tailscale"}
else
    readonly TAILSCALE_CLI="$TAILSCALE_APP/Contents/MacOS/Tailscale"
fi

readonly SOURCE_RULES=${TAILNET_KEEPER_RULES:-/etc/pf.anchors/tailnet-keeper}
readonly CONFIG_FILE=${TAILNET_KEEPER_CONFIG:-/usr/local/etc/tailnet-keeper.conf}
readonly STATE_DIR=${TAILNET_KEEPER_STATE_DIR:-/var/db/tailnet-keeper}
readonly RUNTIME_DIR=${TAILNET_KEEPER_RUNTIME_DIR:-/var/run/tailnet-keeper}
readonly ANCHOR=com.apple/io.github.andredezzy.tailnet-keeper
readonly DERP_CACHE="$STATE_DIR/derp-ipv4"
readonly DERP_IPV6_CACHE="$STATE_DIR/derp-ipv6"
readonly DERP_MAP="$RUNTIME_DIR/derp-map.json"
readonly ROUTE_JOURNAL="$STATE_DIR/routes"
readonly GATEWAY_STATE="$STATE_DIR/gateway"
readonly VPN_BOOT_STATE="$STATE_DIR/vpn-boot"
readonly VPN_RECOVERY_STATE="$STATE_DIR/vpn-recovery"
readonly VPN_RETRY_STATE="$STATE_DIR/vpn-retry"
readonly VPN_RECOVERY_FAILURE_STATE="$STATE_DIR/vpn-recovery-failed"
readonly HEALTH_STATE="$STATE_DIR/health"
readonly RUNTIME_RULES="$RUNTIME_DIR/rules.pf"

readonly REFRESH_SECONDS=3600
readonly BOOT_RECONCILE_SECONDS=600
readonly VPN_RECOVERY_MAX_ATTEMPTS=20
readonly VPN_RETRY_MAX_ATTEMPTS=3
readonly MAX_DERP_ADDRESSES=512
readonly CONTROL_IPV4=192.200.0.0/24
readonly LOGGING_IPV4=199.165.136.0/24
readonly CONTROL_IPV6=2606:b740:49::/48
readonly LOGGING_IPV6=2606:b740:1::/48

RESTART_TAILSCALE_AFTER_BOOT=off
physical_ipv4_gateway=
physical_interface=
physical_ipv6_gateway=
tailscale_interface=

prepare_directory() {
    local directory=$1
    [ ! -L "$directory" ] || return 1
    "$MKDIR" -p "$directory" || return 1
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    "$CHMOD" 0700 "$directory" || return 1

    if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ]; then
        [ "$("$STAT" -f %Lp "$directory")" = 700 ]
    else
        [ "$("$STAT" -f '%Su:%Sg:%Lp' "$directory")" = root:wheel:700 ]
    fi
}

prepare_directories() {
    prepare_directory "$STATE_DIR" && prepare_directory "$RUNTIME_DIR"
}

trusted_root_file() {
    local path=$1
    local mode=$2
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ]; then
        [ "$("$STAT" -f %Lp "$path")" = "$mode" ]
    else
        [ "$("$STAT" -f '%Su:%Sg:%Lp' "$path")" = "root:wheel:$mode" ]
    fi
}

prepare_state_file() {
    local path=$1
    local temporary="${path}.new"
    [ ! -L "$path" ] && [ ! -L "$temporary" ] || return 1
    if [ ! -e "$path" ]; then
        : >"$temporary" || return 1
        "$CHMOD" 0600 "$temporary" || return 1
        "$MV" "$temporary" "$path" || return 1
    fi
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    "$CHMOD" 0600 "$path" || return 1
    if [ "${TAILNET_KEEPER_TESTING:-0}" = 1 ]; then
        [ "$("$STAT" -f %Lp "$path")" = 600 ]
    else
        [ "$("$STAT" -f '%Su:%Sg:%Lp' "$path")" = root:wheel:600 ]
    fi
}

prepare_runtime_state() {
    prepare_state_file "$DERP_CACHE" &&
        prepare_state_file "$DERP_IPV6_CACHE" &&
        prepare_state_file "$ROUTE_JOURNAL"
}

write_health() {
    local status=$1
    local detail=$2
    local temporary="$HEALTH_STATE.new"

    {
        printf 'status=%s\n' "$status"
        printf 'detail=%s\n' "$detail"
        printf 'updated_at=%s\n' "$("$DATE" -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'process_id=%s\n' "${TAILNET_KEEPER_SERVICE_PID:-$$}"
        printf 'physical_interface=%s\n' "$physical_interface"
        printf 'physical_ipv4_gateway=%s\n' "$physical_ipv4_gateway"
        printf 'physical_ipv6_gateway=%s\n' "$physical_ipv6_gateway"
        printf 'tailscale_interface=%s\n' "$tailscale_interface"
    } >"$temporary"
    "$CHMOD" 0600 "$temporary"
    "$MV" "$temporary" "$HEALTH_STATE"
}
log_error() {
    "$LOGGER" -t tailnet-keeper "$1"
    write_health degraded "$1"
}
with_lock() {
    local lock=$1
    shift
    "$LOCKF" -t 0 "$lock" "$@"
}
file_has_terminating_newline() {
    local path=$1
    [ ! -s "$path" ] || [ "$(/usr/bin/tail -c 1 "$path" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ]
}

load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    [ ! -L "$CONFIG_FILE" ] || return 1
    [ "$("$STAT" -f '%Su:%Sg:%Lp' "$CONFIG_FILE")" = root:wheel:600 ] || return 1
    file_has_terminating_newline "$CONFIG_FILE" || return 1

    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            ''|'#'*) continue ;;
            RESTART_TAILSCALE_AFTER_BOOT)
                case "$value" in on|off) RESTART_TAILSCALE_AFTER_BOOT=$value ;; *) return 1 ;; esac
                ;;
            *) return 1 ;;
        esac
    done <"$CONFIG_FILE"
}
