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
    local wanted=$1 actual=$2
    [ -n "$actual" ] || return 1
    # The kernel renders some host routes with an explicit full-width mask,
    # so strip it before comparing against the bare host that was asked for.
    actual=${actual%/32}
    actual=${actual%/128}
    if [[ "$wanted" == *:* ]]; then
        # IPv6 has many spellings of one address; only the canonical form is
        # comparable. The journal key and the kernel may disagree on zeros.
        [ "$(canonical_ipv6 "${wanted%%\%*}")" = "$(canonical_ipv6 "${actual%%\%*}")" ]
    else
        [ "$wanted" = "$actual" ]
    fi
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

# Reads one route out of `route -n get` output: gateway, interface, policy,
# and whether the route is interface-scoped.
#
# The kernel answers a lookup for an absent route with the covering route
# rather than an error, so the answer must be checked against what was asked.
# For a host that means the HOST flag and the exact destination; for a
# prefix it means the exact destination and mask. A host entry the kernel
# clones for a neighbour carries HOST as well, but never STATIC: only a
# STATIC route is one that was placed.
#
# Exit 1 is a confirmed absence. Exit 2 is output that could not be read.
route_details() {
    local destination=$1
    local expected_destination=${destination%/*}
    local expected_mask
    case "$destination" in
        */24) expected_mask=255.255.255.0 ;;
        */48) expected_mask=ffff:ffff:ffff:: ;;
        */*) return 2 ;;
        *) expected_mask= ;;
    esac

    local details actual gateway interface policy scope
    details=$("$AWK" -v expected_mask="$expected_mask" '
        $1 == "destination:" { destination=$2 }
        $1 == "mask:" { mask=tolower($2) }
        $1 == "gateway:" { gateway=$NF }
        $1 == "interface:" { interface=$2 }
        $1 == "flags:" { flags=$2 }
        function has(flag) { return flags ~ ("(^|[,<])" flag "([,>]|$)") }
        END {
            if (destination == "" || interface == "" || flags == "" || !has("UP")) exit 2
            if (expected_mask == "") {
                if (!has("HOST") || !has("STATIC")) exit 1
            } else if (mask != expected_mask) exit 1
            policy = ""
            if (has("REJECT")) policy = "reject"
            if (has("BLACKHOLE")) policy = policy == "" ? "blackhole" : policy "+blackhole"
            if (policy == "") policy = "normal"
            print destination, (gateway == "" ? "-" : gateway), interface, policy, (has("IFSCOPE") ? "scoped" : "unscoped")
        }
    ') || return "$?"
    read -r actual gateway interface policy scope <<<"$details"
    destinations_equal "$expected_destination" "$actual" || return 1
    [ "$gateway" != - ] || gateway=
    printf '%s %s %s %s\n' "$(normalize_gateway "$gateway" "$interface")" "$interface" "$policy" "$scope"
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

# One awk program canonicalises IPv6 for both the single-address and the
# stream form, so the two can never drift apart. A line that is not a valid
# address fails the whole run: an unparseable entry is a defect, not noise.
CANONICAL_IPV6_PROGRAM='
    # An empty result means the address did not parse. In stream mode a row
    # that does not parse is skipped; the caller compares against canonical
    # keys, and a row it cannot key is one it can never match. In single mode
    # an unparseable address is the error the exit status reports.
    function normalize(group) {
        group=tolower(group)
        if (length(group) < 1 || length(group) > 4 || group !~ /^[0-9a-f]+$/) return ""
        while (length(group) > 1 && substr(group, 1, 1) == "0") group=substr(group, 2)
        return group
    }
    function canonical(address,    zone, compressed, left, right, left_count, right_count, missing, count, i, output, groups, left_parts, right_parts, parts) {
        address=tolower(address)
        # A link-local zone, fe80::1%en0, is part of the address: the uplink
        # gateway is written that way and the table prints it that way.
        zone=""
        if (index(address, "%")) { zone=substr(address, index(address, "%")); address=substr(address, 1, index(address, "%") - 1) }
        count=0
        compressed=index(address, "::")
        if (compressed) {
            left=substr(address, 1, compressed - 1)
            right=substr(address, compressed + 2)
            if (index(right, "::")) return ""
            left_count=left == "" ? 0 : split(left, left_parts, ":")
            right_count=right == "" ? 0 : split(right, right_parts, ":")
            missing=8 - left_count - right_count
            if (missing < 1) return ""
            for (i=1; i<=left_count; i++) groups[++count]=normalize(left_parts[i])
            for (i=1; i<=missing; i++) groups[++count]="0"
            for (i=1; i<=right_count; i++) groups[++count]=normalize(right_parts[i])
        } else {
            count=split(address, parts, ":")
            if (count != 8) return ""
            for (i=1; i<=count; i++) groups[i]=normalize(parts[i])
        }
        if (count != 8) return ""
        for (i=1; i<=8; i++) if (groups[i] == "") return ""
        output=groups[1]
        for (i=2; i<=8; i++) output=output ":" groups[i]
        return output zone
    }
    !NF { next }
    { key = index($1, ":") ? canonical($1) : $1 }
    key == "" { if (keyed) next; exit 1 }
    keyed { print key, $0; next }
    { print key }
'

canonical_ipv6() {
    printf '%s\n' "$1" | "$AWK" "$CANONICAL_IPV6_PROGRAM"
}

# Canonicalises every address on stdin in one process; IPv4 lines pass
# through unchanged. Use this over canonical_ipv6 whenever there is a list.
canonical_address_stream() {
    "$AWK" "$CANONICAL_IPV6_PROGRAM"
}

# Same, but prefixes each line with its canonical key: "canonical <line>".
# A set operation on the key column can then hand back the original spelling
# and any further columns a caller must act on.
canonical_address_stream_keyed() {
    "$AWK" -v keyed=1 "$CANONICAL_IPV6_PROGRAM"
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

# True when the placed route is in the table: a static route to the
# destination through the gateway on the interface, not interface-scoped.
#
# The table is read rather than `route -n get`. Traffic clones a per-interface
# cache entry beside a placed route, and the lookup answers with the clone
# while it lives; that says nothing about the placed route, which a plain
# socket still uses. A scoped route is excluded because a plain socket never
# consults one, so it is not a bypass the client can use.
route_matches() {
    local family=$1
    local destination=$2
    local gateway=$3
    local interface=$4
    local policy=${5:-normal}
    local table_family=inet
    [ "$family" = -inet6 ] && table_family=inet6

    "$NETSTAT" -rn -f "$table_family" 2>/dev/null |
        table_route_matches "$destination" "$gateway" "$interface" "$policy" unscoped
}

# Decides whether a netstat table on stdin holds the described route.
#
# netstat prints an IPv4 network with trailing zero octets dropped and the
# prefix length appended when it is not the class default: `192.200.0/24`
# is 192.200.0.0/24, `172.20.10/28` is 172.20.10.0/28, and `10` is
# 10.0.0.0/8. A host prints in full, sometimes with an explicit /32 or
# /128. Flags are the single-letter set: S static, H host, I scoped,
# R reject, B blackhole. The final argument names the scope required:
# `unscoped`, `scoped`, or `any`.
table_route_matches() {
    local destination=$1
    local expected_gateway=$2
    local expected_interface=$3
    local expected_policy=${4:-normal}
    local scope=${5:-any}
    local wanted=${destination%%/*}
    local wanted_length=${destination#*/}
    local prefix=0
    [ "$wanted_length" != "$destination" ] || wanted_length=
    [ -z "$wanted_length" ] || prefix=1
    [[ "$wanted" != *:* ]] || wanted=$(canonical_ipv6 "$wanted") || return 1
    expected_gateway=$(normalize_gateway "$expected_gateway" "$expected_interface")

    "$AWK" -v prefix="$prefix" -v wanted_length="$wanted_length" '
        function classful(net,    n) {
            n = split(net, o, ".")
            if (n == 1) return 8
            if (n == 2) return 16
            if (n == 3) return 24
            return 32
        }
        function padded(net,    n) {
            for (n = split(net, o, "."); n < 4; n++) net = net ".0"
            return net
        }
        $3 !~ /S/ { next }
        prefix && $3 !~ /H/ {
            dest = $1
            len = classful(dest)
            if (dest ~ /\//) { len = dest; sub(/.*\//, "", len); sub(/\/.*/, "", dest) }
            if (dest !~ /:/) dest = padded(dest)
            if (len != wanted_length) next
            print dest, $2, $4, $3
        }
        !prefix && $3 ~ /H/ {
            dest = $1; sub(/\/[0-9]+$/, "", dest)
            print dest, $2, $4, $3
        }
    ' |
        canonical_address_stream_keyed |
        "$AWK" -v wanted="$wanted" -v gateway="$expected_gateway" -v interface="$expected_interface" \
            -v policy="$expected_policy" -v scope="$scope" -v prefix_arg="$INTERFACE_GATEWAY_PREFIX" '
            $1 != wanted || $4 != interface { next }
            {
                flags = $5
                actual_policy = ""
                if (flags ~ /R/) actual_policy = "reject"
                if (flags ~ /B/) actual_policy = actual_policy == "" ? "blackhole" : actual_policy "+blackhole"
                if (actual_policy == "") actual_policy = "normal"
                if (actual_policy != policy) next
                actual_scope = flags ~ /I/ ? "scoped" : "unscoped"
                if (scope != "any" && actual_scope != scope) next
                actual_gateway = $3
                if (actual_gateway ~ /^link#/ || actual_gateway == interface) actual_gateway = prefix_arg interface
                if (actual_gateway != gateway) next
                found = 1; exit
            }
            END { exit !found }
        '
}

# True when the table holds the route the journal says was placed, in either
# scope. This is the question retirement asks; route_matches asks the
# stricter one -- is it a route a plain socket can use. A route an earlier
# version placed scoped is still ours to remove even though it is no longer
# one we would accept.
owned_route_present() {
    local family=$1
    local destination=$2
    local gateway=$3
    local interface=$4
    local policy=${5:-normal}
    local table_family=inet
    [ "$family" = -inet6 ] && table_family=inet6

    "$NETSTAT" -rn -f "$table_family" 2>/dev/null |
        table_route_matches "$destination" "$gateway" "$interface" "$policy" any
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
# Adds a route an ordinary socket will use. The kernel consults an
# interface-scoped route (-ifscope) only for a socket bound to that interface,
# and the Tailscale daemon binds none, so a scoped bypass would be invisible
# to it and its traffic would follow the tunnel's default route instead.
route_add() {
    local family=$1
    local destination=$2
    local gateway=$3
    local interface=${4:-}
    local policy=${5:-normal}
    local kind=-host
    [[ "$destination" != */* ]] || kind=-net

    gateway=$(normalize_gateway "$gateway" "$interface")
    if [[ "$gateway" == "$INTERFACE_GATEWAY_PREFIX"* ]]; then
        # An interface route is re-added by interface, never by passing the
        # interface name where an address belongs.
        interface=${gateway#"$INTERFACE_GATEWAY_PREFIX"}
        [ -n "$interface" ] || return 1
        if [ "$family" = -inet6 ]; then
            route_add_command "$policy" -q -n add -inet6 "$destination" -interface "$interface" >/dev/null 2>&1
        else
            route_add_command "$policy" -q -n add "$kind" "$destination" -interface "$interface" >/dev/null 2>&1
        fi
    elif [ "$family" = -inet6 ]; then
        route_add_command "$policy" -q -n add -inet6 "$kind" "$destination" "$gateway" >/dev/null 2>&1
    else
        route_add_command "$policy" -q -n add "$kind" "$destination" "$gateway" >/dev/null 2>&1
    fi
}
# Removes a route in whichever scope it exists. A scoped route is removable
# only through its scope, and an unscoped delete leaves it in place silently;
# a host that then carries both a scoped and an unscoped route refuses a
# plain socket outright. An unscoped lookup cannot reveal a scoped-only
# route -- the kernel answers with the covering route -- so the table is read
# for every interface the destination is scoped to, and each is named.
route_delete() {
    local family=$1
    local destination=$2
    local kind=-host
    [[ "$destination" != */* ]] || kind=-net
    local table_family=inet
    [ "$family" = -inet6 ] && table_family=inet6

    local status=0 interface
    "$ROUTE" -q -n delete "$family" "$kind" "$destination" >/dev/null 2>&1 || true
    while read -r interface; do
        [ -n "$interface" ] || continue
        "$ROUTE" -q -n delete "$family" "$kind" -ifscope "$interface" "$destination" >/dev/null 2>&1 || status=1
    done < <(scoped_route_interfaces "$table_family" "$destination")
    return "$status"
}

# Prints each interface the destination has an interface-scoped route on.
# The table is canonicalised in one pass so IPv6 spellings compare, and a
# prefix is matched on the bare network the table prints for it.
scoped_route_interfaces() {
    local table_family=$1
    local destination=$2
    local wanted=${destination%%/*}
    [[ "$wanted" != *:* ]] || wanted=$(canonical_ipv6 "$wanted") || return 1

    "$NETSTAT" -rn -f "$table_family" 2>/dev/null |
        "$AWK" '$3 ~ /I/ && $3 ~ /S/ { sub(/\/[0-9]+$/, "", $1); print $1, $4 }' |
        canonical_address_stream_keyed |
        "$AWK" -v wanted="$wanted" '$1 == wanted { print $3 }'
}
capture_specific_route() {
    local family=$1
    local destination=$2
    local kind=-host
    [[ "$destination" != */* ]] || kind=-net

    # The route command's own exit status is what separates "the lookup
    # failed" from "there is no such route": an absent route still answers
    # with its covering route, which route_details reports as absence.
    local lookup details status
    lookup=$("$ROUTE" -n get "$family" "$kind" "$destination" 2>/dev/null) || return 2
    [ -n "$lookup" ] || return 0
    details=$(printf '%s\n' "$lookup" | route_details "$destination")
    status=$?
    case "$status" in
        0) printf '%s\n' "${details% *}" ;;
        1) return 0 ;;
        *) return "$status" ;;
    esac
}
# The journal is keyed by destination, so two spellings of the same IPv6
# address must resolve to one entry. Prefixes and IPv4 destinations already
# have a single spelling and are used verbatim.
# Copies the journal to a staging file with one destination's entry removed.
# A journal that does not exist yet contributes no lines, which is the ordinary
# state of a first run rather than a failure to read it.
journal_without_entry() {
    local destination=$1
    local temporary=$2

    if [ ! -f "$ROUTE_JOURNAL" ]; then
        : >"$temporary" && return 0
        "$RM" -f "$temporary"
        return 1
    fi
    if ! "$AWK" -F'|' -v destination="$destination" '$1 != destination' "$ROUTE_JOURNAL" 2>/dev/null >"$temporary"; then
        "$RM" -f "$temporary"
        return 1
    fi
}

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
    # A journal that does not exist yet holds no entries. That is the ordinary
    # state of a first run, not a failure to read, so it reports absence.
    [ -f "$ROUTE_JOURNAL" ] || return 1
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
    journal_without_entry "$destination" "$temporary" || return 1
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
    journal_without_entry "$destination" "$temporary" || return 1
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$destination" "$family" "$owned_gateway" "$physical_interface" "$prior_gateway" "$prior_interface" "$prior_policy" >>"$temporary" || return 1
    "$MV" "$temporary" "$ROUTE_JOURNAL"
}
journal_remove() {
    local destination
    destination=$(journal_key "$1") || return 1
    local temporary="$ROUTE_JOURNAL.new"
    journal_without_entry "$destination" "$temporary" || return 1
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
    if ! route_add "$family" "$destination" "$gateway" "$interface" ||
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

    if owned_route_present "$family" "$destination" "$owned_gateway" "$owned_interface"; then
        route_delete "$family" "$destination" || return 1
        if [ "$prior_gateway" != - ]; then
            route_add "$family" "$destination" "$prior_gateway" "$prior_interface" "$prior_policy" || return 1
            route_matches "$family" "$destination" "$prior_gateway" "$prior_interface" "$prior_policy" || return 1
        else
            local deleted_route
            deleted_route=$(capture_specific_route "$family" "$destination") || return 1
            [ -z "$deleted_route" ] || return 1
            ! owned_route_present "$family" "$destination" "$owned_gateway" "$owned_interface" || return 1
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
