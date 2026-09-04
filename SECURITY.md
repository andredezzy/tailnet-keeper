# Security

## Privilege model

The installer and uninstaller require one administrator authorization. The installed worker runs as a root LaunchDaemon and exposes no passwordless `sudo` commands. Program files, configuration, state, and the install manifest use fixed ownership and modes.

The worker calls system tools through absolute paths. It accepts DERP data only from the signed Tailscale app binary owned by `root:wheel` and rejects a group-writable or world-writable binary. `scripts/verify.sh` validates exact Mullvad and OrbStack CLI links and vendor signatures, then executes Tailscale, Mullvad, OrbStack, and Docker as the logged-in console user. User-managed application code is never executed with verifier root privileges.

## Network boundary

The physical bypass includes only Tailscale infrastructure:

- coordination: `192.200.0.0/24`, `2606:b740:49::/48`
- logging: `199.165.136.0/24`, `2606:b740:1::/48`
- DERP addresses from `tailscale debug derp-map`
- DERP TCP 80/443 and STUN UDP 3478

Tailscale may use outbound UDP from source port 41641 for direct tunnels. This project does not add a broad physical-interface UDP exception for that traffic. Direct paths continue to depend on the VPNs and host firewall accepting them; DERP remains the fallback.

Mullvad still controls the default route and its kill-switch policy. The bypass lets Tailscale infrastructure avoid that default. It does not prove resistance to every future macOS, Mullvad, or Tailscale change.

## Local traffic

Inbound tailnet traffic can terminate only at the current Tailscale interface address. The rules do not authorize forwarding to LAN devices or OrbStack guests. Add no forwarding rule without a separate threat model and test suite.

## Update and removal

The installer serializes install and removal through a private root-owned transaction directory at `/var/db/tailnet-keeper-transactions`. The re-executed child accepts its marker only when its direct `lockf` parent has the exact lock inode open and a competing acquisition fails. Source snapshots live there so recovery can replace `/var/db/tailnet-keeper` without deleting the payload it still needs. Activation waits for fresh health and verifies rollback on failure. An incomplete rollback exits with status `2` and retains its transaction data. The manifest records SHA-256 for each managed file.

The uninstaller revalidates the private transaction directory before locking, then validates manifest ownership, mode, hash syntax, and every path against a compiled allowlist. The manifest is parsed by fixed-width hash prefix, so a managed path containing spaces stays exact. Every managed-path ancestor must be real. The resumable-removal marker must be a protected regular file and is published atomically, so a symlink cannot become a privileged truncation target. `--force` bypasses content hash mismatches only.

Interrupted-install recovery accepts a recorded backup path only when it names a real generated backup directory, so recorded metadata cannot direct deletion elsewhere. A successful install clears any interrupted-removal marker, and rollback restores it alongside the manifest, so a failed reinstall cannot leave a partial removal unresumable. The root verifier sources the keeper in a mode that suppresses its auto-run without making tool paths environment-overridable.

A removal that cannot delete every managed file exits non-zero and keeps the manifest, so rerunning the uninstaller resumes and completes it. The manifest is removed before its marker, because a marker that outlived the manifest would leave the removal unresumable and that failure is deliberately not bypassable with `--force`.

## Reporting a vulnerability

Do not open a public issue for a route, PF, installer, or privilege bug that could expose traffic or produce root code execution. Use GitHub's private vulnerability reporting for this repository.

Include the macOS, Mullvad, Tailscale, and tailnet-keeper versions; installation source; expected behavior; observed behavior; and a minimal reproduction. Remove account IDs, node keys, auth keys, device names, and private tailnet addresses from logs.
