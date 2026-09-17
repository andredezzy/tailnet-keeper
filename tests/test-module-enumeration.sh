#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tailnet-keeper-modules.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# shellcheck source=../scripts/modules.sh
source "$PROJECT_ROOT/scripts/modules.sh"

# The reader answers from the entrypoint's own source lines, in their order.
listed=$(keeper_modules "$PROJECT_ROOT/bin/tailnet-keeper") ||
    fail 'the entrypoint sourced no modules'
for module in $listed; do
    [ -f "$PROJECT_ROOT/libexec/$module" ] ||
        fail "the entrypoint sources $module, which is not in libexec"
done
on_disk=$(cd "$PROJECT_ROOT/libexec" && printf '%s\n' *.sh | sort)
[ "$(sort <<<"$listed")" = "$on_disk" ] ||
    fail 'libexec holds a module the entrypoint does not source, or the reverse'

# An entrypoint that sources nothing is a file this reader no longer
# understands, not a keeper with no modules, so it is refused rather than
# answered with an empty set that would install nothing.
printf '#!/usr/bin/env bash\necho hello\n' >"$SANDBOX/silent"
keeper_modules "$SANDBOX/silent" >/dev/null 2>&1 &&
    fail 'an entrypoint with no source lines was read as having no modules'
keeper_modules "$SANDBOX/absent" >/dev/null 2>&1 &&
    fail 'a missing entrypoint was read as having no modules'

# Adding a module is adding a file and one source line. Nothing else knows
# the list, so nothing else can be forgotten.
PROJECT_COPY="$SANDBOX/project"
mkdir -p "$PROJECT_COPY"
cp -R "$PROJECT_ROOT/bin" "$PROJECT_ROOT/libexec" "$PROJECT_ROOT/scripts" \
      "$PROJECT_ROOT/launchd" "$PROJECT_COPY/"
cp "$PROJECT_ROOT/tailnet-keeper.pf" "$PROJECT_ROOT/tailnet-keeper.conf.example" "$PROJECT_COPY/"

printf '# A module that exists only to be installed.\nprobe_module() { return 0; }\n' \
    >"$PROJECT_COPY/libexec/probe.sh"
chmod 644 "$PROJECT_COPY/libexec/probe.sh"
printf '# shellcheck source=../libexec/probe.sh\nsource "$LIBEXEC_DIR/probe.sh"\n' \
    >>"$PROJECT_COPY/bin/tailnet-keeper"

DEST="$SANDBOX/dest"
mkdir -p "$DEST"
DESTDIR="$DEST" "$PROJECT_COPY/scripts/install.sh" >"$SANDBOX/install.log" 2>&1 ||
    { cat "$SANDBOX/install.log" >&2; fail 'installing an added module failed'; }

# macOS resolves /var to /private/var, and the manifest records the resolved
# path, so the entry is matched on its tail rather than on DESTDIR.
MODULE_DIR="$DEST/usr/local/libexec/tailnet-keeper"
MANIFEST="$DEST/var/db/tailnet-keeper/install-manifest"
[ -f "$MODULE_DIR/probe.sh" ] ||
    fail 'a module added to the entrypoint alone was not installed'
grep -q 'libexec/tailnet-keeper/probe\.sh$' "$MANIFEST" ||
    fail 'an installed module was left out of the manifest'

# Removing the source line removes it from everything the scripts publish.
grep -v 'probe\.sh' "$PROJECT_COPY/bin/tailnet-keeper" >"$SANDBOX/entrypoint"
cat "$SANDBOX/entrypoint" >"$PROJECT_COPY/bin/tailnet-keeper"
rm "$PROJECT_COPY/libexec/probe.sh"
DESTDIR="$DEST" "$PROJECT_COPY/scripts/install.sh" >"$SANDBOX/reinstall.log" 2>&1 ||
    { cat "$SANDBOX/reinstall.log" >&2; fail 'reinstalling without the module failed'; }
if grep -q 'probe\.sh' "$MANIFEST"; then
    fail 'a module removed from the entrypoint stayed in the manifest'
fi

# The file itself is left behind. The installer publishes the current set and
# has never swept a module the previous install published, so a module dropped
# from the entrypoint stays on disk, inert and unlisted. Recorded here so the
# gap is stated rather than assumed closed; removing it means deleting from a
# root-owned path, which the previous manifest could bound but this change
# does not attempt.
[ -e "$MODULE_DIR/probe.sh" ] ||
    fail 'orphan sweeping was added without updating this expectation'

printf 'module_enumeration=PASS\n'
