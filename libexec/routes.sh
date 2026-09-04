# Which interfaces are real uplinks is a question macOS already answers.
# `networksetup -listnetworkserviceorder` lists exactly the configured network
# services, in the priority the OS itself uses, so it serves as both allowlist
# and tiebreak. Guessing by name instead was wrong twice on this host: it
# rejected `bridge0` (Thunderbolt Bridge, a real uplink ranked above Wi-Fi) and
# it relied on routing-table order, which varies with the order daemons happen
# to start. A virtual interface such as an OrbStack bridge is absent from this
# list, and a VPN service is listed with an empty device, so neither can win.
ranked_network_devices() {
    "$NETWORKSETUP" -listnetworkserviceorder 2>/dev/null |
        "$AWK" -F'Device: ' '/Device: /{ device=$2; sub(/\).*$/, "", device); if (device != "") print device }'
}

# Prints the first default route whose interface is a configured network
# service, honouring the OS service order rather than routing-table order.
select_ranked_default_route() {
    local table=$1 pattern=$2 device found
    while read -r device; do
        found=$(printf '%s\n' "$table" |
            "$AWK" -v want="$device" -v pattern="$pattern" \
                '$1 == "default" && $2 ~ pattern && $3 ~ /U/ && $3 !~ /[RB]/ && $4 == want { print $2, $4; exit }')
        [ -z "$found" ] || { printf '%s\n' "$found"; return 0; }
    done < <(ranked_network_devices)
    return 1
}

