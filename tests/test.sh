#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEEPER="$PROJECT_ROOT/bin/tailnet-keeper"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_equal() {
    local expected=$1
    local actual=$2
    local message=$3
    [ "$actual" = "$expected" ] || fail "$message\nexpected: $expected\nactual:   $actual"
}

[ -f "$KEEPER" ] || fail "tailnet-keeper is missing"
[ "$(grep -c '^if \[ "${TAILNET_KEEPER_TESTING:-0}" != 1 \] && \[ "${TAILNET_KEEPER_SOURCE_ONLY:-0}" != 1 \]; then$' "$KEEPER")" -eq 1 ] || fail 'keeper entrypoint invokes main more than once'
# shellcheck source=../tailnet-keeper
TAILNET_KEEPER_TESTING=1 source "$KEEPER"

ipv4_routes='default            10.0.0.1           UGScg                 utun5
default            link#22            UCSIg             bridge100
default            192.168.0.1        UGScg                   en0'
assert_equal '192.168.0.1 en0' "$(find_physical_ipv4_route <<<"$ipv4_routes")" \
    'physical IPv4 route must ignore tunnel and VM defaults'

ipv6_routes='default                                 fe80::%utun5                            UGcIg               utun5
default                                 fe80::4f2:67ff:fe34:6c55%en0            UGcg                  en0'
assert_equal 'fe80::4f2:67ff:fe34:6c55%en0 en0' "$(find_physical_ipv6_route <<<"$ipv6_routes")" \
    'physical IPv6 route must ignore tunnel defaults'

rules=$(render_rules en7 utun9 "$PROJECT_ROOT/tailnet-keeper.pf")
grep -q 'on en7 ' <<<"$rules" || fail 'renderer did not bind infrastructure rules to the physical interface'
grep -q 'on utun9 ' <<<"$rules" || fail 'renderer did not bind tailnet rules to the Tailscale interface'
grep -q 'from 100.64.0.0/10 to (utun9)' <<<"$rules" || fail 'IPv4 inbound rule is not restricted to the local Tailscale address'
grep -q 'from fd7a:115c:a1e0::/48 to (utun9)' <<<"$rules" || fail 'IPv6 inbound rule is not restricted to the local Tailscale address'
! grep -qE '^pass in .* to any ' <<<"$rules" || fail 'inbound tailnet policy permits forwarding to arbitrary destinations'
! grep -qE '^pass out .* from any ' <<<"$rules" || fail 'outbound bypass policy permits forwarded traffic'
! grep -q '__[A-Z_]*__' <<<"$rules" || fail 'renderer left unresolved placeholders'

bootstrap_rules=$(render_rules en7 '' "$PROJECT_ROOT/tailnet-keeper.pf")
grep -q 'on en7 ' <<<"$bootstrap_rules" || fail 'bootstrap renderer removed physical rules'
! grep -q '100.64.0.0/10' <<<"$bootstrap_rules" || fail 'bootstrap renderer retained IPv4 tailnet rules without an interface'
! grep -q 'fd7a:115c:a1e0::/48' <<<"$bootstrap_rules" || fail 'bootstrap renderer retained IPv6 tailnet rules without an interface'

for network in 192.200.0.0/24 199.165.136.0/24 2606:b740:49::/48 2606:b740:1::/48; do
    grep -q "$network" "$PROJECT_ROOT/tailnet-keeper.pf" || fail "missing documented Tailscale range: $network"
done

# A bypass route must be bound to its uplink. Without IFSCOPE the kernel takes
# a source address from the primary interface, which a peer VPN owns, and the
# socket fails before sending -- so an unscoped route is not an equal match.
route_output='   route to: 192.200.0.107
destination: 192.200.0.107
    gateway: 192.168.0.1
  interface: en7
      flags: <UP,GATEWAY,HOST,DONE,STATIC,IFSCOPE>'
route_output_matches 192.200.0.107 '192.168.0.1' en7 <<<"$route_output" || fail 'matching usable gateway and interface were rejected'
unscoped_output='   route to: 192.200.0.107
destination: 192.200.0.107
    gateway: 192.168.0.1
  interface: en7
      flags: <UP,GATEWAY,HOST,DONE,STATIC>'
