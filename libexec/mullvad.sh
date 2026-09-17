# Mullvad resolves DNS through 100.64.0.X whenever its content blocker is on,
# where X is the sum of the enabled lists. That address sits inside
# 100.64.0.0/10 -- the CGNAT range Tailscale claims as a prefix route on its
# own interface -- and a /10 beats the tunnel's default route, so every query
# is delivered into the tailnet and answered by nobody. Traffic addressed by
# IP keeps working throughout, so the machine looks online while no name
# resolves, which reads as the VPN having broken the internet.
#
# A host route for the one address beats the /10 and returns the query to the
# tunnel. Observed on macOS 26.6.2 with Mullvad 2026.5 and Tailscale 1.102.4:
# with the route placed, blocking DNS and the tailnet both work; without it,
# `dig` times out while `curl https://1.1.1.1` still answers.
#
# MULLVAD_DNS_NETWORK is shared through common.sh: the relay bookkeeping in
# derp.sh has to recognise this network as one it does not own.

# Each list owns one bit and the resolver address is the network plus their
# sum. The order is Mullvad's own, as its settings file writes them; every bit
# was confirmed against the address the daemon queries with only that list on.
readonly MULLVAD_BLOCKLIST_BITS='block_ads=1 block_trackers=2 block_malware=4 block_adult_content=8 block_gambling=16 block_social_media=32'

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
mullvad_blocklist_keys() {
    "$AWK" '
        { text = text $0 "\n" }
        END {
            while (match(text, "\"block_[a-z_]+\"[ \t\r\n]*:")) {
                key = substr(text, RSTART + 1, RLENGTH - 1)
                sub(/"[ \t\r\n]*:$/, "", key)
                seen[key] = 1
                text = substr(text, RSTART + RLENGTH)
            }
            for (key in seen) print key
        }
    ' "$MULLVAD_SETTINGS"
}

# Prints the address Mullvad's blocking resolver answers on.
#
# Exit 1 is nothing to route: Mullvad absent, custom DNS in use, or no list
# enabled, all of which leave the resolver inside the tunnel where the default
# route already reaches it. Exit 2 is settings that could not be read, which
# must not collapse into exit 1 -- a sum computed from a file this parse no
# longer understands would route an address Mullvad never queries and leave
# the real one stolen, with health still reporting the route placed.
mullvad_blocklist_address() {
    [ -f "$MULLVAD_SETTINGS" ] && [ ! -L "$MULLVAD_SETTINGS" ] || return 1

    # A list this bit table does not name means Mullvad shipped a new one, and
    # the sum below would silently omit it. Refusing is the only answer that
    # does not route a wrong address with confidence. Only a key counts: a
    # custom list a user named `block_foo` appears as a value, and reading it
    # as a seventh list would degrade DNS over somebody's choice of name.
    local declared
    declared=$(mullvad_blocklist_keys | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [ "$declared" = 6 ] || return 2

    local state
    state=$(mullvad_setting state) || return 2
    # Custom DNS replaces the blocking resolver, so no address of this family
    # is in play.
    [ "$state" = default ] || return 1

    local total=0 pair key bit value
    for pair in $MULLVAD_BLOCKLIST_BITS; do
        key=${pair%%=*}
        bit=${pair##*=}
        value=$(mullvad_setting "$key") || return 2
        case "$value" in
            true) total=$((total + bit)) ;;
            false) ;;
            *) return 2 ;;
        esac
    done

    [ "$total" -ne 0 ] || return 1
    printf '%s%s\n' "$MULLVAD_DNS_NETWORK" "$total"
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

# Every resolver address the keeper has owned a route for. The address changes
# whenever a list is toggled, so the one it was placed under has to be
# withdrawn before the new one goes in. Nothing else the keeper owns lives in
# this network: relay routes are public addresses, and CGNAT is not.
journaled_mullvad_dns_addresses() {
    [ -f "$ROUTE_JOURNAL" ] || return 0
    "$AWK" -F'|' -v network="$MULLVAD_DNS_NETWORK" \
        'index($1, network) == 1 { print $1 }' "$ROUTE_JOURNAL"
}

# Answers whether a tailnet peer already holds this address.
#
# Tailscale assigns from the same /10 Mullvad draws the resolver address from,
# so the two can genuinely land on one address. Routing it into the tunnel
# would take that peer off the tailnet, trading the DNS outage for the outage
# this keeper exists to prevent, so a collision is named rather than resolved.
#
# Exit 0 is a peer holding it, 1 is no peer, 2 is an answer the CLI could not
# give. The signature check this runs is slow, so callers reach it only when a
# route is about to change, never on a steady-state pass.
tailnet_peer_holds_address() {
    local address=$1
    local peers="$RUNTIME_DIR/tailnet-peers"
    local status=0

    validate_tailscale_cli || return 2
    run_with_timeout 10 "$peers" "$TAILSCALE_CLI" status || { "$RM" -f "$peers"; return 2; }
    "$AWK" -v want="$address" '$1 == want { found = 1 } END { exit !found }' "$peers" || status=$?
    "$RM" -f "$peers"
    return "$status"
}

# Keeps Mullvad's blocking resolver reachable while Tailscale owns the prefix
# its address sits in.
#
# Returns 0 when the route is in the state it should be, placed or absent. 1
# is a route that could not be placed or withdrawn. 2 is settings that could
# not be read. 3 is a tailnet peer holding the resolver address, where placing
# the route would cure one outage by causing another. 4 is that same question
# left unanswered, which is not the same finding and does not share its code.
#
# Whatever the outcome, the address in health describes the table: a route is
# never left behind under an address this run did not place.
reconcile_mullvad_dns_route() {
    local address= status=0 result=0 stale= tunnel_interface= routing_table=
    local snapshot="$RUNTIME_DIR/mullvad-dns-retirement"

    address=$(mullvad_blocklist_address) || status=$?
    # Settings this parse no longer understands leave the right address
    # unknown, so none is kept. A route placed under an earlier reading would
    # go on stranding whatever now holds that address, while health reported
    # nothing routed.
    [ "$status" -eq 0 ] || address=
    [ "$status" -ne 2 ] || result=2

    if [ -n "$address" ] && [ -n "$tailscale_interface" ]; then
        # A table that cannot be read says nothing about the tunnel, and
        # retiring a working route over a transient failure to look would
        # break resolution to report that it could not be checked.
        routing_table=$("$NETSTAT" -rn -f inet 2>/dev/null) || return 1
        tunnel_interface=$(printf '%s\n' "$routing_table" | find_unscoped_default_interface)
        # With the uplink itself holding the unscoped default, Mullvad is not
        # carrying traffic and its resolver address is not being stolen.
        [ -n "$tunnel_interface" ] && [ "$tunnel_interface" != "$physical_interface" ] || address=
    else
        address=
    fi

    # The journal changes under each retirement, so the stale set is fixed
    # once before the loop starts rather than read as it shrinks.
    journaled_mullvad_dns_addresses >"$snapshot" || { "$RM" -f "$snapshot"; return 1; }
    status=0
    while read -r stale; do
        [ -n "$stale" ] || continue
        [ "$stale" != "$address" ] || continue
        retire_owned_route "$stale" || status=1
    done <"$snapshot"
    "$RM" -f "$snapshot"
    [ "$status" -eq 0 ] || return 1

    mullvad_dns_address=$address
    [ "$result" -eq 0 ] || return "$result"
    [ -n "$address" ] || return 0

    # An unchanged route is the steady state, and answering it from the
    # routing table keeps the five-minute run clear of the signature check
    # below.
    if route_matches -inet "$address" '' "$tunnel_interface"; then
        return 0
    fi

    status=0
    tailnet_peer_holds_address "$address" || status=$?
    if [ "$status" -ne 1 ]; then
        mullvad_dns_address=
        [ "$status" -ne 0 ] || return 3
        return 4
    fi

    ensure_owned_route -inet "$address" '' "$tunnel_interface" || {
        # The route rolled back, so the address describes nothing placed.
        mullvad_dns_address=
        return 1
    }
}