find_physical_ipv4_route() {
    select_ranked_default_route "$("$CAT")" '^[0-9]+\.'
}
find_physical_ipv6_route() {
    select_ranked_default_route "$("$CAT")" '^fe80:'
}
# The journal keys IPv6 hosts in expanded form, but the kernel always echoes
# the compressed spelling, so identity must be compared canonically on both
# sides or a route can never be matched, restored, or withdrawn.
destinations_equal() {
    local wanted=$1 actual=$2 canonical_wanted canonical_actual
    [ -n "$actual" ] || return 1
    # netstat renders some host routes with an explicit full-width mask, so
    # strip it before comparing against a bare host.
    case "$actual" in
        */32) [[ "$wanted" != */* ]] && actual=${actual%/32} ;;
        */128) [[ "$wanted" != */* ]] && actual=${actual%/128} ;;
    esac
    if [[ "$wanted" == *:* ]] && [[ "$actual" == *:* ]] &&
       [[ "$wanted" != */* ]] && [[ "$actual" != */* ]]; then
        canonical_wanted=$(canonical_ipv6 "${wanted%%\%*}") || return 1
        canonical_actual=$(canonical_ipv6 "${actual%%\%*}") || return 1
        [ "$canonical_wanted" = "$canonical_actual" ]
        return
    fi
    [ "$(printf '%s' "$wanted" | "$AWK" '{ print tolower($0) }')" = \
      "$(printf '%s' "$actual" | "$AWK" '{ print tolower($0) }')" ]
}

# A route is either reached through a gateway address or scoped directly to an
# interface. The kernel spells the latter three ways -- `link#N`, a bare
# interface name, or `index: N ifname` -- and an interface route prints no
# gateway line at all. All of them mean the same thing, so they are normalised
# to one token that route_add knows to re-add with `-interface`.
readonly INTERFACE_GATEWAY_PREFIX='interface#'

normalize_gateway() {
    local gateway=$1 interface=$2
    case "$gateway" in
        '') printf '%s%s\n' "$INTERFACE_GATEWAY_PREFIX" "$interface" ;;
        link\#*) printf '%s%s\n' "$INTERFACE_GATEWAY_PREFIX" "$interface" ;;
        "$INTERFACE_GATEWAY_PREFIX"*) printf '%s\n' "$gateway" ;;
        *[0-9a-fA-F]:*|*.*) printf '%s\n' "$gateway" ;;
        *) printf '%s%s\n' "$INTERFACE_GATEWAY_PREFIX" "$interface" ;;
    esac
}

# `route -n get <host>` answers with the default route when no specific route
# exists, so the destination must be compared or the matcher accepts anything.
route_output_matches() {
    local expected_destination=$1
    local expected_gateway=$2
    local expected_interface=$3
    local expected_policy=${4:-normal}
    local output actual_destination actual_gateway actual_interface

    output=$("$CAT")
    actual_destination=$("$AWK" '$1 == "destination:" { print $2; exit }' <<<"$output")
    destinations_equal "$expected_destination" "$actual_destination" || return 1
    # The kernel prints a point-to-point gateway as `index: N ifname`, so take
    # the last field rather than the first.
    actual_gateway=$("$AWK" '$1 == "gateway:" { print $NF; exit }' <<<"$output")
    actual_interface=$("$AWK" '$1 == "interface:" { print $2; exit }' <<<"$output")
    actual_gateway=$(normalize_gateway "$actual_gateway" "$actual_interface")
    [ "$actual_gateway" = "$(normalize_gateway "$expected_gateway" "$expected_interface")" ] || return 1

    "$AWK" -v interface="$expected_interface" -v expected_policy="$expected_policy" '
        $1 == "interface:" { actual_interface = $2 }
        $1 == "flags:" { flags = $2 }
        END {
            if (flags !~ /(^|[,<])UP([,>]|$)/) exit 1
            policy = ""
            if (flags ~ /(^|[,<])REJECT([,>]|$)/) policy = "reject"
            if (flags ~ /(^|[,<])BLACKHOLE([,>]|$)/) policy = policy == "" ? "blackhole" : policy "+blackhole"
            if (policy == "") policy = "normal"
            exit !(actual_interface == interface && policy == expected_policy)
        }
    ' <<<"$output"
}
network_route_details() {
    local destination=$1
    local expected_destination=${destination%/*}
    local expected_mask details gateway interface policy
    case "$destination" in
        */24) expected_mask=255.255.255.0 ;;
        */48) expected_mask=ffff:ffff:ffff:: ;;
        *) return 1 ;;
    esac

    # An interface-scoped route prints no gateway line, which is a legitimate
    # shape rather than an error, so the gateway is normalised afterwards.
    details=$("$AWK" -v expected_destination="$expected_destination" -v expected_mask="$expected_mask" '
        $1 == "destination:" { destination=tolower($2) }
        $1 == "mask:" { mask=tolower($2) }
        $1 == "gateway:" { gateway=$NF }
        $1 == "interface:" { interface=$2 }
        $1 == "flags:" { flags=$2 }
        END {
            if (destination == "" || interface == "" ||
                flags == "" || flags !~ /(^|[,<])UP([,>]|$)/) exit 2
            if (destination != tolower(expected_destination) || mask != expected_mask) exit 1
            policy = ""
            if (flags ~ /(^|[,<])REJECT([,>]|$)/) policy = "reject"
            if (flags ~ /(^|[,<])BLACKHOLE([,>]|$)/) policy = policy == "" ? "blackhole" : policy "+blackhole"
            if (policy == "") policy = "normal"
            print (gateway == "" ? "-" : gateway), interface, policy
        }
    ') || return "$?"
    read -r gateway interface policy <<<"$details"
    [ "$gateway" != - ] || gateway=
    printf '%s %s %s\n' "$(normalize_gateway "$gateway" "$interface")" "$interface" "$policy"
}
network_route_output_matches() {
    local destination=$1
    local expected_gateway=$2
    local expected_interface=$3
    local expected_policy=${4:-normal}
    local details
    details=$(network_route_details "$destination") || return 1
    [ "$details" = "$(normalize_gateway "$expected_gateway" "$expected_interface") $expected_interface $expected_policy" ]
}
valid_derp_ipv4() {
    local address=$1

    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    "$AWK" -F. '
        NF != 4 { exit 1 }
        {
            for (part = 1; part <= 4; part++) if ($part > 255) exit 1
            if (sprintf("%d.%d.%d.%d", $1, $2, $3, $4) != $0) exit 1
            if ($1 == 0 || $1 == 10 || $1 == 127 || $1 >= 224) exit 1
            if ($1 == 100 && $2 >= 64 && $2 <= 127) exit 1
            if ($1 == 169 && $2 == 254) exit 1
            if ($1 == 172 && $2 >= 16 && $2 <= 31) exit 1
            if ($1 == 192 &&
                ($2 == 168 ||
                 ($2 == 0 && ($3 == 0 || $3 == 2)) ||
                 ($2 == 31 && $3 == 196) ||
                 ($2 == 52 && $3 == 193) ||
                 ($2 == 88 && $3 == 99) ||
                 ($2 == 175 && $3 == 48))) exit 1
            if ($1 == 198 && (($2 == 18 || $2 == 19) || ($2 == 51 && $3 == 100))) exit 1
            if ($1 == 203 && $2 == 0 && $3 == 113) exit 1
        }
    ' <<<"$address"
}