! route_output_matches 192.200.0.107 '192.168.0.1' en7 <<<"$unscoped_output" || fail 'an unscoped bypass route was accepted as correct'
! route_output_matches 192.200.0.107 '192.168.0.1' en8 <<<"$route_output" || fail 'wrong interface was accepted'
! route_output_matches 192.200.0.107 '192.168.0.2' en7 <<<"$route_output" || fail 'wrong gateway was accepted'
! route_output_matches 192.200.0.108 '192.168.0.1' en7 <<<"$route_output" || fail 'a different destination was accepted'
! route_output_matches 192.200.0.107 '192.168.0.1' en7 <<<"${route_output/UP,GATEWAY/UP,GATEWAY,REJECT}" || fail 'REJECT route was accepted'
! route_output_matches 192.200.0.107 '192.168.0.1' en7 <<<"${route_output/UP,GATEWAY/UP,GATEWAY,BLACKHOLE}" || fail 'BLACKHOLE route was accepted'

network_default_output='destination: default
       mask: default
    gateway: 192.168.0.1
  interface: en7
      flags: <UP,GATEWAY,DONE,STATIC>'
! network_route_output_matches 192.200.0.0/24 192.168.0.1 en7 <<<"$network_default_output" || fail 'network matcher accepted the physical default route'
network_exact_output='destination: 192.200.0.0
       mask: 255.255.255.0
    gateway: 192.168.0.1
  interface: en7
      flags: <UP,GATEWAY,DONE,STATIC>'
network_route_output_matches 192.200.0.0/24 192.168.0.1 en7 <<<"$network_exact_output" || fail 'network matcher rejected an exact /24 route'
! network_route_output_matches 192.200.0.0/24 192.168.0.1 en7 <<<"${network_exact_output/UP,GATEWAY/UP,GATEWAY,BLACKHOLE}" || fail 'network matcher accepted a BLACKHOLE route'
[ "$(network_route_details 192.200.0.0/24 <<<"$network_exact_output")" = '192.168.0.1 en7 normal' ] || fail 'exact network route details were not captured'
if network_route_details 192.200.0.0/24 <<<"$network_default_output" >/dev/null; then fail 'default route details were captured as a specific route'; fi

needs_boot_reconciliation boot-b boot-a Connected 1 120 || fail 'new boot with populated DERP cache must reconcile a connected VPN'
! needs_boot_reconciliation boot-a boot-a Connected 1 120 || fail 'same boot reconciled twice'
! needs_boot_reconciliation boot-b boot-a Disconnected 1 120 || fail 'disconnected VPN was treated as safely restartable'
! needs_boot_reconciliation boot-b boot-a Connected 0 120 || fail 'empty DERP cache allowed VPN reconciliation'
! needs_boot_reconciliation boot-b boot-a Connected 1 601 || fail 'VPN reconciliation escaped the boot window'

assert_equal stop "$(vpn_recovery_action none Connected 0)" 'fresh recovery must stop a connected VPN'
assert_equal stop "$(vpn_recovery_action stopping Connected 1)" 'stopping phase must retry a stop that did not take effect'
assert_equal wait "$(vpn_recovery_action stopping Disconnecting 1)" 'stopping phase must wait while disconnecting'
assert_equal start "$(vpn_recovery_action stopping Disconnected 1)" 'stopping phase must compensate by starting after disconnect'
assert_equal start "$(vpn_recovery_action starting Disconnected 2)" 'starting phase must retry a disconnected VPN'
assert_equal complete "$(vpn_recovery_action starting Connected 2)" 'starting phase must complete only after reconnect'
assert_equal terminal_start "$(vpn_recovery_action starting Disconnected 20)" 'attempt budget must end with a start and slow retry, not abandon Tailscale disconnected'
assert_equal terminal_start "$(vpn_recovery_action starting Connecting 20)" 'attempt budget must move every non-connected start state to slow retry'
assert_equal terminal_stop "$(vpn_recovery_action stopping Connected 20)" 'attempt budget must not complete before a disconnect was observed'
assert_equal start "$(vpn_retry_action boot-b boot-b starting Disconnected 0)" 'slow start retry must start a disconnected VPN'
assert_equal complete "$(vpn_retry_action boot-b boot-b starting Connected 3)" 'slow start retry must complete when VPN reconnects'
assert_equal stop "$(vpn_retry_action boot-b boot-b stopping Connected 0)" 'slow stop retry must keep stopping a connected VPN'
assert_equal exhausted "$(vpn_retry_action boot-b boot-b stopping Connected 3)" 'slow stop retry must stop after its attempt budget'
assert_equal start_transition "$(vpn_retry_action boot-b boot-b stopping Disconnected 3)" 'a completed stop must transition to start even at the attempt budget'
assert_equal clear "$(vpn_retry_action boot-b boot-a starting Disconnected 0)" 'stale retry state must be cleared after another boot'
assert_equal none "$(vpn_retry_action boot-b '' '' Disconnected '')" 'an absent retry record must stay dormant'
assert_equal clear "$(vpn_retry_action boot-b '' stopping Connected 1)" 'a retry record with an empty boot field must be cleared, not treated as dormant'

