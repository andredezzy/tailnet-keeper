# shellcheck shell=bash
# The keeper's modules, read from the one list that has to be right.
#
# A module the entrypoint does not source does nothing at runtime, whatever
# any other list says, so the installer, the uninstaller and the verifier take
# their enumeration from it rather than each repeating it. Adding a module is
# adding a file and one source line; forgetting the rest is no longer possible
# because there is no rest. Before this, a module missing from the installer's
# copy of the list was simply absent at runtime and nothing failed loudly.
#
# The source lines stay literal rather than becoming an array the scripts
# could read directly, because shellcheck follows them to lint the modules
# through the entrypoint that sources them.
keeper_modules() {
    local entrypoint=$1 modules
    [ -f "$entrypoint" ] && [ ! -L "$entrypoint" ] || return 1
    modules=$(/usr/bin/awk -F'/' '
        /^source "\$LIBEXEC_DIR\/[A-Za-z0-9._-]+"$/ {
            name = $2
            sub(/"$/, "", name)
            print name
        }
    ' "$entrypoint") || return 1
    # An entrypoint that sources nothing is a file this reader no longer
    # understands, not a keeper with no modules.
    [ -n "$modules" ] || return 1
    printf '%s\n' "$modules"
}