canonical_ipv6() {
    local address=$1
    "$AWK" -v address="$address" '
        function normalize(group) {
            group=tolower(group)
            if (length(group) < 1 || length(group) > 4 || group !~ /^[0-9a-f]+$/) exit 1
            while (length(group) > 1 && substr(group, 1, 1) == "0") group=substr(group, 2)
            return group
        }
        BEGIN {
            address=tolower(address)
            compressed=index(address, "::")
            if (compressed) {
                left=substr(address, 1, compressed - 1)
                right=substr(address, compressed + 2)
                if (index(right, "::")) exit 1
                left_count=left == "" ? 0 : split(left, left_parts, ":")
                right_count=right == "" ? 0 : split(right, right_parts, ":")
                missing=8 - left_count - right_count
                if (missing < 1) exit 1
                for (i=1; i<=left_count; i++) groups[++count]=normalize(left_parts[i])
                for (i=1; i<=missing; i++) groups[++count]="0"
                for (i=1; i<=right_count; i++) groups[++count]=normalize(right_parts[i])
            } else {
                count=split(address, parts, ":")
                if (count != 8) exit 1
                for (i=1; i<=count; i++) groups[i]=normalize(parts[i])
            }
            if (count != 8) exit 1
            output=groups[1]
            for (i=2; i<=8; i++) output=output ":" groups[i]
            print output
        }
    '
}

valid_derp_ipv6() {
    local address=$1 canonical first_group
    [ "${#address}" -le 39 ] || return 1
    [[ "$address" =~ ^[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{0,4})+$ ]] || return 1
    # Gate on the canonical first group, not the leading character: 2::1 and
    # 20::1 start with "2" but sit far outside global unicast 2000::/3.
    canonical=$(canonical_ipv6 "$address") || return 1
    first_group=${canonical%%:*}
    [ "$((16#$first_group))" -ge 8192 ] && [ "$((16#$first_group))" -le 16383 ] || return 1
    [[ "$canonical" != 2001:db8:* ]]
}

