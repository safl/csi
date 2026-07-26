# shellcheck shell=bash
# nosi/provision/lib/common.sh
#
# Sourced by every step under provision/steps/. Provides distro detection,
# a thin package-manager wrapper, logging, and small idempotency helpers.
#
# Steps are written to be:
#   * standalone (executable on their own, no apply.sh required)
#   * idempotent (running twice does nothing the second time)
#   * cross-distro where the work is genuinely the same (DKMS, modprobe.d,
#     systemd units, /etc/profile.d snippets); per-distro otherwise.
#
# Source from a step with:
#   . "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

set -euo pipefail

# ---- distro detection ------------------------------------------------------
# NOSI_DISTRO is one of: debian, ubuntu, fedora, arch, freebsd.
# NOSI_PKGMGR is one of: apt, dnf, pacman, pkg.
# Steps that need finer granularity (e.g. trixie vs noble) can read /etc/os-release directly.

nosi_detect_distro() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        NOSI_DISTRO="${ID:-unknown}"
        NOSI_DISTRO_VERSION="${VERSION_ID:-unknown}"
    else
        NOSI_DISTRO="unknown"
        NOSI_DISTRO_VERSION="unknown"
    fi

    # FreeBSD's /etc/os-release is a symlink to /var/run/os-release, which
    # rc.d/os-release regenerates at boot; if apply.sh runs before that is
    # populated, uname is authoritative so detection never dies on FreeBSD.
    if [ "$NOSI_DISTRO" = "unknown" ] && [ "$(uname -s)" = "FreeBSD" ]; then
        NOSI_DISTRO="freebsd"
        NOSI_DISTRO_VERSION="$(uname -r | sed 's/-.*//')"   # 14.4-RELEASE -> 14.4
    fi

    case "$NOSI_DISTRO" in
        debian|ubuntu) NOSI_PKGMGR=apt ;;
        fedora)        NOSI_PKGMGR=dnf ;;
        arch)          NOSI_PKGMGR=pacman ;;
        freebsd)       NOSI_PKGMGR=pkg ;;
        *) nosi_die "unsupported distro: $NOSI_DISTRO (need debian, ubuntu, fedora, arch, or freebsd)" ;;
    esac

    export NOSI_DISTRO NOSI_DISTRO_VERSION NOSI_PKGMGR
}

# ---- logging ---------------------------------------------------------------

nosi_info() { printf '[nosi] %s\n' "$*"; }
nosi_warn() { printf '[nosi] WARN: %s\n' "$*" >&2; }
nosi_die()  { printf '[nosi] FATAL: %s\n' "$*" >&2; exit 1; }

# ---- environment guards ----------------------------------------------------

nosi_require_root() {
    [ "$(id -u)" -eq 0 ] || nosi_die "must run as root (use sudo)"
}

# WSL has no real kernel headers and DKMS is meaningless. Steps that build
# kernel modules should bail early on WSL. Guard the /proc read so the grep
# never trips `set -e` on a kernel without procfs (e.g. FreeBSD).
nosi_is_wsl() {
    [ -r /proc/version ] || return 1
    grep -qi microsoft /proc/version 2>/dev/null
}

# ---- package manager wrapper ----------------------------------------------
# Synchronous, non-interactive install. Idempotent in the sense that apt/dnf
# already no-op on already-installed packages.

nosi_pkg_install() {
    [ "$#" -gt 0 ] || return 0
    case "$NOSI_PKGMGR" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
        dnf) dnf install -y "$@" ;;
        # --needed so an already-current package is not needlessly
        # reinstalled (pacman -S otherwise re-downloads + re-extracts it).
        # No -y flag exists; --noconfirm is the non-interactive equivalent.
        pacman) pacman -S --needed --noconfirm "$@" ;;
        pkg) ASSUME_ALWAYS_YES=yes pkg install -y "$@" ;;
        *)   nosi_die "no package manager wired for $NOSI_PKGMGR" ;;
    esac
}

# Is a package installed? Returns 0 yes / 1 no.
nosi_pkg_installed() {
    case "$NOSI_PKGMGR" in
        apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed" ;;
        dnf) rpm -q "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Qq "$1" >/dev/null 2>&1 ;;
        pkg) pkg info -e "$1" >/dev/null 2>&1 ;;
        *)   return 1 ;;
    esac
}

# ---- grub kernel cmdline ---------------------------------------------------

# Append a space-separated token string to GRUB_CMDLINE_LINUX in
# /etc/default/grub, then regenerate grub. Handles both double- and
# single-quoted values and leaves GRUB_CMDLINE_LINUX_DEFAULT untouched.
# Deciding WHAT to add (idempotency) is the caller's job; this performs only
# the shared append plus update-grub, so the brittle sed lives in exactly one
# place rather than copied across the cmdline steps (iommu, serial console).
# apt/grub systems only: the dnf path uses grubby, which has no such file.
nosi_grub_cmdline_add() {
    local grub=/etc/default/grub add="$*"
    [ -n "$add" ] || return 0
    if grep -q '^GRUB_CMDLINE_LINUX=' "$grub"; then
        sed -i -E "s@^(GRUB_CMDLINE_LINUX=)([\"'])(.*)\2[[:space:]]*\$@\1\2\3 ${add}\2@" "$grub"
    else
        printf '\nGRUB_CMDLINE_LINUX="%s"\n' "$add" >> "$grub"
    fi
    update-grub
}

# ---- idempotency helpers ---------------------------------------------------

# Write $1 contents to $2 with mode $3, but only if contents differ. Useful
# to avoid touching mtimes on /etc files that other tools watch.
nosi_write_if_changed() {
    local content="$1" path="$2" mode="${3:-0644}"
    if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
        return 0
    fi
    # `install -D` (auto-create parent dirs) is GNU-only; FreeBSD's install
    # lacks it. mkdir -p + chmod is equivalent and portable.
    mkdir -p "$(dirname "$path")"
    printf '%s' "$content" > "$path"
    chmod "$mode" "$path"
}

# Auto-detect on source. Callers can re-run if they need to refresh.
nosi_detect_distro
