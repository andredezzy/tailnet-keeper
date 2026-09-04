needs_boot_reconciliation() {
    local current_boot=$1
    local reconciled_boot=$2
    local vpn_status=$3
    local derp_cache_ready=$4
    local boot_uptime=$5

    [ "$current_boot" != "$reconciled_boot" ] &&
        [ "$vpn_status" = Connected ] &&
        [ "$derp_cache_ready" -eq 1 ] &&
        [ "$boot_uptime" -le "$BOOT_RECONCILE_SECONDS" ]
}
vpn_recovery_action() {
    local phase=$1
    local vpn_status=$2
    local attempts=$3

    if [ "$phase" = starting ] && [ "$vpn_status" = Connected ]; then
        printf 'complete\n'
    elif [ "$attempts" -ge "$VPN_RECOVERY_MAX_ATTEMPTS" ] && [ "$phase" = stopping ] && [ "$vpn_status" = Connected ]; then
        printf 'terminal_stop\n'
    elif [ "$attempts" -ge "$VPN_RECOVERY_MAX_ATTEMPTS" ]; then
        printf 'terminal_start\n'
    elif [ "$phase" = none ] && [ "$vpn_status" = Connected ]; then
        printf 'stop\n'
    elif [ "$phase" = stopping ] && [ "$vpn_status" = Connected ]; then
        printf 'stop\n'
    elif [ "$phase" = stopping ] && [ "$vpn_status" = Disconnected ]; then
        printf 'start\n'
    elif [ "$phase" = starting ] && [ "$vpn_status" = Disconnected ]; then
        printf 'start\n'
    else
        printf 'wait\n'
    fi
}

vpn_retry_action() {
    local current_boot=$1
    local retry_boot=$2
    local retry_phase=$3
    local vpn_status=$4
    local retry_attempts=$5
    # An empty boot field means the record cannot belong to this boot. Only a
    # wholly empty record is dormant; anything else is malformed and cleared.
    if [ -z "$retry_boot" ] && [ -z "$retry_phase" ] && [ -z "$retry_attempts" ]; then
        printf 'none\n'
    elif [ -z "$retry_boot" ]; then
        printf 'clear\n'
    elif [ "$current_boot" != "$retry_boot" ]; then
        printf 'clear\n'
    elif [ "$retry_phase" = stopping ]; then
        if [ "$vpn_status" = Connected ]; then
            if [ "$retry_attempts" -ge "$VPN_RETRY_MAX_ATTEMPTS" ]; then
                printf 'exhausted\n'
            else
                printf 'stop\n'
            fi
        else
            printf 'start_transition\n'
        fi
    elif [ "$vpn_status" = Connected ]; then
        printf 'complete\n'
    elif [ "$retry_attempts" -ge "$VPN_RETRY_MAX_ATTEMPTS" ]; then
        printf 'exhausted\n'
    else
        printf 'start\n'
    fi
}
validate_tailscale_cli() {
    [ -f "$TAILSCALE_CLI" ] && [ -x "$TAILSCALE_CLI" ] && [ ! -L "$TAILSCALE_CLI" ] || return 1
    [ "$("$STAT" -f '%Su:%Sg' "$TAILSCALE_CLI")" = root:wheel ] || return 1
    local mode
    mode=$("$STAT" -f '%Lp' "$TAILSCALE_CLI")
    [ $((mode % 100)) -eq 55 ] || return 1
    verify_tailscale_signature "$TAILSCALE_APP"
}
verify_tailscale_signature() {
    local application=$1
    "$CODESIGN" --verify --deep --strict "$application" >/dev/null 2>&1 || return 1
    "$CODESIGN" -dv "$application" 2>&1 |
        "$AWK" '/^Identifier=io\.tailscale\.ipn\.macsys$/ { id=1 } /^TeamIdentifier=W5364U7YZB$/ { team=1 } END { exit !(id && team) }'
}
run_with_timeout() {
    local seconds=$1
    local output=$2
    shift 2

    "$@" >"$output" 2>/dev/null &
    local command_pid=$!
    (
        "$SLEEP" "$seconds"
        "$KILL" -TERM "$command_pid" 2>/dev/null || exit 0
        "$SLEEP" 2
        "$KILL" -KILL "$command_pid" 2>/dev/null || true
    ) &
    local watchdog_pid=$!

    wait "$command_pid"
    local result=$?
    "$KILL" "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    return "$result"
}
boot_uptime() {
    local boot_epoch now
    boot_epoch=$("$SYSCTL" -n kern.boottime | "$AWK" -F'[=,]' '{ gsub(/ /, "", $2); print $2 }')
    now=$("$DATE" +%s)
    printf '%s\n' "$((now - boot_epoch))"
}
find_tailscale_service_id() {
    "$SCUTIL" --nc list 2>/dev/null |
        "$AWK" '/VPN \(io\.tailscale\.ipn\.macsys\)/ { print $3; exit }'
}
vpn_status() {
    "$SCUTIL" --nc status "$1" 2>/dev/null | "$AWK" 'NR == 1 { print; exit }'
}
persist_recovery_state() {
    local boot=$1
    local phase=$2
    local attempts=$3
    printf '%s|%s|%s\n' "$boot" "$phase" "$attempts" >"$VPN_RECOVERY_STATE.new" || return 1
    "$MV" "$VPN_RECOVERY_STATE.new" "$VPN_RECOVERY_STATE"
}