route_matches() {
    local family=$1
    local destination=$2
    local gateway=$3
    local interface=$4
    local policy=${5:-normal}

    if [[ "$destination" == */* ]]; then
        "$ROUTE" -n get "$family" -net "$destination" 2>/dev/null |
            network_route_output_matches "$destination" "$gateway" "$interface" "$policy"
    else
        "$ROUTE" -n get "$family" "$destination" 2>/dev/null |
            route_output_matches "$destination" "$gateway" "$interface" "$policy"
    fi
}
route_add_command() {
    local policy=$1
    shift
    case "$policy" in
        normal|-) "$ROUTE" "$@" ;;
        reject) "$ROUTE" "$@" -reject ;;
        blackhole) "$ROUTE" "$@" -blackhole ;;
        reject+blackhole) "$ROUTE" "$@" -reject -blackhole ;;
        *) return 1 ;;
    esac
}
route_add() {
    local family=$1
    local destination=$2
    local gateway=$3
    local interface=${4:-}
    local policy=${5:-normal}

    gateway=$(normalize_gateway "$gateway" "$interface")
    if [[ "$gateway" == "$INTERFACE_GATEWAY_PREFIX"* ]]; then
        # An interface-scoped route is re-added by interface, never by passing
        # the interface name where an address belongs.
        interface=${gateway#"$INTERFACE_GATEWAY_PREFIX"}
        [ -n "$interface" ] || return 1
        if [ "$family" = -inet6 ]; then
            route_add_command "$policy" -q -n add -inet6 "$destination" -interface "$interface" >/dev/null 2>&1
        elif [[ "$destination" == */* ]]; then
            route_add_command "$policy" -q -n add -net "$destination" -interface "$interface" >/dev/null 2>&1
        else
            route_add_command "$policy" -q -n add -host "$destination" -interface "$interface" >/dev/null 2>&1
        fi
    elif [ "$family" = -inet6 ]; then
        route_add_command "$policy" -q -n add -inet6 "$destination" "$gateway" >/dev/null 2>&1
    elif [[ "$destination" == */* ]]; then
        route_add_command "$policy" -q -n add -net "$destination" "$gateway" >/dev/null 2>&1
    else
        route_add_command "$policy" -q -n add -host "$destination" "$gateway" >/dev/null 2>&1
    fi
}
route_delete() {
    local family=$1
    local destination=$2

    if [ "$family" = -inet6 ]; then
        "$ROUTE" -q -n delete -inet6 "$destination" >/dev/null 2>&1
    elif [[ "$destination" == */* ]]; then
        "$ROUTE" -q -n delete -net "$destination" >/dev/null 2>&1
    else
        "$ROUTE" -q -n delete -host "$destination" >/dev/null 2>&1
    fi
}
capture_specific_route() {
    local family=$1
    local destination=$2
    local table_family=inet
    [ "$family" = -inet6 ] && table_family=inet6

    if [[ "$destination" == */* ]]; then
        local details status
        if details=$("$ROUTE" -n get "$family" -net "$destination" 2>/dev/null |
            network_route_details "$destination"); then
            printf '%s\n' "$details"
            return 0
        else
            status=$?
        fi
        [ "$status" -eq 1 ] && return 0
        return "$status"
    else
        local table entry candidate
        table=$("$NETSTAT" -rn -f "$table_family" 2>/dev/null) || return "$?"
        while IFS= read -r entry; do
            candidate=${entry%% *}
            [ -n "$candidate" ] || continue
            destinations_equal "$destination" "$candidate" || continue
            printf '%s\n' "$entry" | "$AWK" '
                {
                    if ($3 !~ /U/) exit 2
                    policy=""
                    if ($3 ~ /R/) policy="reject"
                    if ($3 ~ /B/) policy=policy == "" ? "blackhole" : policy "+blackhole"
                    if (policy == "") policy="normal"
                    print $2, $4, policy
                }
            ' | {
                read -r captured_gateway captured_interface captured_policy || return 1
                printf '%s %s %s\n' \
                    "$(normalize_gateway "$captured_gateway" "$captured_interface")" \
                    "$captured_interface" "$captured_policy"
            }
            return "$?"
        done <<<"$table"
    fi
}
# The journal is keyed by destination, so two spellings of the same IPv6
# address must resolve to one entry. Prefixes and IPv4 destinations already
# have a single spelling and are used verbatim.
journal_key() {
    local destination=$1
    case "$destination" in
        */*|*.*) printf '%s\n' "$destination" ;;
        *:*) canonical_ipv6 "$destination" ;;
        *) printf '%s\n' "$destination" ;;
    esac
}

journal_entry() {
    local destination
    destination=$(journal_key "$1") || return 2
    "$AWK" -F'|' -v destination="$destination" '
        $1 == destination { print; found=1; exit }
        END { if (!found) exit 1 }
    ' "$ROUTE_JOURNAL" 2>/dev/null
}

journal_has() {
    journal_entry "$1" >/dev/null
}

journal_replace_entry() {
    local entry=$1
    local destination
    destination=$(journal_key "${entry%%|*}") || return 1
    local temporary="$ROUTE_JOURNAL.new"
    if ! "$AWK" -F'|' -v destination="$destination" '$1 != destination' "$ROUTE_JOURNAL" 2>/dev/null >"$temporary"; then
        "$RM" -f "$temporary"
        return 1
    fi
    printf '%s\n' "$entry" >>"$temporary" || return 1
    "$MV" "$temporary" "$ROUTE_JOURNAL"
}

