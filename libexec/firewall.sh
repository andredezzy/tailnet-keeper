render_rules() {
    local interface=$1
    local tailnet_interface=$2
    local source_rules=$3

    "$SED" "s/__PHYSICAL_INTERFACE__/${interface}/g" "$source_rules" |
        if [ -n "$tailnet_interface" ]; then
            "$SED" "s/__TAILSCALE_INTERFACE__/${tailnet_interface}/g"
        else
            "$GREP" -v '__TAILSCALE_INTERFACE__'
        fi
}

rules_without_tables() {
    "$AWK" '$1 != "table"'
}

pf_enabled() {
    "$PFCTL" -s info 2>/dev/null | "$AWK" '$1 == "Status:" { exit !($2 == "Enabled") }'
}
clear_anchor() {
    "$PFCTL" -a "$ANCHOR" -F all >/dev/null 2>&1
}
fail_closed() {
    local status=0 replacement_complete=1 entries
    local remaining="$ROUTE_JOURNAL.cleanup"

    clear_anchor || status=1
    : >"$remaining" || return 1
    if [ -s "$ROUTE_JOURNAL" ]; then
        # Read the journal up front. A failed read must not look like an empty
        # journal, or the replacement below would erase every ownership record
        # without attempting a single restore.
        if ! entries=$("$CAT" "$ROUTE_JOURNAL" 2>/dev/null); then
            "$RM" -f "$remaining"
            return 1
        fi
        while IFS='|' read -r destination family owned_gateway owned_interface prior_gateway prior_interface prior_policy; do
            [ -n "$destination" ] || continue
            prior_policy=${prior_policy:-normal}
            if ! restore_journaled_route "$destination" "$family" "$owned_gateway" "$owned_interface" "$prior_gateway" "$prior_interface" "$prior_policy"; then
                printf '%s|%s|%s|%s|%s|%s|%s\n' "$destination" "$family" "$owned_gateway" "$owned_interface" "$prior_gateway" "$prior_interface" "$prior_policy" >>"$remaining" || replacement_complete=0
                status=1
            fi
        done <<<"$entries"
    fi
    if [ "$replacement_complete" -eq 0 ]; then
        "$RM" -f "$remaining"
        return 1
    fi
    "$MV" "$remaining" "$ROUTE_JOURNAL" || return 1
    return "$status"
}

fail_safely() {
    local detail=$1
    if fail_closed; then
        log_error "$detail"
    else
        log_error "${detail}_cleanup_failed"
    fi
}

find_tailscale_interface() {
    local candidate
    for candidate in $("$IFCONFIG" -l | /usr/bin/tr ' ' '\n' | "$GREP" '^utun'); do
        if "$IFCONFIG" "$candidate" 2>/dev/null |
           "$GREP" -qE 'inet 100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}
load_anchor() {
    local interface=$1
    local tailnet_interface=$2
    local temporary="$RUNTIME_RULES.new"
    render_rules "$interface" "$tailnet_interface" "$SOURCE_RULES" >"$temporary" || return 1
    ! "$GREP" -q '__[A-Z_]*__' "$temporary" || return 1
    "$PFCTL" -nvf "$temporary" >/dev/null 2>&1 || return 1
    "$MV" "$temporary" "$RUNTIME_RULES" || return 1
    "$PFCTL" -a "$ANCHOR" -f "$RUNTIME_RULES" >/dev/null 2>&1 || return 1

    local expected loaded expected_table loaded_table expected_table6 loaded_table6
    expected=$("$PFCTL" -nvf "$RUNTIME_RULES" 2>/dev/null | rules_without_tables)
    loaded=$("$PFCTL" -a "$ANCHOR" -sr 2>/dev/null)
    [ -n "$expected" ] && [ "$loaded" = "$expected" ] || return 1

    expected_table=$("$SORT" -u "$DERP_CACHE")
    loaded_table=$("$PFCTL" -a "$ANCHOR" -t tailscale_derp -T show 2>/dev/null |
        "$AWK" '{$1=$1; print}' | "$SORT" -u)
    [ "$loaded_table" = "$expected_table" ] || return 1

    expected_table6=$("$SORT" -u "$DERP_IPV6_CACHE")
    loaded_table6=$("$PFCTL" -a "$ANCHOR" -t tailscale_derp6 -T show 2>/dev/null |
        "$AWK" '{$1=$1; print}' | "$SORT" -u)
    [ "$loaded_table6" = "$expected_table6" ]
}