valid_derp_ipv4 8.8.8.8 || fail 'valid global IPv4 relay was rejected'
for unsafe_address in 10.0.0.1 100.64.0.1 127.0.0.1 169.254.1.1 172.16.0.1 192.0.2.1 192.31.196.1 192.52.193.1 192.88.99.1 192.168.0.1 192.175.48.1 198.18.0.1 198.51.100.1 203.0.113.7 224.0.0.1 255.255.255.255 008.8.8.8 203.0.113.999 '1.2.3.4;touch /tmp/pwned'; do
    ! valid_derp_ipv4 "$unsafe_address" || fail "unsafe relay value was accepted: $unsafe_address"
done
valid_derp_ipv6 '2a03:2880:f10c:83:face:b00c:0:25de' || fail 'valid global IPv6 relay was rejected'
for unsafe_address in '::1' 'fe80::1' 'fd7a:115c:a1e0::1' '2001:db8::1' '2a03::1;touch/tmp/pwned'; do
    ! valid_derp_ipv6 "$unsafe_address" || fail "unsafe IPv6 relay value was accepted: $unsafe_address"
done
[ "$(canonical_ipv6 '2600::1')" = '2600:0:0:0:0:0:0:1' ] || fail 'IPv6 canonicalization failed for compressed address'
[ "$(canonical_ipv6 '2600:0:0:0::1')" = '2600:0:0:0:0:0:0:1' ] || fail 'equivalent IPv6 text did not canonicalize identically'

grep -q 'table <tailscale_derp6>' "$PROJECT_ROOT/tailnet-keeper.pf" || fail 'IPv6 DERP table is missing'
grep -q 'inet6 proto tcp from (en7) to <tailscale_derp6>' <<<"$rules" || fail 'IPv6 DERP TCP bypass is missing'
grep -q 'inet6 proto udp from (en7) to <tailscale_derp6>' <<<"$rules" || fail 'IPv6 DERP STUN bypass is missing'

journal_sandbox=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-journal.XXXXXX")
trap 'rm -rf "$journal_sandbox"' EXIT
TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_STATE_DIR="$journal_sandbox" bash -c '
    source "$1"
    : >"$ROUTE_JOURNAL"
    physical_ipv4_gateway=192.168.0.1
    physical_interface=en0
    journal_add 203.0.113.7 -inet "198.51.100.1 en1"
    journal_add 203.0.113.7 -inet -
    [ "$(cat "$ROUTE_JOURNAL")" = "203.0.113.7|-inet|192.168.0.1|en0|198.51.100.1|en1|normal" ]
' _ "$KEEPER" || fail 'route repair discarded the original displaced route'

canonical_fixture='table <tailscale_derp> persist file "/state/derp"
pass out quick on en7 inet from any to 192.200.0.0/24'
expected_rule='pass out quick on en7 inet from any to 192.200.0.0/24'
[ "$(printf '%s\n' "$canonical_fixture" | rules_without_tables)" = "$expected_rule" ] || fail 'PF read-back comparison retained table declarations'

route_fake="$journal_sandbox/route-fake"
route_log="$journal_sandbox/route-log"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >"%s"\n' "$route_log" >"$route_fake"
chmod +x "$route_fake"
TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_ROUTE="$route_fake" bash -c '
    source "$1"
    route_add -inet6 2001:db8:1234::/64 "link#4" en0
' _ "$KEEPER" || fail 'direct route restoration failed'
[ "$(cat "$route_log")" = '-q -n add -inet6 2001:db8:1234::/64 -interface en0' ] || fail 'direct route restoration used link number as a gateway'

printf '#!/usr/bin/env bash\n/usr/bin/printf "   route to: 203.0.113.0\\ndestination: default\\n    gateway: index: 32 utun5\\n  interface: utun5\\n      flags: <UP,GATEWAY,DONE,STATIC>\\n"\n' >"$route_fake"
chmod +x "$route_fake"
TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_ROUTE="$route_fake" bash -c '
    set -euo pipefail
    source "$1"
    result=$(capture_specific_route -inet 203.0.113.0/24)
    [ -z "$result" ]
' _ "$KEEPER" || fail 'missing network route was reported as an inspection error'

