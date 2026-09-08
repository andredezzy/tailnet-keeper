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

# Writes the relay list to route: the current map when it can be fetched,
# otherwise the last cached list. Returns 0 from the map, 3 from the cache,
# 1 with neither.
#
# The cache is a valid source on its own. After a reboot on another network
# the gateway has changed, so every relay needs a new route, and the map
# fetch needs the control plane -- which the routes being placed are what
# reach. Refusing to route without a fresh map locks Tailscale out until a
# fetch succeeds, and the lockout is what stops it succeeding.
build_derp_candidates() {
    local ipv4_candidate=$1
    local ipv6_candidate=$2
    local raw="$DERP_MAP"
    : >"$ipv4_candidate"
    : >"$ipv6_candidate"

    # The map is JSON. `plutil -lint` parses its input as a property list and
    # rejects JSON outright, so parseability is proven by the conversion in
    # extract_derp_candidates, which fails closed on malformed input.
    if fetch_derp_map "$raw" &&
        extract_derp_candidates "$raw" "$ipv4_candidate" "$ipv6_candidate"; then
        return 0
    fi
    [ -s "$DERP_CACHE" ] || return 1
    "$CP" "$DERP_CACHE" "$ipv4_candidate" || return 1
    if [ -s "$DERP_IPV6_CACHE" ]; then
        "$CP" "$DERP_IPV6_CACHE" "$ipv6_candidate" || return 1
    fi
    return 3
}

# Answers whether every desired relay has its bypass route in place and the
# journal owns nothing it should not. It runs every five minutes over the
# full relay list, so it reads the routing table once per family instead of
# asking the kernel one route at a time.
#
# A placed bypass is a host route (H) through the uplink gateway that is
# static (S) and not interface-scoped (I): a plain socket never consults a
# scoped route. A neighbour entry the kernel clones on its own is a host
# route too, but it is not static and not ours.
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

# True when every address in the desired list has a static, unscoped host
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
                $2 == gateway && $4 == interface && $3 ~ /H/ && $3 ~ /S/ && $3 !~ /I/ { print $1 }
            ' |
            canonical_address_stream | "$SORT" -u |
            "$COMM" -13 - <(canonical_address_stream <"$desired" | "$SORT" -u)
    )
    [ -z "$missing" ]
}

