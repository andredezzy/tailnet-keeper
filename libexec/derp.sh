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

# Answers whether every desired relay has its bypass route in place and the
# journal owns nothing it should not. It runs every five minutes over the
# full relay list, so it reads the routing table once per family instead of
# asking the kernel one route at a time.
#
# A placed bypass is a host route (H) through the uplink gateway that is
# static (S) and interface-scoped (I). A neighbour entry the kernel clones
# on its own is a host route too, but it is neither static nor ours.
routes_complete() {
    [ -s "$DERP_CACHE" ] || return 1
    placed_routes_cover -inet "$DERP_CACHE" "$physical_ipv4_gateway" "$physical_interface" || return 1
    if [ -n "$physical_ipv6_gateway" ] && [ -s "$DERP_IPV6_CACHE" ]; then
        placed_routes_cover -inet6 "$DERP_IPV6_CACHE" "$physical_ipv6_gateway" "$physical_interface" || return 1
    fi
    journal_owns_only_desired
}

# Prints, in the journal's own spelling, every relay the journal owns that is
# not on the given desired lists. The infrastructure prefixes are always owned
# and never printed. Both sides are compared canonically in one pass; the
# journal keys IPv6 expanded and the relay map spells it compressed.
journaled_relays_not_in() {
    local desired_ipv4=$1
    local desired_ipv6=$2
    "$AWK" -F'|' -v control4="$CONTROL_IPV4" -v logging4="$LOGGING_IPV4" \
        -v control6="$CONTROL_IPV6" -v logging6="$LOGGING_IPV6" '
        $1 != "" && $1 != control4 && $1 != logging4 && $1 != control6 && $1 != logging6 { print $1 }
    ' "$ROUTE_JOURNAL" |
        canonical_address_stream_keyed | "$SORT" -k1,1 -u |
        "$JOIN" -v1 - <("$CAT" "$desired_ipv4" "$desired_ipv6" | canonical_address_stream | "$SORT" -u) |
        "$AWK" '{ print $2 }'
}

# True when every relay the journal owns is still desired. An IPv6 entry
# without an IPv6 gateway is stale, so the desired IPv6 list is empty then.
journal_owns_only_desired() {
    local desired_ipv6=/dev/null
    [ -z "$physical_ipv6_gateway" ] || desired_ipv6=$DERP_IPV6_CACHE
    [ -z "$(journaled_relays_not_in "$DERP_CACHE" "$desired_ipv6")" ]
}

# True when every address in the desired list has a static, scoped host
# route through the given gateway and interface in one family's table.
placed_routes_cover() {
    local family=$1
    local desired=$2
    local gateway=$3
    local interface=$4
    local table_family=inet
    [ "$family" = -inet6 ] && table_family=inet6

    # comm -13 prints what the desired list has and the table lacks; an
    # empty result is the only complete one.
    local missing
    missing=$(
        "$NETSTAT" -rn -f "$table_family" 2>/dev/null |
            "$AWK" -v gateway="$gateway" -v interface="$interface" '
                $2 == gateway && $4 == interface && $3 ~ /H/ && $3 ~ /S/ && $3 ~ /I/ { print $1 }
            ' |
            canonical_address_stream | "$SORT" -u |
            "$COMM" -13 - <(canonical_address_stream <"$desired" | "$SORT" -u)
    )
    [ -z "$missing" ]
}

# Places every candidate's bypass route and records what it displaced, so a
# failure later in the transaction can put each one back. A route that is
# already correct is proven with one lookup and recorded unchanged: rollback
# skips unchanged records, so nothing more about it is ever read.
stage_candidate_routes() {
    local family=$1
    local candidate=$2
    local gateway=$3
    local interface=$4
    local touched=$5
    local address was_owned previous previous_gateway previous_interface previous_policy lookup_status

    while read -r address; do
        [ -n "$address" ] || continue
        if journal_entry "$address" >/dev/null; then
            was_owned=1
        else
            lookup_status=$?
            [ "$lookup_status" -eq 1 ] || return "$lookup_status"
            was_owned=0
        fi
        if route_matches "$family" "$address" "$gateway" "$interface"; then
            printf '%s|%s|%s|0|-|-|-\n' "$address" "$family" "$was_owned" >>"$touched" || return 1
            continue
        fi
        previous=$(capture_specific_route "$family" "$address" "$physical_interface") || return 1
        previous_gateway=- previous_interface=- previous_policy=-
        if [ -n "$previous" ]; then
            read -r previous_gateway previous_interface previous_policy <<<"$previous"
            previous_policy=${previous_policy:-normal}
        fi
        printf '%s|%s|%s|1|%s|%s|%s\n' "$address" "$family" "$was_owned" "$previous_gateway" "$previous_interface" "$previous_policy" >>"$touched" || return 1
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
    local status=0 destination
    # The journal changes under each retirement, so the stray set is fixed
    # once before the loop starts.
    journaled_relays_not_in "$desired_ipv4" "$desired_ipv6" >"$snapshot" || { "$RM" -f "$snapshot"; return 1; }
    while read -r destination; do
        [ -n "$destination" ] || continue
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