printf '#!/usr/bin/env bash\nexit 2\n' >"$route_fake"
chmod +x "$route_fake"
if TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_ROUTE="$route_fake" bash -c '
    set -euo pipefail
    source "$1"
    capture_specific_route -inet 203.0.113.0/24 >/dev/null
' _ "$KEEPER"; then
    fail 'network route command failure was reported as confirmed absence'
fi

codesign_fake="$journal_sandbox/codesign-fake"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\nif [ "$1" = -dv ]; then printf "Identifier=io.tailscale.ipn.macsys\\nTeamIdentifier=W5364U7YZB\\n" >&2; fi\n' "$journal_sandbox/codesign-log" >"$codesign_fake"
chmod +x "$codesign_fake"

scutil_fake="$journal_sandbox/scutil-fake"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$journal_sandbox/scutil-log" >"$scutil_fake"
chmod +x "$scutil_fake"
sysctl_fake="$journal_sandbox/sysctl-fake"
printf '#!/bin/bash\nprintf "{ sec = 123, usec = 0 }\\n"\n' >"$sysctl_fake"
chmod +x "$sysctl_fake"
pfctl_fake="$journal_sandbox/pfctl-fake"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$journal_sandbox/pfctl-log" >"$pfctl_fake"
chmod +x "$pfctl_fake"
mv_fake="$journal_sandbox/mv-fake"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$journal_sandbox/mv-log" >"$mv_fake"
chmod +x "$mv_fake"
TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_SCUTIL="$scutil_fake" TAILNET_KEEPER_SYSCTL="$sysctl_fake" TAILNET_KEEPER_PFCTL="$pfctl_fake" TAILNET_KEEPER_MV="$mv_fake" bash -c '
    set -euo pipefail
    source "$1"
    "$SCUTIL" probe
    "$SYSCTL" probe | grep -q "sec = 123"
    "$PFCTL" probe
    "$MV" probe
' _ "$KEEPER" || fail 'external command test seams are unavailable'

mv_failure_fake="$journal_sandbox/mv-failure-fake"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\nexit 1\n' "$journal_sandbox/mv-failure-log" >"$mv_failure_fake"
chmod +x "$mv_failure_fake"
: >"$journal_sandbox/pfctl-log"
mkdir -p "$journal_sandbox/firewall-state" "$journal_sandbox/firewall-run"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$journal_sandbox/firewall-state" \
TAILNET_KEEPER_RUNTIME_DIR="$journal_sandbox/firewall-run" \
TAILNET_KEEPER_RULES="$PROJECT_ROOT/tailnet-keeper.pf" \
TAILNET_KEEPER_CONFIG="$journal_sandbox/absent.conf" \
TAILNET_KEEPER_PFCTL="$pfctl_fake" \
TAILNET_KEEPER_MV="$mv_failure_fake" \
bash -c '
    set -uo pipefail
    source "$1"
    load_anchor en0 utun0 >/dev/null 2>&1
    [ "$?" -ne 0 ]
    ! grep -q -- "-a $ANCHOR -f" "$2"
' _ "$KEEPER" "$journal_sandbox/pfctl-log" || fail 'firewall loaded an old runtime file after atomic publish failed'

recovery_sandbox="$journal_sandbox/recovery"
mkdir -p "$recovery_sandbox/state" "$recovery_sandbox/run"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$scutil_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -uo pipefail
    source "$1"
    find_tailscale_service_id() { printf service-id; }
    verify_tailscale_signature() { return 0; }
    RESTART_TAILSCALE_AFTER_BOOT=on
    vpn_status() { return 1; }
    ! reconcile_vpn_after_boot
    vpn_status() { printf Unknown; }
    ! reconcile_vpn_after_boot
' _ "$KEEPER" || fail 'VPN status failure or unknown state was treated as healthy'

: >"$journal_sandbox/scutil-log"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$scutil_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -uo pipefail
    source "$1"
    find_tailscale_service_id() { printf service-id; }
    verify_tailscale_signature() { return 0; }
    vpn_status() { printf Disconnected; }
    persist_recovery_state() { return 1; }
    RESTART_TAILSCALE_AFTER_BOOT=on
    reconcile_vpn_after_boot
    [ "$?" -ne 0 ]
    [ ! -s "$2" ]
' _ "$KEEPER" "$journal_sandbox/scutil-log" || fail 'VPN action ran after recovery state persistence failed'