journal_add() {
    local destination
    destination=$(journal_key "$1") || return 1
    local family=$2
    local prior=$3
    local temporary="$ROUTE_JOURNAL.new"
    local recorded prior_gateway=- prior_interface=- prior_policy=- owned_gateway=$physical_ipv4_gateway
    [ "$family" != -inet6 ] || owned_gateway=$physical_ipv6_gateway
    if [ "$prior" != - ] && [ -n "$prior" ]; then
        read -r prior_gateway prior_interface prior_policy <<<"$prior"
        prior_policy=${prior_policy:-normal}
    fi

    recorded=$("$AWK" -F'|' -v destination="$destination" '$1 == destination { print $5 "|" $6 "|" $7; exit }' "$ROUTE_JOURNAL" 2>/dev/null || true)
    if [ -n "$recorded" ]; then
        IFS='|' read -r prior_gateway prior_interface prior_policy <<<"$recorded"
        prior_policy=${prior_policy:-normal}
    fi
    if ! "$AWK" -F'|' -v destination="$destination" '$1 != destination' "$ROUTE_JOURNAL" 2>/dev/null >"$temporary"; then
        "$RM" -f "$temporary"
        return 1
    fi
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$destination" "$family" "$owned_gateway" "$physical_interface" "$prior_gateway" "$prior_interface" "$prior_policy" >>"$temporary" || return 1
    "$MV" "$temporary" "$ROUTE_JOURNAL"
}
journal_remove() {
    local destination
    destination=$(journal_key "$1") || return 1
    local temporary="$ROUTE_JOURNAL.new"
    if ! "$AWK" -F'|' -v destination="$destination" '$1 != destination' "$ROUTE_JOURNAL" 2>/dev/null >"$temporary"; then
        "$RM" -f "$temporary"
        return 1
    fi
    "$MV" "$temporary" "$ROUTE_JOURNAL"
}
ensure_owned_route() {
    local family=$1
    local destination=$2
    local gateway=$3
    local interface=$4
    local prior prior_gateway=- prior_interface=- prior_policy=- was_owned=0 prior_journal_entry lookup_status

    if route_matches "$family" "$destination" "$gateway" "$interface"; then
        return 0
    fi

    if prior_journal_entry=$(journal_entry "$destination"); then
        was_owned=1
    else
        lookup_status=$?
        [ "$lookup_status" -eq 1 ] || return "$lookup_status"
        prior_journal_entry=
    fi
    if [ "$#" -ge 5 ]; then
        prior=$5
    elif ! prior=$(capture_specific_route "$family" "$destination"); then
        return 1
    fi
    if [ -n "$prior" ]; then
        read -r prior_gateway prior_interface prior_policy <<<"$prior"
        prior_policy=${prior_policy:-normal}
    fi
    journal_add "$destination" "$family" "$prior" || return 1
    route_delete "$family" "$destination" || true
    if ! route_add "$family" "$destination" "$gateway" ||
       ! route_matches "$family" "$destination" "$gateway" "$interface"; then
        restore_journaled_route "$destination" "$family" "$gateway" "$interface" "$prior_gateway" "$prior_interface" "$prior_policy" || return 1
        if [ "$was_owned" -eq 1 ]; then
            journal_replace_entry "$prior_journal_entry" || return 1
        else
            journal_remove "$destination" || return 1
        fi
        return 1
    fi
}
restore_journaled_route() {
    local destination=$1
    local family=$2
    local owned_gateway=$3
    local owned_interface=$4
    local prior_gateway=$5
    local prior_interface=$6
    local prior_policy=${7:-normal}

    if route_matches "$family" "$destination" "$owned_gateway" "$owned_interface"; then
        route_delete "$family" "$destination" || return 1
        if [ "$prior_gateway" != - ]; then
            route_add "$family" "$destination" "$prior_gateway" "$prior_interface" "$prior_policy" || return 1
            route_matches "$family" "$destination" "$prior_gateway" "$prior_interface" "$prior_policy" || return 1
        else
            local deleted_route
            deleted_route=$(capture_specific_route "$family" "$destination") || return 1
            [ -z "$deleted_route" ] || return 1
            ! route_matches "$family" "$destination" "$owned_gateway" "$owned_interface" || return 1
        fi
        return 0
    fi

    if [ "$prior_gateway" != - ] &&
       route_matches "$family" "$destination" "$prior_gateway" "$prior_interface" "$prior_policy"; then
        return 0
    fi
    local current
    if ! current=$(capture_specific_route "$family" "$destination"); then
        return 1
    fi
    if [ -z "$current" ]; then
        if [ "$prior_gateway" = - ]; then
            return 0
        fi
        route_add "$family" "$destination" "$prior_gateway" "$prior_interface" "$prior_policy" &&
            route_matches "$family" "$destination" "$prior_gateway" "$prior_interface" "$prior_policy"
        return
    fi
    return 1
}

retire_owned_route() {
    local destination=$1
    local entry lookup_status family owned_gateway owned_interface prior_gateway prior_interface prior_policy
    if entry=$(journal_entry "$destination"); then
        :
    else
        lookup_status=$?
        [ "$lookup_status" -eq 1 ] && return 0
        return "$lookup_status"
    fi
    IFS='|' read -r _ family owned_gateway owned_interface prior_gateway prior_interface prior_policy <<<"$entry"
    prior_policy=${prior_policy:-normal}
    restore_journaled_route "$destination" "$family" "$owned_gateway" "$owned_interface" "$prior_gateway" "$prior_interface" "$prior_policy" || return 1
    journal_remove "$destination"
}
