render_rules() {
    local interface=$1
    local tailnet_interface=$2
    local source_rules=$3

    # The table files live under the configured state directory. Hardcoding
    # the default path in the template made the rules unloadable whenever that
    # directory moved, which is every test run and every DESTDIR install.
    "$SED" -e "s/__PHYSICAL_INTERFACE__/${interface}/g" \
        -e "s|__DERP_IPV4_CACHE__|${DERP_CACHE}|g" \
        -e "s|__DERP_IPV6_CACHE__|${DERP_IPV6_CACHE}|g" "$source_rules" |
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
    retire_orphaned_relay_routes || status=1
    return "$status"
}

# Removes cached relay routes the journal no longer lists. An interrupted
# transaction can rewrite the journal before the kernel, or roll a route back
# without knowing its scope, and the route survives with no owner. It is
# recognisable: a static host route to a cached relay address through the
# uplink gateway. Nothing else places those. The uplink is read from the
# table when deactivation runs before the main reconciliation discovered it.
retire_orphaned_relay_routes() {
    local gateway4=${physical_ipv4_gateway:-} gateway6=${physical_ipv6_gateway:-} interface=${physical_interface:-}
    local route
    if [ -z "$gateway4" ]; then
        route=$("$NETSTAT" -rn -f inet 2>/dev/null | find_physical_ipv4_route) || return 0
        gateway4=${route%% *}
        interface=${route##* }
    fi
    if [ -z "$gateway6" ]; then
        route=$("$NETSTAT" -rn -f inet6 2>/dev/null | find_physical_ipv6_route) || route=
        [ "${route##* }" != "$interface" ] || gateway6=${route%% *}
    fi

    local status=0
    retire_orphaned_relay_family -inet "$DERP_CACHE" "$gateway4" "$interface" || status=1
    [ -z "$gateway6" ] || retire_orphaned_relay_family -inet6 "$DERP_IPV6_CACHE" "$gateway6" "$interface" || status=1
    return "$status"
}

retire_orphaned_relay_family() {
    local family=$1
    local cache=$2
    local gateway=$3
    local interface=$4
    [ -s "$cache" ] && [ -n "$gateway" ] || return 0
    local table_family=inet
    [ "$family" = -inet6 ] && table_family=inet6

    local status=0 address
    while read -r address; do
        [ -n "$address" ] || continue
        route_delete "$family" "$address" || status=1
    done < <(
        "$NETSTAT" -rn -f "$table_family" 2>/dev/null |
            "$AWK" -v gateway="$gateway" -v interface="$interface" '
                $2 == gateway && $4 == interface && $3 ~ /H/ && $3 ~ /S/ { print $1 }
            ' |
            canonical_address_stream_keyed | "$SORT" -k1,1 -u |
            "$JOIN" - <(canonical_address_stream <"$cache" | "$SORT" -u) |
            "$AWK" '{ print $2 }'
    )
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
# PF prints IPv6 in its own canonical spelling, so a table read back from the
# kernel can never be compared to the cache byte for byte. Both sides pass
# through the same canonical form, as route identity already does.
canonical_address_set() {
    canonical_address_stream | "$SORT" -u
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

    expected_table6=$(canonical_address_set <"$DERP_IPV6_CACHE")
    loaded_table6=$("$PFCTL" -a "$ANCHOR" -t tailscale_derp6 -T show 2>/dev/null |
        "$AWK" '{$1=$1; print}' | canonical_address_set)
    [ "$loaded_table6" = "$expected_table6" ]
}
