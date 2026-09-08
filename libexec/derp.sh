# xmllint exits 10 when an XPath matches nothing, which is a legitimate empty
# result. Any other non-zero status is a real failure and must not be
# collapsed into "this family has no DERP addresses", because callers treat an
# empty candidate set as authority to retire every route of that family.
readonly XMLLINT_EMPTY_XPATH=10

extract_derp_addresses() {
    local xml=$1
    local key=$2
    local destination=$3
    local status=0

    "$XMLLINT" --xpath "//key[text()='$key']/following-sibling::string[1]/text()" "$xml" \
        2>/dev/null >"$destination.raw" || status=$?
    if [ "$status" -ne 0 ] && [ "$status" -ne "$XMLLINT_EMPTY_XPATH" ]; then
        "$RM" -f "$destination.raw"
        return 1
    fi
    "$SORT" -u "$destination.raw" >"$destination" || { "$RM" -f "$destination.raw"; return 1; }
    "$RM" -f "$destination.raw"
}

extract_derp_candidates() {
    local raw=$1
    local ipv4_candidate=$2
    local ipv6_candidate=$3
    local xml="${raw}.xml"

    "$PLUTIL" -convert xml1 -o "$xml" "$raw" >/dev/null 2>&1 || return 1
    if ! extract_derp_addresses "$xml" IPv4 "$ipv4_candidate" ||
       ! extract_derp_addresses "$xml" IPv6 "$ipv6_candidate"; then
        "$RM" -f "$xml"
        return 1
    fi
    "$RM" -f "$xml"

    local count=0 address
    while read -r address; do
        valid_derp_ipv4 "$address" || return 1
        count=$((count + 1))
        [ "$count" -le "$MAX_DERP_ADDRESSES" ] || return 1
    done <"$ipv4_candidate"
    [ "$count" -gt 0 ] || return 1

    count=0
    while read -r address; do
        [ -z "$address" ] && continue
        valid_derp_ipv6 "$address" || return 1
        count=$((count + 1))
        [ "$count" -le "$MAX_DERP_ADDRESSES" ] || return 1
    done <"$ipv6_candidate"
}

# The map is public, and Tailscale's own CLI names this endpoint when its
# local daemon is unreachable. Falling back to it matters because the daemon
# is unreachable in exactly the situation this keeper exists to repair: with
# no bypass in place the CLI cannot serve the map that building the bypass
# depends on. The fetch travels the current default route, so it works while
# the VPN still carries ordinary traffic.
readonly DERP_MAP_URL=https://controlplane.tailscale.com/derpmap/default

fetch_derp_map() {
    local raw=$1

    if validate_tailscale_cli &&
        run_with_timeout 20 "$raw" "$TAILSCALE_CLI" debug derp-map &&
        [ -s "$raw" ]; then
        return 0
    fi
    run_with_timeout 20 "$raw" "$CURL" --fail --silent --show-error --location "$DERP_MAP_URL" &&
        [ -s "$raw" ]
}

build_derp_candidates() {
    local ipv4_candidate=$1
    local ipv6_candidate=$2
    local raw="$DERP_MAP"
    : >"$ipv4_candidate"
    : >"$ipv6_candidate"

    fetch_derp_map "$raw" || return 1
    # The map is JSON. `plutil -lint` parses its input as a property list and
    # rejects JSON outright, so parseability is proven by the conversion in
    # extract_derp_candidates, which fails closed on malformed input.
    extract_derp_candidates "$raw" "$ipv4_candidate" "$ipv6_candidate"
}

address_is_desired() {
    local family=$1
    local address=$2
    local desired=$3
    if [ "$family" = -inet ]; then
        "$GREP" -Fqx "$address" "$desired"
        return
    fi
    # IPv6 has many spellings of one address, so both sides are compared in
    # canonical form. The candidate list is canonicalised once per call rather
    # than once per line: a per-line spawn made this quadratic across a full
    # relay list and dominated the warm reconciliation.
    local canonical
    canonical=$(canonical_ipv6 "$address") || return 1
    canonical_address_stream <"$desired" | "$GREP" -Fqx "$canonical"
}

