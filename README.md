# tailnet-keeper

`tailnet-keeper` keeps standalone Mullvad, Tailscale, and OrbStack working together on macOS. Mullvad remains the default route. Tailscale coordination, logging, DERP, and STUN traffic uses the physical network, while tailnet payload stays on the Tailscale interface.

The project targets the standalone Mullvad app and the Tailscale macOS Network Extension. It does not install either VPN.

## Requirements

- macOS with Packet Filter enabled
- Mullvad VPN with autoconnect enabled
- Tailscale from the App Store or standalone macOS package
- Administrator access for installation and removal
- Optional: OrbStack

Tested locally with macOS 26.6, Mullvad 2026.4, Tailscale 1.102.3, and OrbStack.

## Install

```sh
git clone https://github.com/andredezzy/tailnet-keeper.git
cd tailnet-keeper
make test
sudo ./scripts/install.sh
sudo ./scripts/verify.sh
```

The installer validates the payload, proves its direct `lockf` parent holds the exact shared lock inode, and snapshots sources under that lock so a concurrent rewrite cannot reach a privileged target. The snapshot lives in a private transaction directory outside rollback-managed state. Activation waits for a healthy read-back; failed activation attempts and verifies restoration of the previous files and service.

## Boot recovery

Most machines should keep the default setting:

```text
RESTART_TAILSCALE_AFTER_BOOT=off
```

If Tailscale reports `Connected` after boot but has no data plane, install with one bounded Network Extension recycle per boot:

```sh
sudo ./scripts/install.sh --enable-boot-recovery
```

Run the installer with `--disable-boot-recovery` to turn it off. An upgrade without either flag preserves the current setting.

The recovery state survives process crashes. The keeper performs at most 20 immediate recovery attempts, then at most three retries on the five-minute service interval. Active retries remain `recovering`; corrupt counters become terminal failure rather than arithmetic loops. A non-triggering marker keeps terminal health degraded without more transition attempts until the next boot.

## Verify a tailnet host and OrbStack

```sh
sudo ./scripts/verify.sh --target 100.64.0.10 --ports 22,443 --check-orbstack
```

Replace the example address and ports with your own node. The verifier does not print tailnet identity or keys.

## Remove

```sh
sudo ./scripts/uninstall.sh
```

The default removal restores keeper-owned routes and preserves configuration, state, and backups. Inspect modified managed files before using `--force`. Add `--purge` to remove preserved local state.

## Design boundaries

- The root LaunchDaemon grants no shell privileges to unprivileged users.
- The keeper edits only `com.apple/io.github.andredezzy.tailnet-keeper`.
- It does not reload or flush the main PF ruleset.
- Inbound tailnet rules terminate at the local Tailscale interface address. The project does not forward tailnet traffic into OrbStack guests.
- DERP updates validate signed Tailscale CLI output, stage routes, replace PF tables, commit state, then retire stale routes. A failed transaction attempts and verifies restoration of live tables, caches, journal, and changed routes. Incomplete rollback returns a distinct failure and retains snapshots.

Read [ARCHITECTURE.md](ARCHITECTURE.md) and [SECURITY.md](SECURITY.md) before using this under a strict leak-prevention threat model.

## Prior work

[tobomobo/mullvad-tailscale-macos](https://github.com/tobomobo/mullvad-tailscale-macos) addresses the same VPN pairing with a different design. This repository shares no source code with that project. It adds physical transport routing, dual-stack DERP transactions, crash-safe boot recovery, and OrbStack preservation checks.

## References

- [Tailscale firewall ports and service ranges](https://tailscale.com/docs/reference/faq/firewall-ports)
- [Tailscale interoperability with other VPNs](https://tailscale.com/docs/reference/faq/other-vpns)
- [Mullvad macOS split-tunneling tracker](https://github.com/mullvad/mullvadvpn-app/issues/3039)

Licensed under the [MIT License](LICENSE).