persist_retry_state() {
    local boot=$1
    local phase=$2
    local attempts=$3
    printf '%s|%s|%s\n' "$boot" "$phase" "$attempts" >"$VPN_RETRY_STATE.new" || return 1
    "$MV" "$VPN_RETRY_STATE.new" "$VPN_RETRY_STATE"
}

# launchd watches the immediate recovery file, while the interval path reads the
# retry file. A removal that silently fails would keep stale protocol state
# active while the keeper reports success, so confirm each file is gone.
discard_state_file() {
    local path
    for path in "$@"; do
        "$RM" -f "$path" || return 1
        [ ! -e "$path" ] || return 1
    done
}

record_vpn_recovery_failure() {
    local boot=$1 temporary="$VPN_RECOVERY_FAILURE_STATE.new"
    printf '%s\n' "$boot" >"$temporary" || return 1
    "$MV" "$temporary" "$VPN_RECOVERY_FAILURE_STATE" || return 1
    discard_state_file "$VPN_RECOVERY_STATE" "$VPN_RETRY_STATE" || return 1
}

# launchd keeps relaunching the worker while the recovery file exists, so a
# record that this protocol can no longer advance must be retired even when the
# run cannot proceed. Every early return below passes through here first.
# A zero-byte file still satisfies launchd's PathState, so presence is what
# counts here, not size.
retire_stale_protocol_state() {
    local current_boot=$1 record recorded_boot path
    for path in "$VPN_RECOVERY_STATE" "$VPN_RETRY_STATE"; do
        [ -e "$path" ] || continue
        record=$("$CAT" "$path" 2>/dev/null || true)
        recorded_boot=${record%%|*}
        if [ -z "$record" ] || [ "$recorded_boot" != "$current_boot" ]; then
            discard_state_file "$path" || return 1
        fi
    done
}

# Callable before the boot identity is known: reads it, then retires anything
# that cannot belong to this boot.
discard_stale_boot_state() {
    local current_boot
    current_boot=$("$SYSCTL" -n kern.boottime) || return 1
    retire_stale_protocol_state "$current_boot"
}

