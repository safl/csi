#!/usr/bin/env bash
# nosi/provision/apply.sh <variant> [--shape-only]
#
# Run the provision steps for <variant>. The variant is
# `<distro>-<version>-<shape>`, e.g.:
#
#   debian-13-headless    headless on Debian 13 (apt)
#   ubuntu-2604-headless  headless on Ubuntu 26.04 (apt)
#   ubuntu-2604-wsl       WSL2 rootfs on Ubuntu 26.04
#   ubuntu-2604-docker    OCI/container bootstrap on Ubuntu 26.04
#   fedora-44-desktop     desktop on Fedora 44 (dnf; Sway tiling stack)
#
# Steps come in three groups:
#
#   BASE_STEPS   distro/HW infrastructure every shape shares (release
#                stamp, tool installs, ssh, daemon-prune, ...). Identical
#                logic across shapes -- the part that would be pure
#                replication if every shape baked from scratch.
#   SHAPE_STEPS  the per-shape delta (Sway desktop, WSL GUI tools, LXC
#                container, Proxmox VE host; docker has no step). Each
#                self-gates on NOSI_SHAPE, so the set is safe to run
#                wholesale: only the matching one does work.
#                These steps OWN their package installs (via
#                nosi_pkg_install), so the shape is fully defined here
#                rather than half here / half in cloud-init.
#   FINAL_STEPS  metadata capture + motd, run last so they reflect the
#                final installed inventory.
#
# Layered build model: the headless base bakes once (full run: BASE +
# SHAPE + FINAL; for headless no SHAPE step does anything). desktop /
# wsl / docker are DERIVED from that baked rootfs -- cijoe's
# derive_pack copies the base qcow2, chroots in, and runs
# `apply.sh <derived-variant> --shape-only`, which skips BASE_STEPS
# (already done in the base, and several aren't chroot-safe to re-run:
# the clock step would set the host clock, dkms/uname see the host
# kernel) and runs only SHAPE + FINAL. An operator on a vanilla VM runs
# the full `apply.sh <variant>` (no flag) and gets the complete result,
# so the "apply.sh reproduces the image" invariant holds in both
# contexts.
#
# Each step is independently idempotent, so apply.sh is too. Steps that
# touch kernel cmdline / initramfs may require a reboot to take effect.

set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

# Fail-fast on first step error: a step abort means /etc/nosi/apply-ok
# is never written, the smoketest's sentinel-presence assertion fails,
# and the image is refused for publish regardless of which step died.

VARIANT=""
SHAPE_ONLY=0
for arg in "$@"; do
    case "$arg" in
    --shape-only) SHAPE_ONLY=1 ;;
    -*) nosi_die "unknown flag: $arg" ;;
    *)
        if [ -z "$VARIANT" ]; then
            VARIANT="$arg"
        else
            nosi_die "unexpected extra argument: $arg"
        fi
        ;;
    esac
done
[ -n "$VARIANT" ] || nosi_die "usage: $0 <variant> [--shape-only]   (e.g. ubuntu-2604-headless | ubuntu-2604-docker | fedora-44-desktop)"

# Shape is the trailing segment. Distro + version are carried in the
# variant name but not enforced here: lib/common.sh derives the live
# NOSI_DISTRO / NOSI_PKGMGR from /etc/os-release, so an operator-side
# `apply.sh ubuntu-2604-headless` on a different-version Ubuntu box still
# works -- the variant string is identity / catalog metadata, not a
# runtime selector.
case "$VARIANT" in
*-headless) export NOSI_SHAPE=headless ;;
*-desktop)  export NOSI_SHAPE=desktop  ;;
*-wsl)      export NOSI_SHAPE=wsl      ;;
*-docker)   export NOSI_SHAPE=docker   ;;
*-lxc)      export NOSI_SHAPE=lxc      ;;
*-proxmox)  export NOSI_SHAPE=proxmox  ;;
*)          nosi_die "variant must end in -headless, -desktop, -wsl, -docker, -lxc, or -proxmox: $VARIANT" ;;
esac

# Full variant string (e.g. "ubuntu-2604-headless") for identity-aware steps.
export NOSI_VARIANT="$VARIANT"

# Runs FIRST in BOTH modes. /etc/nosi-release captures the build
# identity (version from /opt/nosi/.nosi-version, shape/variant from the
# env apply.sh exports), so the derive re-stamps the DERIVED variant's
# identity onto the headless-baked rootfs with the same build version.
# Cheap, chroot-safe (reads a file, writes a file).
ALWAYS_FIRST=(
    05-nosi-release
)

# Infrastructure shared by every shape. 06-package-presence runs right
# after the identity stamp so a cloud-init package-install failure fails
# the bake here with the missing-tool list instead of cascading into a
# later step. Not re-run in the derive (already done in the base bake;
# several aren't chroot-safe to re-run).
BASE_STEPS=(
    04-operator-account
    06-package-presence
    07-odus-sudoers
    08-network-dhcp
    09-growroot
    10-r8125-dkms
    12-gdb-dashboard
    15-nouveau-blacklist
    20-upstream-tools
    21-shell-tools
    22-python-tools
    23-userspace-pci
    24-podman-setup
    25-iommu-cmdline
    26-daemon-prune
    27-snapd-disable
    28-ssh-config
    29-rotate-password
    30-clock-from-http
    31-root-lock
    32-firstboot-inventory
    33-serial-console
    34-netboot-ramboot-hook
    45-nosi-addons
)

