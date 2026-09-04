# Contributing

Run the full local gate before opening a pull request:

```sh
make check
```

Keep changes within the existing ownership boundaries. The worker may edit only its PF child anchor, its state directory, and routes recorded in its journal. Tests must reproduce a failure before production code changes.

Pull requests should state:

- the macOS, Mullvad, and Tailscale variants tested
- the failing behavior and regression test
- the PF and route state before and after the change
- whether OrbStack was running during the test

Remove account IDs, node keys, auth keys, device names, and private tailnet addresses from fixtures and logs.
