# Mullvad's DNS content blocker does not filter inside the tunnel. It resolves
# through an address in 100.64.0.0/26: the network plus the sum of the enabled
# lists, one bit each. That block sits inside 100.64.0.0/10 -- the CGNAT range
# Tailscale assigns its nodes from and installs as a prefix route on its own
# interface -- and a /10 is more specific than the tunnel's default route, so
# every query left for the tailnet and was answered by nobody. Only name
# resolution uses that address, so everything addressed by IP kept working:
# the machine looked online while no name resolved.
#
# The block is routed, not the one address the current lists sum to. A /26
# still beats the /10 by a wide margin, and reading which lists are on only to
# pick an address inside a block that is routed anyway buys precision with a
# bit table that goes stale the day Mullvad ships another list -- the day the
# keeper would refuse to route and name resolution would stop until somebody
# noticed. The block is sized from the lists the settings actually declare, so
# that day it simply widens by one bit.
#
# MULLVAD_DNS_NETWORK, its base and the list ceiling are shared through
# common.sh: the relay bookkeeping in derp.sh has to recognise this network as
# one it does not own.

# Reads one value out of Mullvad's settings.
#
# The file is JSON, and `plutil` -- which every other parse in this project
# goes through -- rejects it outright, because Mullvad writes `null` for unset
# options and a property list has no null. The keys read here are unique in
# the file, so they are matched as tokens rather than by position: the match
# spans whitespace, so a reformatted or minified file reads the same.
#
# A key that appears anything other than once means the shape changed under
# an assumption this parse depends on, and it fails rather than read whichever
# copy came first.
mullvad_setting() {
    local key=$1
    "$AWK" -v key="$key" '
        { text = text $0 "\n" }
        END {
            occurrences = 0
            probe = text
            while (match(probe, "\"" key "\"[ \t\r\n]*:")) {
                occurrences++
                probe = substr(probe, RSTART + RLENGTH)
            }
            if (occurrences != 1) exit 1
            if (match(text, "\"" key "\"[ \t\r\n]*:[ \t\r\n]*(true|false)")) {
                value = substr(text, RSTART, RLENGTH)
                print (value ~ /true$/) ? "true" : "false"
                exit 0
            }
            if (match(text, "\"" key "\"[ \t\r\n]*:[ \t\r\n]*\"[^\"]*\"")) {
                value = substr(text, RSTART, RLENGTH)
                sub(/^.*"[ \t\r\n]*:[ \t\r\n]*"/, "", value)
                sub(/"$/, "", value)
                print value
                exit 0
            }
            exit 1
        }
    ' "$MULLVAD_SETTINGS"
}

# Prints each distinct `block_` key the settings declare, matched as a key --
# quoted name, then a colon -- so a value that happens to read like one is not
# counted. Whitespace between the two may include newlines, as it may for
# every other read here.
#
# Any name at all counts. A key this misses is a list whose bit the block is
# not sized for, and the resolver would then answer outside the route.
mullvad_blocklist_keys() {
    "$AWK" '
        { text = text $0 "\n" }
        END {
            while (match(text, "\"block_[^\"]+\"[ \t\r\n]*:")) {
                key = substr(text, RSTART + 1, RLENGTH - 1)
                sub(/"[ \t\r\n]*:$/, "", key)
                seen[key] = 1
                text = substr(text, RSTART + RLENGTH)
            }
            for (key in seen) print key
        }
    ' "$MULLVAD_SETTINGS"
}

# Prints the block Mullvad's blocking resolver answers in, as a prefix, and
# the count of addresses it holds.
#
# Exit 1 is nothing to route: Mullvad absent, custom DNS in use, or no list
# enabled, all of which leave the resolver inside the tunnel where the default
# route already reaches it. Exit 2 is settings that could not be read, which
# must not collapse into exit 1 -- a block sized from a file this parse no
# longer understands would leave the resolver answering outside the route,
# with health reporting one placed.
mullvad_blocklist_block() {
    [ -f "$MULLVAD_SETTINGS" ] && [ ! -L "$MULLVAD_SETTINGS" ] || return 1

    local state
    state=$(mullvad_setting state) || return 2
    # Custom DNS replaces the blocking resolver, so no address of this family
    # is in play.
    [ "$state" = default ] || return 1

    local keys count
    keys=$(mullvad_blocklist_keys) || return 2
    count=$(printf '%s\n' "$keys" | "$GREP" -c . || true)
    [ "$count" -ge 1 ] && [ "$count" -le "$MULLVAD_MAX_BLOCKLISTS" ] || return 2

    # Which lists are on decides only whether the resolver moves at all: the
    # route covers wherever inside the block it lands.
    local key value enabled=0
    while read -r key; do
        [ -n "$key" ] || continue
        value=$(mullvad_setting "$key") || return 2
        case "$value" in
            true) enabled=1 ;;
            false) ;;
            *) return 2 ;;
        esac
    done <<<"$keys"
    [ "$enabled" -eq 1 ] || return 1

    printf '%s/%s %s\n' "$MULLVAD_DNS_BLOCK_BASE" "$((32 - count))" "$((1 << count))"
}

# Prints the interface an unbound socket's packet leaves by, read from the
# IPv4 routing table on stdin. The kernel consults a scoped default only for a
# socket bound to its interface, and Mullvad's resolver binds none, so the one
# unscoped default is the path its query actually takes. While Mullvad carries
# traffic that is its tunnel; with the VPN down it is the uplink, and then no
# resolver address is being stolen.
find_unscoped_default_interface() {
    "$AWK" '$1 == "default" && $3 ~ /U/ && $3 !~ /I/ && $3 !~ /[RB]/ { print $4; exit }'
}