: >"$journal_sandbox/scutil-log"
printf '{ sec = 123, usec = 0 }|starting|1\n' >"$recovery_sandbox/state/vpn-recovery"
chmod 0500 "$recovery_sandbox/state"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$scutil_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -euo pipefail
    source "$1"
    find_tailscale_service_id() { printf service-id; }
    verify_tailscale_signature() { return 0; }
    vpn_status() { printf Connected; }
    ! reconcile_vpn_after_boot 2>/dev/null
    [ -f "$VPN_RECOVERY_STATE" ]
    [ ! -e "$VPN_BOOT_STATE" ]
' _ "$KEEPER" || fail 'VPN recovery completed without a durable boot marker'
chmod 0700 "$recovery_sandbox/state"
rm -f "$recovery_sandbox/state/vpn-recovery"

# Syslog availability is not part of the recovery transaction. A logger error
# after durable completion must not turn success into a degraded health state.
logger_failure_tree="$journal_sandbox/logger-failure-tree"
cp -R "$PROJECT_ROOT/." "$logger_failure_tree/"
sed -i '' 's|readonly LOGGER=/usr/bin/logger|readonly LOGGER=/usr/bin/false|' "$logger_failure_tree/libexec/common.sh"
printf '{ sec = 123, usec = 0 }|starting|1\n' >"$recovery_sandbox/state/vpn-recovery"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$scutil_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -uo pipefail
    source "$1"
    find_tailscale_service_id() { printf service-id; }
    vpn_status() { printf Connected; }
    RESTART_TAILSCALE_AFTER_BOOT=on
    reconcile_vpn_after_boot
    result=$?
    [ "$result" -eq 0 ] &&
        [ ! -e "$VPN_RECOVERY_STATE" ] &&
        [ -s "$VPN_BOOT_STATE" ]
' _ "$logger_failure_tree/bin/tailnet-keeper" || fail 'logger failure turned completed VPN recovery into failure'
rm -rf "$logger_failure_tree"
rm -f "$recovery_sandbox/state/vpn-boot"

printf '{ sec = 123, usec = 0 }|starting\n' >"$recovery_sandbox/state/vpn-retry"
ln -s /dev/full "$recovery_sandbox/state/vpn-boot.new"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$scutil_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -euo pipefail
    source "$1"
    find_tailscale_service_id() { printf service-id; }
    verify_tailscale_signature() { return 0; }
    vpn_status() { printf Connected; }
    ! reconcile_vpn_after_boot 2>/dev/null
    [ -f "$VPN_RETRY_STATE" ]
    [ ! -e "$VPN_BOOT_STATE" ]
' _ "$KEEPER" || fail 'VPN retry completed without a durable boot marker'
chmod 0700 "$recovery_sandbox/state"

rm -f "$recovery_sandbox/state/vpn-boot.new" "$recovery_sandbox/state/vpn-recovery"
printf '{ sec = 123, usec = 0 }|starting\n' >"$recovery_sandbox/state/vpn-retry"
chflags uchg "$recovery_sandbox/state/vpn-retry"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$scutil_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -euo pipefail
    source "$1"
    find_tailscale_service_id() { printf service-id; }
    verify_tailscale_signature() { return 0; }
    vpn_status() { printf Connected; }
    # launchd relaunches while this file exists, so a removal that does not
    # take effect must not be reported as a completed reconciliation.
    ! reconcile_vpn_after_boot 2>/dev/null
    [ -f "$VPN_RETRY_STATE" ]
' _ "$KEEPER" || {
    chflags nouchg "$recovery_sandbox/state/vpn-retry" 2>/dev/null || true
    fail 'undeletable retry state was reported as a completed reconciliation'
}
chflags nouchg "$recovery_sandbox/state/vpn-retry"
rm -f "$recovery_sandbox/state/vpn-retry"

# A VPN that ignores stop requests must not keep the retry state forever. Once
# retry attempts are exhausted, record this boot, clear launch-trigger state,
# and report failure without issuing another transition.
printf '{ sec = 123, usec = 0 }|stopping|3\n' >"$recovery_sandbox/state/vpn-retry"
: >"$journal_sandbox/scutil-log"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$scutil_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -uo pipefail
    source "$1"
    find_tailscale_service_id() { printf service-id; }
    vpn_status() { printf Connected; }
    RESTART_TAILSCALE_AFTER_BOOT=on
    reconcile_vpn_after_boot
    result=$?
    first_log_size=$(wc -c <"$2")
    reconcile_vpn_after_boot
    second_result=$?
    second_log_size=$(wc -c <"$2")
    [ "$result" -ne 0 ] &&
        [ "$second_result" -ne 0 ] &&
        [ ! -e "$VPN_RETRY_STATE" ] &&
        [ "$first_log_size" -eq "$second_log_size" ]