# Prints one line per candidate from one read of the journal and one read
# of the table:
#
#     address owned present prior_gateway prior_interface prior_policy
#
# `owned` is 1 when the journal already lists the host, `present` is 1 when
# the table holds the bypass route the keeper would place. When it does not,
# the prior fields describe the static host route the table holds instead
# (`-` when none), which is what rollback must put back. Ownership, presence
# and the prior are set questions over the whole list; asking the kernel per
# candidate reads the same table once per relay.
classify_candidates() {
    local family=$1
    local candidate=$2
    local gateway=$3
    local interface=$4
    local table_family=inet
    [ "$family" = -inet6 ] && table_family=inet6
    gateway=$(normalize_gateway "$gateway" "$interface")
    local owned="$RUNTIME_DIR/classify-owned" hosts="$RUNTIME_DIR/classify-hosts"

    # Bash 3.2 cannot nest process substitutions reliably, so the two
    # right-hand sets are materialised first.
    "$AWK" -F'|' '$1 != "" { print $1 }' "$ROUTE_JOURNAL" 2>/dev/null |
        canonical_address_stream | "$AWK" '{ print $1, 1 }' | "$SORT" -k1,1 -u >"$owned" || return 1
    # Every static, unscoped host route on any interface: `key present
    # gateway interface policy`. The bypass route is present=1; anything
    # else is a prior route to record.
    "$NETSTAT" -rn -f "$table_family" 2>/dev/null |
        "$AWK" -v gateway="$gateway" -v interface="$interface" -v prefix="$INTERFACE_GATEWAY_PREFIX" '
            $3 ~ /H/ && $3 ~ /S/ && $3 !~ /I/ {
                dest = $1; sub(/\/[0-9]+$/, "", dest)
                actual = $2
                if (actual ~ /^link#/ || actual == $4) actual = prefix $4
                policy = "normal"
                if ($3 ~ /R/) policy = "reject"
                if ($3 ~ /B/) policy = policy == "normal" ? "blackhole" : policy "+blackhole"
                present = (actual == gateway && $4 == interface && policy == "normal") ? 1 : 0
                print dest, present, actual, $4, policy
            }
        ' | canonical_address_stream_keyed |
        "$AWK" '{ print $1, $3, $4, $5, $6 }' | "$SORT" -k1,1 -u >"$hosts" || return 1

    canonical_address_stream_keyed <"$candidate" | "$SORT" -k1,1 -u |
        "$JOIN" -a1 -e 0 -o '0,1.2,2.2' - "$owned" |
        "$JOIN" -a1 -e - -o '1.2,1.3,2.2,2.3,2.4,2.5' - "$hosts" |
        "$AWK" '
            $3 == "-" { $3 = 0 }
            $3 == 1 { $4 = "-"; $5 = "-"; $6 = "-" }
            { print }
        '
    local status=$?
    "$RM" -f "$owned" "$hosts"
    return "$status"
}

# Places every candidate's bypass route and records what it displaced, so a
# failure later in the transaction can put each one back. Which candidates
# are already correct, and what the others have instead, is decided from one
# table read for the whole list; the correct ones are recorded unchanged
# without touching the kernel, since rollback skips unchanged records.
#
# A missing route is placed with the minimum of process spawns: no lookup,
# a delete only when the table showed something to delete, one add, and one
# journal write for the whole batch. The verifying read after the adds
# stays: it is the proof the routes landed.
stage_candidate_routes() {
    local family=$1
    local candidate=$2
    local gateway=$3
    local interface=$4
    local touched=$5
    local address was_owned present prior_gateway prior_interface prior_policy
    local journal_batch="$RUNTIME_DIR/journal-batch" classified="$RUNTIME_DIR/stage-classified"
    local placed="$RUNTIME_DIR/stage-placed"
    local owned_gateway
    owned_gateway=$(normalize_gateway "$gateway" "$interface")
    : >"$journal_batch" || return 1
    : >"$placed" || return 1
    classify_candidates "$family" "$candidate" "$gateway" "$interface" >"$classified" || { "$RM" -f "$journal_batch" "$classified" "$placed"; return 1; }

    while read -r address was_owned present prior_gateway prior_interface prior_policy; do
        [ -n "$address" ] || continue
        if [ "$present" = 1 ]; then
            printf '%s|%s|%s|0|-|-|-\n' "$address" "$family" "$was_owned" >>"$touched" || return 1
            continue
        fi
        printf '%s|%s|%s|1|%s|%s|%s\n' "$address" "$family" "$was_owned" "$prior_gateway" "$prior_interface" "$prior_policy" >>"$touched" || { "$RM" -f "$journal_batch" "$classified" "$placed"; return 1; }
        # The journal entry is written before the kernel is touched, so a
        # crash between the two leaves a route the journal owns, never an
        # orphan. The batch is flushed before the first add below.
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$address" "$family" "$owned_gateway" "$interface" "$prior_gateway" "$prior_interface" "$prior_policy" >>"$journal_batch" || { "$RM" -f "$journal_batch" "$classified" "$placed"; return 1; }
        printf '%s %s\n' "$address" "$prior_gateway" >>"$placed" || { "$RM" -f "$journal_batch" "$classified" "$placed"; return 1; }
    done <"$classified"
    "$RM" -f "$classified"

    if [ ! -s "$journal_batch" ]; then
        "$RM" -f "$journal_batch" "$placed"
        return 0
    fi
    journal_add_batch "$journal_batch" || { "$RM" -f "$journal_batch" "$placed"; return 1; }
    "$RM" -f "$journal_batch"

    while read -r address prior_gateway; do
        [ "$prior_gateway" = - ] || route_delete "$family" "$address" || { "$RM" -f "$placed"; return 1; }
        route_add "$family" "$address" "$gateway" "$interface" || { "$RM" -f "$placed"; return 1; }
    done <"$placed"
    # One table read proves the whole batch landed.
    "$AWK" '{ print $1 }' "$placed" >"$placed.addresses" || { "$RM" -f "$placed"; return 1; }
    placed_routes_cover "$family" "$placed.addresses" "$gateway" "$interface"
    local status=$?
    "$RM" -f "$placed" "$placed.addresses"
    return "$status"
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
            route_delete "$family" "$address" || route_status=1
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
            if current=$(capture_specific_route "$family" "$address"); then
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

# Records what was routed. A list that came from the map replaces the cache;
# one that came from the cache leaves it untouched, so its age still says
# when the map was last seen and the next run tries the map again.
commit_derp_state() {
    local ipv4_candidate=$1
    local ipv6_candidate=$2
    local source=${3:-0}
    if [ "$source" -eq 0 ]; then
        "$MV" "$ipv4_candidate" "$DERP_CACHE" || return 1
        "$MV" "$ipv6_candidate" "$DERP_IPV6_CACHE" || return 1
    fi
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
    local source=0
    build_derp_candidates "$ipv4_candidate" "$ipv6_candidate" || source=$?
    [ "$source" -eq 0 ] || [ "$source" -eq 3 ] || { "$RM" -f "${cleanup_files[@]}"; return 1; }

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
       ! commit_derp_state "$ipv4_candidate" "$ipv6_candidate" "$source"; then
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
    [ "$retirement_failed" -eq 0 ] || return 1
    # Routes placed from the cache are in place and rolled forward; the
    # caller still reports the refresh as failed so health says why.
    [ "$source" -eq 0 ]
}
