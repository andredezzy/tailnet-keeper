# Troubleshooting

Run the project verifier first:

```sh
sudo ./scripts/verify.sh
```

## Read health

```sh
sudo cat /var/db/tailnet-keeper/health
```

`status=healthy` means the last reconciliation completed. `status=recovering` means the opt-in boot recovery is between stop and connected. `status=degraded` includes a stable `detail` code for the failed gate.

## Inspect launchd

```sh
sudo launchctl print system/io.github.andredezzy.tailnet-keeper
```

The worker exits between runs. `state = not running` is normal when the last exit code is zero and health is current.

## Inspect PF without changing it

```sh
sudo pfctl -a com.apple/io.github.andredezzy.tailnet-keeper -sr
sudo pfctl -a com.apple/io.github.andredezzy.tailnet-keeper -t tailscale_derp -T show
sudo pfctl -a com.apple/io.github.andredezzy.tailnet-keeper -t tailscale_derp6 -T show
```

Do not run `pfctl -F all` or reload `/etc/pf.conf`. Those commands can remove Mullvad and OrbStack state.

## Tailscale connects but cannot reach peers after boot

Confirm the backend and Network Extension state:

```sh
/Applications/Tailscale.app/Contents/MacOS/Tailscale status
systemextensionsctl list | grep io.tailscale.ipn.macsys.network-extension
```

Enable the bounded boot recovery only after reproducing the connected-without-data-plane state. See [README.md](README.md#boot-recovery).

## DERP refresh fails

The keeper retains the last-known-good tables and routes when a candidate fails validation. Check the stable detail code and unified log:

```sh
log show --last 15m --predicate 'process == "tailnet-keeper" OR senderImagePath CONTAINS "tailnet-keeper"'
```

A failure with no valid cache triggers fail-closed cleanup.

## Removal stops part-way

If the uninstaller reports that some managed files could not be removed, it keeps the manifest so the removal stays resumable. Clear whatever blocks the deletion, then run the same uninstall command again to finish it.

## Verification rejects a third-party CLI

`scripts/verify.sh` requires the exact Mullvad and OrbStack CLI links and expected vendor signatures. It executes application CLIs as the logged-in console user, not root. Inspect the reported path and application signature rather than relaxing the check:

```sh
ls -lde /usr/local/bin/mullvad
codesign --verify --deep --strict "/Applications/Mullvad VPN.app"
```

## OrbStack stops working

Check OrbStack before changing PF:

```sh
orb status
sudo pfctl -a com.apple.internet-sharing -sr
```

The keeper never writes that anchor. An empty anchor while OrbStack reports running points outside this project's owned PF state.
