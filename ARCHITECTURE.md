# Architecture

## Traffic paths

```text
ordinary host and guest traffic
Mac or OrbStack guest -> Mullvad tunnel -> Internet

tailnet payload
Mac -> Tailscale utun -> tailnet node

Tailscale transport
coordination, logging, DERP, STUN -> physical interface -> Internet
```

The keeper picks its uplink from the macOS network service order, taking the highest-priority configured service that owns an `UP`, non-rejecting default route. That list is the OS's own answer to which interfaces are real uplinks and which one wins, so a Thunderbolt Bridge counts while a container bridge or VPN tunnel does not, and the choice never depends on the order daemons happened to start. It uses the same interface for a usable link-local IPv6 default when one exists. Interface names and gateway addresses never enter static configuration.

## PF ownership

Apple's main ruleset loads `com.apple/*`. The keeper loads only this child anchor:

```text
com.apple/io.github.andredezzy.tailnet-keeper
```

The child anchor contains:

- physical-interface TCP rules for Tailscale coordination and logging ranges
- physical-interface TCP and UDP rules for dynamic DERP IPv4 and IPv6 tables
- Tailscale-interface rules for `100.64.0.0/10` and `fd7a:115c:a1e0::/48`
- inbound rules limited to the local Tailscale interface address

The keeper never reloads `/etc/pf.conf`. Mullvad's anchor and `com.apple.internet-sharing` remain under their existing owners.

## Reconciliation

`launchd` runs the keeper at load, after SystemConfiguration changes, and every five minutes as a safety check. The worker takes a single-writer lock, validates root-owned inputs, discovers routes and interfaces, reconciles its routes, loads its anchor, refreshes DERP state when required, and writes `/var/db/tailnet-keeper/health`.

PF disabled, an unsafe config file, a missing physical route, an unreadable routing table, or an invalid PF template triggers fail-closed cleanup. The keeper clears its anchor and restores only routes listed in its ownership journal.

Inspection failures are never read as absence. A routing table the keeper cannot read, or a relay list it cannot parse, fails the run instead of retiring the routes that family depends on.

## DERP transaction

A refresh uses the signed Tailscale app CLI as its data source. `plutil` validates and converts the JSON map; `xmllint` extracts IPv4 and IPv6 fields independent of JSON formatting. Address validation rejects private, reserved, tailnet, multicast, and shell-active input.

The transaction follows this order:

1. Snapshot live IPv4 and IPv6 PF tables, caches, and the route journal.
2. Validate both candidate lists.
3. Add or repair candidate routes and record each change.
4. Replace both live PF tables.
5. Commit both caches and gateway state.
6. Restore keeper-owned stale routes to their prior owners.

A failure before commit starts a verified restoration of changed routes, both live tables, both caches, and the journal. Incomplete restoration returns status `2` and leaves runtime snapshots for diagnosis.

The journal is keyed by destination, with IPv6 destinations reduced to a canonical form first. It stores the displaced gateway, interface, and forwarding policy, preserving `REJECT` and `BLACKHOLE` semantics during restoration. Older six-field records remain readable as normal routes.

## Boot recovery

`RESTART_TAILSCALE_AFTER_BOOT=on` enables a recovery state machine for machines affected by a macOS Network Extension lifecycle failure. The state file records the boot ID, phase, and attempt count before Tailscale stops. `launchd` keeps relaunching the worker while that file exists. A process crash between stop and start therefore resumes at the compensating start phase.

The state machine uses the Network Service UUID associated with `io.tailscale.ipn.macsys`, not its display name. It completes only after `scutil` reports `Connected`.

`launchd` relaunches the worker while the immediate recovery file exists. A slower retry file is checked on the five-minute service interval. Active interval retries remain `recovering`; malformed phases or counters are converted to terminal state instead of crashing repeatedly. Exhaustion creates a non-triggering marker for the current boot, so health remains degraded without another transition loop.

Because that file drives relaunch, no exit may leave it behind. Records from an earlier boot are retired before anything else runs, an unresolvable VPN service becomes a recorded failure rather than an early return, and a removal that failed once is retried on the next run.

A recoverable DERP refresh failure degrades health but still runs reconciliation. Health records both conditions together, including when VPN recovery has failed terminally, rather than hiding the stale DERP state. An interrupted stop or start is therefore compensated even while refreshes keep failing.

Health lives in the state directory. Whenever that directory or its contents fail their trust checks, the keeper clears its anchor and retires the health record rather than leaving a stale healthy one behind.

Route identity is always compared against the destination. `route -n get` answers a missing host route with the default route, so a matcher that read only the gateway and interface would report the keeper's own routes as present while the traffic followed the VPN. IPv6 destinations are compared canonically in both directions: the journal keys them expanded, the kernel always echoes them compressed, and a literal comparison would make every IPv6 route impossible to match or withdraw. `netstat` also renders some host routes with an explicit full-width mask, which names the same route as its bare form.

A route reaches its destination either through a gateway address or scoped directly to an interface. macOS spells the second kind inconsistently — `link#N`, a bare interface name, `index: N ifname`, or no gateway line at all — so all four are normalised to one internal form. Without that, an interface-scoped route is restored by passing an interface name where an address belongs, which the kernel rejects, and the displaced route is destroyed rather than returned to its owner.

Every bypass route through a gateway is bound to the physical interface with `-ifscope`. macOS keeps one default route per interface, and the VPN tunnel owns the primary one. A route without that binding has the right gateway and interface and still does nothing: the kernel selects the source address from the primary interface, and the socket fails with "Can't assign requested address" before a packet leaves. The scope follows the route through its whole life. A scoped route answers only a scoped lookup — an unscoped `route -n get` returns the tunnel's route instead — and an unscoped delete leaves it in place silently. The matcher therefore treats a bypass route without `IFSCOPE` as absent, so one left behind by an older version is repaired rather than accepted.

The kernel answers a lookup for an absent route with the covering route rather than an error, so every answer is checked against what was asked: the `HOST` flag and exact destination for a host, the exact mask for a prefix. Traffic to a neighbour also makes the kernel clone a host entry out of the covering route. That entry carries `HOST` but not `STATIC`, and counting it as placed once left most of the IPv6 relay routes missing while health reported them reconciled. Only a static route is one the keeper placed.

The steady-state check runs every five minutes over the whole relay list. It reads the routing table once per address family and takes the set difference against the desired list, filtered to static, scoped host routes through the uplink gateway. Asking the kernel for each route in turn answered the same question in nine seconds; the table read answers it in under one.