' _ "$KEEPER" "$journal_sandbox/scutil-log" || fail 'VPN retry exhaustion was retried or forgotten on the same boot'
rm -f "$recovery_sandbox/state/vpn-boot" "$recovery_sandbox/state/vpn-recovery-failed"

# Handing the immediate ladder over to the interval retry protocol is an active
# state, not exhaustion: no failure marker, and the retry record is armed.
printf '{ sec = 123, usec = 0 }|stopping|20\n' >"$recovery_sandbox/state/vpn-recovery"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$scutil_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -uo pipefail
    source "$1"
    find_tailscale_service_id() { printf service-id; }
    vpn_status() { printf Connected; }
    RESTART_TAILSCALE_AFTER_BOOT=on
    reconcile_vpn_after_boot
    result=$?
    [ "$result" -eq 11 ] &&
        [ ! -e "$VPN_RECOVERY_STATE" ] &&
        [ ! -e "$VPN_RECOVERY_FAILURE_STATE" ] &&
        [ "$(cat "$VPN_RETRY_STATE")" = "{ sec = 123, usec = 0 }|stopping|1" ]
' _ "$KEEPER" || fail 'immediate-to-interval handoff was reported as terminal failure'
rm -f "$recovery_sandbox/state/vpn-retry" "$recovery_sandbox/state/vpn-boot"

# The full ladder must issue exactly 20 immediate plus 3 interval transitions.
printf '{ sec = 123, usec = 0 }|stopping|0\n' >"$recovery_sandbox/state/vpn-recovery"
: >"$journal_sandbox/scutil-log"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$scutil_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -uo pipefail
    source "$1"
    find_tailscale_service_id() { printf service-id; }
    vpn_status() { printf Connected; }
    RESTART_TAILSCALE_AFTER_BOOT=on
    immediate=0
    interval=0
    for _ in $(seq 1 40); do
        reconcile_vpn_after_boot
        case "$?" in
            10) immediate=$((immediate + 1)) ;;
            11) interval=$((interval + 1)) ;;
            *) break ;;
        esac
    done
    [ "$immediate" -eq 20 ] && [ "$interval" -eq 3 ]
' _ "$KEEPER" || fail 'the recovery ladder did not honour its 20 plus 3 budget'
rm -f "$recovery_sandbox/state/vpn-retry" "$recovery_sandbox/state/vpn-recovery-failed" "$recovery_sandbox/state/vpn-boot"

# A record naming no boot belongs to no boot: it must be cleared, not treated
# as dormant, or it defeats the short-circuit forever.
printf '|||\n' >"$recovery_sandbox/state/vpn-retry"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$scutil_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -uo pipefail
    source "$1"
    find_tailscale_service_id() { printf service-id; }
    vpn_status() { printf Connected; }
    RESTART_TAILSCALE_AFTER_BOOT=off
    reconcile_vpn_after_boot
    [ ! -e "$VPN_RETRY_STATE" ]
' _ "$KEEPER" || fail 'a retry record naming no boot survived reconciliation'
rm -f "$recovery_sandbox/state/vpn-retry" "$recovery_sandbox/state/vpn-boot"

# launchd relaunches while the recovery file exists. A record this protocol can
# no longer advance must be retired, not respawn the daemon every 5 seconds.
no_service_fake="$journal_sandbox/scutil-no-service"
printf '#!/bin/bash\nif [ "$1" = --nc ] && [ "$2" = list ]; then printf "* (Disconnected) 11111111-2222-3333-4444-555555555555 PPP (PPPSerial) \\"Mullvad\\" [Disabled]\\n"; exit 0; fi\nexit 0\n' >"$no_service_fake"
chmod 0755 "$no_service_fake"
printf '{ sec = 111, usec = 0 }|stopping|7\n' >"$recovery_sandbox/state/vpn-recovery"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$no_service_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -uo pipefail
    source "$1"
    RESTART_TAILSCALE_AFTER_BOOT=on
    reconcile_vpn_after_boot
    first=$?
    reconcile_vpn_after_boot
    second=$?
    [ "$first" -ne 0 ] && [ "$second" -ne 0 ] &&
        [ ! -e "$VPN_RECOVERY_STATE" ] &&
        [ ! -e "$VPN_RETRY_STATE" ]
' _ "$KEEPER" || fail 'an unresolvable VPN service left the launchd trigger armed'
rm -f "$recovery_sandbox/state/vpn-recovery-failed" "$recovery_sandbox/state/vpn-boot"