routes_complete() {
    [ -s "$DERP_CACHE" ] || return 1
    local address
    while read -r address; do
        route_matches -inet "$address" "$physical_ipv4_gateway" "$physical_interface" || return 1
    done <"$DERP_CACHE"

    if [ -n "$physical_ipv6_gateway" ] && [ -s "$DERP_IPV6_CACHE" ]; then
        while read -r address; do
            route_matches -inet6 "$address" "$physical_ipv6_gateway" "$physical_interface" || return 1
        done <"$DERP_IPV6_CACHE"
    fi

    local family _
    while IFS='|' read -r address family _; do
        [ -n "$address" ] || continue
        case "$address" in
            "$CONTROL_IPV4"|"$LOGGING_IPV4"|"$CONTROL_IPV6"|"$LOGGING_IPV6") continue ;;
        esac
        if [ "$family" = -inet ]; then
            address_is_desired -inet "$address" "$DERP_CACHE" || return 1
        elif [ "$family" = -inet6 ] && [ -n "$physical_ipv6_gateway" ]; then
            address_is_desired -inet6 "$address" "$DERP_IPV6_CACHE" || return 1
        else
            return 1
        fi
    done <"$ROUTE_JOURNAL"
}

stage_candidate_routes() {
    local family=$1
    local candidate=$2
    local gateway=$3
    local interface=$4
    local touched=$5
    local address was_owned changed previous previous_gateway=- previous_interface=- previous_policy=- journal_record lookup_status

    while read -r address; do
        [ -n "$address" ] || continue
        was_owned=0
        changed=1
        previous_gateway=-
        previous_interface=-
        previous_policy=-
        if journal_record=$(journal_entry "$address"); then
            was_owned=1
        else
            lookup_status=$?
            [ "$lookup_status" -eq 1 ] || return "$lookup_status"
        fi
        route_matches "$family" "$address" "$gateway" "$interface" && changed=0
        if ! previous=$(capture_specific_route "$family" "$address" "$physical_interface"); then
            return 1
        fi
        if [ -n "$previous" ]; then
            read -r previous_gateway previous_interface previous_policy <<<"$previous"
            previous_policy=${previous_policy:-normal}
        fi
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$address" "$family" "$was_owned" "$changed" "$previous_gateway" "$previous_interface" "$previous_policy" >>"$touched" || return 1
        ensure_owned_route "$family" "$address" "$gateway" "$interface" "$previous" || return 1
    done <"$candidate"
}

rollback_candidate_routes() {
    local touched=$1
    [ -s "$touched" ] || return 0
    local address family was_owned changed previous_gateway previous_interface previous_policy owned_gateway route_status current
    local status=0

    while IFS='|' read -r address family was_owned changed previous_gateway previous_interface previous_policy; do
        [ "$changed" = 1 ] || continue
        previous_policy=${previous_policy:-normal}
        owned_gateway=$physical_ipv4_gateway
        [ "$family" != -inet6 ] || owned_gateway=$physical_ipv6_gateway
        route_status=0
        if route_matches "$family" "$address" "$owned_gateway" "$physical_interface"; then
            route_delete "$family" "$address" "$physical_interface" || route_status=1
            if [ "$previous_gateway" != - ]; then
                if [ "$route_status" -eq 0 ]; then
                    route_add "$family" "$address" "$previous_gateway" "$previous_interface" "$previous_policy" || route_status=1
                fi
                if [ "$route_status" -eq 0 ]; then
                    route_matches "$family" "$address" "$previous_gateway" "$previous_interface" "$previous_policy" || route_status=1
                fi
            fi
        elif [ "$previous_gateway" != - ] && route_matches "$family" "$address" "$previous_gateway" "$previous_interface" "$previous_policy"; then
            route_status=0
        elif [ "$previous_gateway" = - ]; then
            if current=$(capture_specific_route "$family" "$address" "$physical_interface"); then
                [ -z "$current" ] || route_status=1
            else
                route_status=1
            fi
        else
            route_status=1
        fi
        [ "$route_status" -eq 0 ] || status=1
    done <"$touched"
    return "$status"
}

replace_derp_table() {
    local table=$1
    local source=$2
    "$PFCTL" -a "$ANCHOR" -t "$table" -T replace -f "$source" >/dev/null 2>&1
}

