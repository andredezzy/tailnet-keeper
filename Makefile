SHELL := /bin/bash
SHELLCHECK ?= shellcheck

.PHONY: test lint check

test:
	@./tests/run.sh

# libexec modules are linted through the entrypoint that sources them, so
# shared state is analysed where it is actually assigned.
lint:
	@$(SHELLCHECK) --severity=warning --source-path=SCRIPTDIR/.. -x \
		bin/tailnet-keeper scripts/*.sh tests/*.sh
	@/usr/bin/plutil -lint launchd/io.github.andredezzy.tailnet-keeper.plist >/dev/null

check: test lint