# The per-boot marker is durable, but a transiently failed removal must be
# retried; otherwise the trigger stays armed for the whole boot.
printf '{ sec = 123, usec = 0 }\n' >"$recovery_sandbox/state/vpn-recovery-failed"
printf '{ sec = 123, usec = 0 }|stopping|7\n' >"$recovery_sandbox/state/vpn-recovery"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$scutil_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -uo pipefail
    source "$1"
    RESTART_TAILSCALE_AFTER_BOOT=on
    reconcile_vpn_after_boot
    result=$?
    [ "$result" -ne 0 ] && [ ! -e "$VPN_RECOVERY_STATE" ]
' _ "$KEEPER" || fail 'a failed marker removal was never retried'
rm -f "$recovery_sandbox/state/vpn-recovery-failed" "$recovery_sandbox/state/vpn-boot"

# launchd's PathState tests existence, so a zero-byte trigger file is not
# dormant and must still be retired.
: >"$recovery_sandbox/state/vpn-recovery"
: >"$recovery_sandbox/state/vpn-retry"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$scutil_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -uo pipefail
    source "$1"
    find_tailscale_service_id() { printf service-id; }
    vpn_status() { printf Connected; }
    RESTART_TAILSCALE_AFTER_BOOT=off
    reconcile_vpn_after_boot
    [ ! -e "$VPN_RECOVERY_STATE" ] && [ ! -e "$VPN_RETRY_STATE" ]
' _ "$KEEPER" || fail 'a zero-byte launchd trigger survived reconciliation'
rm -f "$recovery_sandbox/state/vpn-boot"

# Every early return in main must first retire records from an earlier boot,
# or launchd relaunches the worker every few seconds forever.
printf 'OLDBOOT|stopping|7\n' >"$recovery_sandbox/state/vpn-recovery"
printf 'OLDBOOT|starting|2\n' >"$recovery_sandbox/state/vpn-retry"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$scutil_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -uo pipefail
    source "$1"
    prepare_runtime_state() { return 0; }
    load_config() { return 0; }
    pf_enabled() { return 1; }
    fail_safely() { return 0; }
    main
    [ "$?" -eq 22 ]
    [ ! -e "$VPN_RECOVERY_STATE" ] && [ ! -e "$VPN_RETRY_STATE" ]
' _ "$KEEPER" || fail 'an early return left a stale launchd trigger armed'
rm -f "$recovery_sandbox/state/vpn-boot"

# Corrupt persistent attempts must be converted into a bounded terminal state,
# not crash every launchd invocation on arithmetic expansion.
printf '{ sec = 123, usec = 0 }|starting|not-a-number\n' >"$recovery_sandbox/state/vpn-recovery"
: >"$journal_sandbox/scutil-log"
TAILNET_KEEPER_TESTING=1 \
TAILNET_KEEPER_STATE_DIR="$recovery_sandbox/state" \
TAILNET_KEEPER_RUNTIME_DIR="$recovery_sandbox/run" \
TAILNET_KEEPER_SCUTIL="$scutil_fake" \
TAILNET_KEEPER_SYSCTL="$sysctl_fake" \
bash -c '
    set -uo pipefail
    source "$1"
    find_tailscale_service_id() { printf service-id; }
    vpn_status() { printf Connected; }
    RESTART_TAILSCALE_AFTER_BOOT=on
    reconcile_vpn_after_boot 2>/dev/null
    first=$?
    before=$(wc -c <"$2")
    reconcile_vpn_after_boot 2>/dev/null
    second=$?
    after=$(wc -c <"$2")
    [ "$first" -ne 0 ] && [ "$second" -ne 0 ] &&
        [ ! -e "$VPN_RECOVERY_STATE" ] &&
        [ -s "$VPN_RECOVERY_FAILURE_STATE" ] &&
        [ "$before" -eq "$after" ]
' _ "$KEEPER" "$journal_sandbox/scutil-log" || fail 'malformed VPN recovery state bypassed the attempt bound'

TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_CODESIGN="$codesign_fake" bash -c '
    set -euo pipefail
    source "$1"
    verify_tailscale_signature /Applications/Tailscale.app
    grep -q -- "--verify --deep --strict /Applications/Tailscale.app" "$2/codesign-log"
' _ "$KEEPER" "$journal_sandbox" || fail 'Tailscale signature was displayed but not verified'