snapshot_derp_table() {
    local table=$1
    local destination=$2
    "$PFCTL" -a "$ANCHOR" -t "$table" -T show 2>/dev/null |
        "$AWK" '{$1=$1; print}' | "$SORT" -u >"$destination"
}

commit_derp_state() {
    local ipv4_candidate=$1
    local ipv6_candidate=$2
    "$MV" "$ipv4_candidate" "$DERP_CACHE" || return 1
    "$MV" "$ipv6_candidate" "$DERP_IPV6_CACHE" || return 1
    printf '%s %s %s\n' "$physical_ipv4_gateway" "$physical_ipv6_gateway" "$physical_interface" >"$GATEWAY_STATE.new" || return 1
    "$MV" "$GATEWAY_STATE.new" "$GATEWAY_STATE"
}

restore_cache() {
    local snapshot=$1
    local target=$2
    local existed=$3
    if [ "$existed" -eq 1 ]; then
        restore_file_atomically "$snapshot" "$target"
    else
        "$RM" -f "$target"
    fi
}

restore_file_atomically() {
    local source=$1
    local target=$2
    local temporary="$target.restore"
    "$RM" -f "$temporary" || return 1
    if ! "$CP" "$source" "$temporary"; then
        "$RM" -f "$temporary"
        return 1
    fi
    "$MV" "$temporary" "$target" || return 1
    /usr/bin/cmp -s "$source" "$target"
}

restore_derp_state() {
    local old_ipv4_cache=$1
    local old_ipv6_cache=$2
    local old_journal=$3
    local had_ipv4_cache=$4
    local had_ipv6_cache=$5
    local restore_journal=${6:-1}

    local status=0
    restore_cache "$old_ipv4_cache" "$DERP_CACHE" "$had_ipv4_cache" || status=1
    restore_cache "$old_ipv6_cache" "$DERP_IPV6_CACHE" "$had_ipv6_cache" || status=1
    if [ "$restore_journal" -eq 1 ]; then
        restore_file_atomically "$old_journal" "$ROUTE_JOURNAL" || status=1
    fi
    return "$status"
}

restore_derp_transaction() {
    local touched=$1
    local old_ipv4_table=$2
    local old_ipv6_table=$3
    local old_ipv4_cache=$4
    local old_ipv6_cache=$5
    local old_journal=$6
    local had_ipv4_cache=$7
    local had_ipv6_cache=$8

    local status=0 restore_journal=1
    if ! rollback_candidate_routes "$touched"; then
        status=1
        restore_journal=0
    fi
    replace_derp_table tailscale_derp "$old_ipv4_table" || status=1
    replace_derp_table tailscale_derp6 "$old_ipv6_table" || status=1
    restore_derp_state "$old_ipv4_cache" "$old_ipv6_cache" "$old_journal" "$had_ipv4_cache" "$had_ipv6_cache" "$restore_journal" || status=1
    return "$status"
}

retire_unwanted_owned_routes() {
    local desired_ipv4=$1
    local desired_ipv6=$2
    local snapshot="$RUNTIME_DIR/retirement-journal"
    local status=0 destination family _
    "$CP" "$ROUTE_JOURNAL" "$snapshot" || return 1
    while IFS='|' read -r destination family _; do
        [ -n "$destination" ] || continue
        case "$destination" in
            "$CONTROL_IPV4"|"$LOGGING_IPV4"|"$CONTROL_IPV6"|"$LOGGING_IPV6") continue ;;
        esac
        if { [ "$family" = -inet ] && address_is_desired -inet "$destination" "$desired_ipv4"; } ||
           { [ "$family" = -inet6 ] && address_is_desired -inet6 "$destination" "$desired_ipv6"; }; then
            continue
        fi
        retire_owned_route "$destination" || status=1
    done <"$snapshot"
    "$RM" -f "$snapshot"
    return "$status"
}