# Every resolver route the keeper has owned. The block widens whenever Mullvad
# ships a list, so the prefix it was placed under has to be withdrawn before
# the new one goes in. Nothing else the keeper owns lives in this network:
# relay routes are public addresses, and CGNAT is not.
journaled_mullvad_dns_routes() {
    [ -f "$ROUTE_JOURNAL" ] || return 0
    "$AWK" -F'|' -v network="$MULLVAD_DNS_NETWORK" \
        'index($1, network) == 1 { print $1 }' "$ROUTE_JOURNAL"
}

# Answers whether a tailnet node sits inside the block.
#
# Tailscale assigns from the same /10 Mullvad draws its resolver from, so a
# node can land in it. Routing over that node would take it off the tailnet,
# trading the DNS outage for the outage this keeper exists to prevent, so an
# overlap is named rather than resolved.
#
# Exit 0 is a node inside it, 1 is none, 2 is an answer the CLI could not
# give. The signature check this runs is slow, so callers reach it only when a
# route is about to change, never on a steady-state pass.
tailnet_peer_inside_block() {
    local size=$1
    local peers="$RUNTIME_DIR/tailnet-peers"
    local status=0

    validate_tailscale_cli || return 2
    run_with_timeout 10 "$peers" "$TAILSCALE_CLI" status || { "$RM" -f "$peers"; return 2; }
    "$AWK" -v network="$MULLVAD_DNS_NETWORK" -v size="$size" '
        index($1, network) == 1 {
            host = substr($1, length(network) + 1)
            if (host ~ /^[0-9]+$/ && host + 0 < size) found = 1
        }
        END { exit !found }
    ' "$peers" || status=$?
    "$RM" -f "$peers"
    return "$status"
}

# Keeps Mullvad's blocking resolver reachable while Tailscale owns the prefix
# it answers in.
#
# Returns 0 when the route is in the state it should be, placed or absent. 1
# is a route that could not be placed or withdrawn. 2 is settings that could
# not be read. 3 is a tailnet node inside the block, where placing the route
# would cure one outage by causing another. 4 is that same question left
# unanswered, which is not the same finding and does not share its code.
#
# The route in health describes the table, except on the two paths that return
# before any retirement: a routing table that could not be read, and an older
# route that could not be withdrawn. Both exit non-zero and are retried in
# five seconds.
reconcile_mullvad_dns_route() {
    local block= size=0 status=0 result=0 stale= tunnel_interface= routing_table=
    local specification=
    local snapshot="$RUNTIME_DIR/mullvad-dns-retirement"

    # Command substitution, not `read` from a process substitution: the latter
    # reports whether a line arrived, so every exit code this function turns
    # into a health detail would be replaced by `read`'s own.
    specification=$(mullvad_blocklist_block) || status=$?
    [ "$status" -ne 0 ] || read -r block size <<<"$specification"
    # Settings this parse no longer understands leave the block unknown, so
    # none is kept. A route placed under an earlier reading would go on
    # covering tailnet addresses while health reported nothing routed.
    [ "$status" -eq 0 ] || block=
    [ "$status" -ne 2 ] || result=2

    if [ -n "$block" ] && [ -n "$tailscale_interface" ]; then
        # A table that cannot be read says nothing about the tunnel, and
        # retiring a working route over a transient failure to look would
        # break resolution to report that it could not be checked.
        routing_table=$("$NETSTAT" -rn -f inet 2>/dev/null) || return 1
        tunnel_interface=$(printf '%s\n' "$routing_table" | find_unscoped_default_interface)
        # With the uplink itself holding the unscoped default, Mullvad is not
        # carrying traffic and its resolver is not being stolen.
        [ -n "$tunnel_interface" ] && [ "$tunnel_interface" != "$physical_interface" ] || block=
    else
        block=
    fi

    # The journal changes under each retirement, so the stale set is fixed
    # once before the loop starts rather than read as it shrinks.
    journaled_mullvad_dns_routes >"$snapshot" || { "$RM" -f "$snapshot"; return 1; }
    status=0
    while read -r stale; do
        [ -n "$stale" ] || continue
        [ "$stale" != "$block" ] || continue
        retire_owned_route "$stale" || status=1
    done <"$snapshot"
    "$RM" -f "$snapshot"
    [ "$status" -eq 0 ] || return 1

    mullvad_dns_route=$block
    [ "$result" -eq 0 ] || return "$result"
    [ -n "$block" ] || return 0

    # An unchanged route is the steady state, and answering it from the
    # routing table keeps the five-minute run clear of the signature check
    # below.
    if route_matches -inet "$block" '' "$tunnel_interface"; then
        return 0
    fi

    status=0
    tailnet_peer_inside_block "$size" || status=$?
    if [ "$status" -ne 1 ]; then
        mullvad_dns_route=
        # The block is not being routed, so a route an earlier run placed over
        # it does not stay: the tunnel it points into may since have changed,
        # and a node inside it needs the table clear.
        retire_owned_route "$block" || return 1
        [ "$status" -ne 0 ] || return 3
        return 4
    fi

    ensure_owned_route -inet "$block" '' "$tunnel_interface" || {
        # The route rolled back, so the block describes nothing placed.
        mullvad_dns_route=
        return 1
    }
}
