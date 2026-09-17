# shellcheck shell=bash
# Whether a health record describes a working transport.
#
# One definition, shared: the installer decides from it whether to roll an
# activation back, and the verifier whether to report the installation sound.
# Two copies of that policy would drift, and the one that drifted would either
# roll back a healthy install or pass a broken one.
#
# A resolver fault is the only degradation that leaves the transport intact.
# Every bypass route and the PF anchor are exactly as installed while one
# holds -- only name resolution is lost -- so reporting the installation
# broken over it would name the wrong thing, and rolling an install back would
# keep the machine on the version whose fix it is installing. That holds for
# all four resolver codes, including the two that ask to be retried; what they
# have in common is where the fault is, not whether it clears on its own.
transport_is_working() {
    local status=$1 detail=${2:-}
    [ "$status" != healthy ] || return 0
    [ "$status" = degraded ] || return 1
    case "$detail" in
        mullvad_dns_settings_unreadable) return 0 ;;
        mullvad_dns_block_holds_a_tailnet_node) return 0 ;;
        mullvad_dns_node_check_unavailable) return 0 ;;
        mullvad_dns_route_failed) return 0 ;;
    esac
    return 1
}