refresh_derp_routes() {
    local ipv4_candidate="$STATE_DIR/derp-ipv4.candidate"
    local ipv6_candidate="$STATE_DIR/derp-ipv6.candidate"
    local touched="$RUNTIME_DIR/derp-touched"
    local old_ipv4_cache="$RUNTIME_DIR/derp-ipv4-old"
    local old_ipv6_cache="$RUNTIME_DIR/derp-ipv6-old"
    local old_ipv4_table="$RUNTIME_DIR/derp-ipv4-table-old"
    local old_ipv6_table="$RUNTIME_DIR/derp-ipv6-table-old"
    local old_journal="$RUNTIME_DIR/routes-old"
    local had_ipv4_cache=0 had_ipv6_cache=0 route_failed=0 retirement_failed=0
    local cleanup_files=(
        "$ipv4_candidate" "$ipv6_candidate" "$touched" "$old_ipv4_cache"
        "$old_ipv6_cache" "$old_ipv4_table" "$old_ipv6_table" "$old_journal"
        "$GATEWAY_STATE.new"
    )

    : >"$touched" || return 1
    : >"$old_ipv4_cache" || { "$RM" -f "${cleanup_files[@]}"; return 1; }
    : >"$old_ipv6_cache" || { "$RM" -f "${cleanup_files[@]}"; return 1; }
    if [ -f "$DERP_CACHE" ]; then
        "$CP" "$DERP_CACHE" "$old_ipv4_cache" || { "$RM" -f "${cleanup_files[@]}"; return 1; }
        had_ipv4_cache=1
    fi
    if [ -f "$DERP_IPV6_CACHE" ]; then
        "$CP" "$DERP_IPV6_CACHE" "$old_ipv6_cache" || { "$RM" -f "${cleanup_files[@]}"; return 1; }
        had_ipv6_cache=1
    fi
    "$CP" "$ROUTE_JOURNAL" "$old_journal" || { "$RM" -f "${cleanup_files[@]}"; return 1; }
    snapshot_derp_table tailscale_derp "$old_ipv4_table" || { "$RM" -f "${cleanup_files[@]}"; return 1; }
    snapshot_derp_table tailscale_derp6 "$old_ipv6_table" || { "$RM" -f "${cleanup_files[@]}"; return 1; }
    build_derp_candidates "$ipv4_candidate" "$ipv6_candidate" || { "$RM" -f "${cleanup_files[@]}"; return 1; }

    stage_candidate_routes -inet "$ipv4_candidate" "$physical_ipv4_gateway" "$physical_interface" "$touched" || route_failed=1
    if [ "$route_failed" -eq 0 ] && [ -n "$physical_ipv6_gateway" ]; then
        stage_candidate_routes -inet6 "$ipv6_candidate" "$physical_ipv6_gateway" "$physical_interface" "$touched" || route_failed=1
    fi
    if [ "$route_failed" -eq 1 ]; then
        if ! restore_derp_transaction "$touched" "$old_ipv4_table" "$old_ipv6_table" "$old_ipv4_cache" "$old_ipv6_cache" "$old_journal" "$had_ipv4_cache" "$had_ipv6_cache"; then
            return 2
        fi
        "$RM" -f "${cleanup_files[@]}"
        return 1
    fi

    if ! replace_derp_table tailscale_derp "$ipv4_candidate" ||
       ! replace_derp_table tailscale_derp6 "$ipv6_candidate" ||
       ! commit_derp_state "$ipv4_candidate" "$ipv6_candidate"; then
        if ! restore_derp_transaction "$touched" "$old_ipv4_table" "$old_ipv6_table" "$old_ipv4_cache" "$old_ipv6_cache" "$old_journal" "$had_ipv4_cache" "$had_ipv6_cache"; then
            return 2
        fi
        "$RM" -f "${cleanup_files[@]}"
        return 1
    fi

    if [ -n "$physical_ipv6_gateway" ]; then
        retire_unwanted_owned_routes "$DERP_CACHE" "$DERP_IPV6_CACHE" || retirement_failed=1
    else
        : >"$RUNTIME_DIR/no-ipv6-routes" || retirement_failed=1
        if [ "$retirement_failed" -eq 0 ]; then
            retire_unwanted_owned_routes "$DERP_CACHE" "$RUNTIME_DIR/no-ipv6-routes" || retirement_failed=1
        fi
    fi
    "$RM" -f "${cleanup_files[@]}" "$RUNTIME_DIR/no-ipv6-routes"
    [ "$retirement_failed" -eq 0 ]
}