# Per-shape delta. Each self-gates on NOSI_SHAPE and no-ops for the
# others, so running the whole list applies exactly one shape's work.
# The docker shape has no step here: its tools (cijoe + qemu) are in
# the base, so "docker" is purely a packaging derivation (strip +
# OCI import) handled by cijoe/scripts/derive_pack.py.
SHAPE_STEPS=(
    50-desktop-stack
    55-wsl-tools
    56-lxc-container
    60-proxmox-ve
)

# Always last: 95 installs the nosi-selfcheck health tool, 96 logs the final
# disk usage (read-only diagnostic), metadata reflects the final inventory,
# motd's presence is the at-a-glance "the whole chain ran" signal. In
# FINAL_STEPS so it runs in every path -- base, shape derive, and FreeBSD.
FINAL_STEPS=(
    95-selfcheck
    96-disk-report
    98-metadata
    99-motd
)

# FreeBSD step set. Phase 2a landed the critical path (06/08/09/28);
# Phase 2b adds the dev tooling + niceties (12/20/21/22), the
# clock/inventory steps (30/32), and the serial console (33), each with
# a FreeBSD branch. Still
# Linux-only (no FreeBSD analogue): 10-r8125-dkms, 15-nouveau-blacklist,
# 23-userspace-pci (vfio/sysfs), 24-podman-setup, 25-iommu-cmdline (grub),
# 26-daemon-prune (systemd), 27-snapd-disable, 29-rotate-password,
# 45-nosi-addons. Same group semantics as Linux: 05 first (ALWAYS_FIRST),
# 06 presence early, 98/99 last (FINAL_STEPS). FreeBSD has only the
# headless shape and no derives, so there is no FreeBSD SHAPE_STEPS set.
FREEBSD_BASE_STEPS=(
    04-operator-account
    06-package-presence
    07-odus-sudoers
    08-network-dhcp
    09-growroot
    12-gdb-dashboard
    20-upstream-tools
    21-shell-tools
    22-python-tools
    28-ssh-config
    30-clock-from-http
    31-root-lock
    32-firstboot-inventory
    33-serial-console
)

# Arch step set (headless only). Deliberately LEAN: Arch is the "minimal
# netboot base" experiment, so it runs the operator/network/ssh/serial
# infrastructure plus the dracut netboot wiring and NOTHING from the fat
# dev-tooling chain (no 10-r8125-dkms / 12 / 20 / 21 / 22 / 23 / 24 / 25;
# those need base-devel + a compiler this image intentionally omits). Same
# group semantics as the others: 05 first (ALWAYS_FIRST), 06 presence
# early, 98/99 last (FINAL_STEPS). Every step listed carries a pacman
# branch; steps not listed are simply not applicable to a minimal headless
# Arch image. Arch has only the headless shape and no derives, so there is
# no Arch SHAPE_STEPS set.
ARCH_BASE_STEPS=(
    04-operator-account
    06-package-presence
    07-odus-sudoers
    08-network-dhcp
    09-growroot
    28-ssh-config
    31-root-lock
    33-serial-console
    34-netboot-ramboot-hook
)

is_freebsd=0
[ "$NOSI_DISTRO" = "freebsd" ] && is_freebsd=1
is_arch=0
[ "$NOSI_DISTRO" = "arch" ] && is_arch=1

if [ "$is_freebsd" -eq 1 ]; then
    # FreeBSD: curated list regardless of --shape-only (no shapes/derives).
    RUN_STEPS=( "${ALWAYS_FIRST[@]}" "${FREEBSD_BASE_STEPS[@]}" "${FINAL_STEPS[@]}" )
elif [ "$is_arch" -eq 1 ]; then
    # Arch: curated lean list regardless of --shape-only (headless-only,
    # no shapes/derives).
    RUN_STEPS=( "${ALWAYS_FIRST[@]}" "${ARCH_BASE_STEPS[@]}" "${FINAL_STEPS[@]}" )
elif [ "$SHAPE_ONLY" -eq 1 ]; then
    # Derive context (chroot on a baked headless rootfs): base already
    # ran in the base bake; re-stamp identity, run only the shape delta,
    # refresh metadata + motd.
    RUN_STEPS=( "${ALWAYS_FIRST[@]}" "${SHAPE_STEPS[@]}" "${FINAL_STEPS[@]}" )
else
    RUN_STEPS=( "${ALWAYS_FIRST[@]}" "${BASE_STEPS[@]}" "${SHAPE_STEPS[@]}" "${FINAL_STEPS[@]}" )
fi

nosi_info "apply start: variant=$NOSI_VARIANT shape=$NOSI_SHAPE distro=$NOSI_DISTRO pkgmgr=$NOSI_PKGMGR shape_only=$SHAPE_ONLY"

for s in "${RUN_STEPS[@]}"; do
    script="$HERE/steps/${s}.sh"
    [ -x "$script" ] || nosi_die "missing step: $script"
    nosi_info "--- step $s ---"
    "$script"
done

# All steps completed. Write the success sentinel. The smoketest's only
# whole-chain assertion checks for this file; absence => apply.sh aborted
# somewhere => image is refused for publish.
install -d -m 0755 /etc/nosi
date -u +%Y-%m-%dT%H:%M:%SZ > /etc/nosi/apply-ok
nosi_info "apply complete: $VARIANT (shape_only=$SHAPE_ONLY; sentinel: /etc/nosi/apply-ok)"