reconcile_vpn_after_boot() {
    # launchd's PathState tests existence, so a zero-byte trigger file is not
    # dormant: it must reach the retirement below.
    if [ "$RESTART_TAILSCALE_AFTER_BOOT" != on ] &&
       [ ! -e "$VPN_RECOVERY_STATE" ] && [ ! -e "$VPN_RETRY_STATE" ] &&
       [ ! -s "$VPN_RECOVERY_FAILURE_STATE" ]; then
        return 0
    fi
    local current_boot reconciled_boot failure_boot uptime service_id status phase attempts state action retry_state retry_boot retry_phase retry_attempts retry_action retry_extra recovery_extra
    current_boot=$("$SYSCTL" -n kern.boottime) || return 1
    retire_stale_protocol_state "$current_boot" || return 1
    failure_boot=$("$CAT" "$VPN_RECOVERY_FAILURE_STATE" 2>/dev/null || true)
    if [ -n "$failure_boot" ]; then
        if [ "$failure_boot" = "$current_boot" ]; then
            # The marker is durable, but its companion removal may have failed
            # transiently. Retry it or the trigger stays armed all boot.
            discard_state_file "$VPN_RECOVERY_STATE" "$VPN_RETRY_STATE" || return 1
            return 1
        fi
        discard_state_file "$VPN_RECOVERY_FAILURE_STATE" || return 1
    fi
    reconciled_boot=$("$CAT" "$VPN_BOOT_STATE" 2>/dev/null || true)
    uptime=$(boot_uptime) || return 1
    service_id=$(find_tailscale_service_id)
    if [ -z "$service_id" ]; then
        # Without a service the protocol cannot advance. Record the failure so
        # the launchd trigger is retired instead of respawning every 5 seconds.
        record_vpn_recovery_failure "$current_boot" || return 1
        return 1
    fi
    status=$(vpn_status "$service_id") || return 1
    case "$status" in Connected|Disconnected|Connecting|Disconnecting) ;; *) return 1 ;; esac

    retry_state=$("$CAT" "$VPN_RETRY_STATE" 2>/dev/null || true)
    retry_boot=
    retry_phase=
    retry_attempts=0
    retry_extra=
    if [ -n "$retry_state" ]; then
        IFS='|' read -r retry_boot retry_phase retry_attempts retry_extra <<<"$retry_state"
        retry_attempts=${retry_attempts:-0}
        # A record that exists but names no boot cannot belong to any boot. It
        # would never be validated or cleared, and its mere presence keeps the
        # dormant short-circuit from firing.
        if [ -z "$retry_boot" ]; then
            discard_state_file "$VPN_RETRY_STATE" || return 1
            retry_state=
            retry_phase=
            retry_attempts=0
            retry_extra=
        elif [ "$retry_boot" = "$current_boot" ]; then
            case "$retry_phase" in stopping|starting) ;; *) record_vpn_recovery_failure "$current_boot" || return 1; return 1 ;; esac
            if ! [[ "$retry_attempts" =~ ^[0-9]+$ ]] || [ -n "$retry_extra" ]; then
                record_vpn_recovery_failure "$current_boot" || return 1
                return 1
            fi
        fi
    fi
    retry_action=$(vpn_retry_action "$current_boot" "$retry_boot" "$retry_phase" "$status" "$retry_attempts")
    case "$retry_action" in
        stop)
            retry_attempts=$((retry_attempts + 1))
            persist_retry_state "$current_boot" stopping "$retry_attempts" || return 1
            "$SCUTIL" --nc stop "$service_id" >/dev/null 2>&1 || true
            return 11
            ;;
        start_transition)
            retry_attempts=$((retry_attempts + 1))
            persist_retry_state "$current_boot" starting "$retry_attempts" || return 1
            "$SCUTIL" --nc start "$service_id" >/dev/null 2>&1 || true
            return 11
            ;;
        start)
            retry_attempts=$((retry_attempts + 1))
            persist_retry_state "$current_boot" starting "$retry_attempts" || return 1
            "$SCUTIL" --nc start "$service_id" >/dev/null 2>&1 || true
            return 11
            ;;
        exhausted)
            record_vpn_recovery_failure "$current_boot" || return 1
            return 1
            ;;
        complete)
            printf '%s\n' "$current_boot" >"$VPN_BOOT_STATE.new" || return 1
            "$MV" "$VPN_BOOT_STATE.new" "$VPN_BOOT_STATE" || return 1
            discard_state_file "$VPN_RETRY_STATE" "$VPN_RECOVERY_STATE" "$VPN_RECOVERY_FAILURE_STATE" || return 1
            return 0
            ;;
        clear) discard_state_file "$VPN_RETRY_STATE" || return 1 ;;
    esac
    phase=none
    attempts=0

    state=$("$CAT" "$VPN_RECOVERY_STATE" 2>/dev/null || true)
    if [ -n "$state" ]; then
        local recovery_boot
        recovery_extra=
        IFS='|' read -r recovery_boot phase attempts recovery_extra <<<"$state"
        if [ "$recovery_boot" != "$current_boot" ]; then
            phase=none
            attempts=0
            discard_state_file "$VPN_RECOVERY_STATE" || return 1
        else
            attempts=${attempts:-0}
            case "$phase" in stopping|starting) ;; *) record_vpn_recovery_failure "$current_boot" || return 1; return 1 ;; esac
            if ! [[ "$attempts" =~ ^[0-9]+$ ]] || [ -n "$recovery_extra" ]; then
                record_vpn_recovery_failure "$current_boot" || return 1
                return 1
            fi
        fi
    fi

    if [ "$phase" = none ] && [ "$RESTART_TAILSCALE_AFTER_BOOT" != on ]; then
        return 0
    fi

    if [ "$phase" = none ] && ! needs_boot_reconciliation "$current_boot" "$reconciled_boot" "$status" "$([ -s "$DERP_CACHE" ] && printf 1 || printf 0)" "$uptime"; then
        return 0
    fi

    action=$(vpn_recovery_action "$phase" "$status" "$attempts")
    case "$action" in
        stop)
            attempts=$((attempts + 1))
            persist_recovery_state "$current_boot" stopping "$attempts" || return 1
            "$SCUTIL" --nc stop "$service_id" >/dev/null 2>&1 || return 1
            return 10
            ;;
        start)
            attempts=$((attempts + 1))
            persist_recovery_state "$current_boot" starting "$attempts" || return 1
            "$SCUTIL" --nc start "$service_id" >/dev/null 2>&1 || return 1
            return 10
            ;;
        complete)
            printf '%s\n' "$current_boot" >"$VPN_BOOT_STATE.new" || return 1
            "$MV" "$VPN_BOOT_STATE.new" "$VPN_BOOT_STATE" || return 1
            discard_state_file "$VPN_RECOVERY_STATE" "$VPN_RECOVERY_FAILURE_STATE" || return 1
            "$LOGGER" -t tailnet-keeper 're-established Tailscale after boot' || true
            return 0
            ;;
        terminal_stop)
            # The seeding run issues its own transition, so it counts as the
            # first interval attempt rather than a free one.
            persist_retry_state "$current_boot" stopping 1 || return 1
            discard_state_file "$VPN_RECOVERY_STATE" || return 1
            "$SCUTIL" --nc stop "$service_id" >/dev/null 2>&1 || true
            # Handing the immediate ladder over to the interval retry protocol
            # is an active state, not exhaustion.
            return 11
            ;;
        terminal_start)
            persist_retry_state "$current_boot" starting 1 || return 1
            discard_state_file "$VPN_RECOVERY_STATE" || return 1
            "$SCUTIL" --nc start "$service_id" >/dev/null 2>&1 || true
            return 11
            ;;
        wait)
            attempts=$((attempts + 1))
            persist_recovery_state "$current_boot" "$phase" "$attempts" || return 1
            return 10
            ;;
    esac
}