# A service mid-transition is not settled. The immediate ladder waits for it,
# and the interval ladder must too, or it acts on a moving target and burns its
# budget interrupting the transition it asked for.
assert_equal wait "$(vpn_retry_action boot-a boot-a stopping Connecting 1)" 'the interval ladder acted while the service was connecting'
assert_equal wait "$(vpn_retry_action boot-a boot-a starting Connecting 1)" 'the interval ladder acted while the service was connecting'
assert_equal wait "$(vpn_retry_action boot-a boot-a stopping Disconnecting 1)" 'the interval ladder acted while the service was disconnecting'
assert_equal wait "$(vpn_retry_action boot-a boot-a starting Disconnecting 1)" 'the interval ladder acted while the service was disconnecting'
assert_equal start "$(vpn_retry_action boot-a boot-a starting Disconnected 1)" 'the interval ladder stopped advancing on a settled service'
assert_equal stop "$(vpn_retry_action boot-a boot-a stopping Connected 1)" 'the interval ladder stopped advancing on a settled service'

# Startup order must not change the outcome. OrbStack installs interface-scoped
# default routes on bridge100/bridge101, and whether they precede or follow the
# physical default in the routing table depends only on which daemon started
# first. Interface selection therefore asks macOS for its configured service
# order instead of guessing by name or trusting routing-table order.
ORDER_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-order.XXXXXX")
cat >"$ORDER_SANDBOX/networksetup" <<'STUB'
#!/bin/bash
printf 'An asterisk (*) denotes that a network service is disabled.\n'
printf '(1) Thunderbolt Bridge\n(Hardware Port: Thunderbolt Bridge, Device: bridge0)\n\n'
printf '(2) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n\n'
printf '(3) Tailscale\n(Hardware Port: io.tailscale.ipn.macsys, Device: )\n'
STUB
chmod +x "$ORDER_SANDBOX/networksetup"

# OrbStack first, exactly as it appears when OrbStack starts before the VPN.
cat >"$ORDER_SANDBOX/table-orbstack-first" <<'TABLE'
default            link#22            UCSIg           bridge100      !
default            link#24            UCSIg           bridge101      !
default            192.168.0.1        UGdScIg               en0
default            10.0.0.1           UGdScg            bridge0
TABLE
# The same host with the physical default already present.
cat >"$ORDER_SANDBOX/table-physical-first" <<'TABLE'
default            10.0.0.1           UGdScg            bridge0
default            192.168.0.1        UGdScIg               en0
default            link#22            UCSIg           bridge100      !
TABLE

order_result_a=$(TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_NETWORKSETUP="$ORDER_SANDBOX/networksetup" \
    /bin/bash -c 'TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"; find_physical_ipv4_route <"$2"' \
    _ "$KEEPER" "$ORDER_SANDBOX/table-orbstack-first")
order_result_b=$(TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_NETWORKSETUP="$ORDER_SANDBOX/networksetup" \
    /bin/bash -c 'TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"; find_physical_ipv4_route <"$2"' \
    _ "$KEEPER" "$ORDER_SANDBOX/table-physical-first")

assert_equal '10.0.0.1 bridge0' "$order_result_a" 'startup order changed the selected uplink'
assert_equal '10.0.0.1 bridge0' "$order_result_b" 'routing-table order changed the selected uplink'

# With two eligible uplinks the OS service order decides, not whichever default
# route was installed first.
cat >"$ORDER_SANDBOX/networksetup" <<'STUB'
#!/bin/bash
printf '(1) AX88179A\n(Hardware Port: AX88179A, Device: en5)\n\n'
printf '(2) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n'
STUB
cat >"$ORDER_SANDBOX/table-wifi-first" <<'TABLE'
default            192.168.0.1        UGdScIg               en0
default            10.0.0.1           UGdScg                en5
TABLE
cat >"$ORDER_SANDBOX/table-usb-first" <<'TABLE'
default            10.0.0.1           UGdScg                en5
default            192.168.0.1        UGdScIg               en0
TABLE
for order_table in table-wifi-first table-usb-first; do
    order_ranked=$(TAILNET_KEEPER_TESTING=1 TAILNET_KEEPER_NETWORKSETUP="$ORDER_SANDBOX/networksetup" \
        /bin/bash -c 'TAILNET_KEEPER_SOURCE_ONLY=1 source "$1"; find_physical_ipv4_route <"$2"' \
        _ "$KEEPER" "$ORDER_SANDBOX/$order_table")
    assert_equal '10.0.0.1 en5' "$order_ranked" 'the higher-priority network service lost to routing-table order'
done
rm -rf "$ORDER_SANDBOX"

printf 'keeper_behavior=PASS\n'
