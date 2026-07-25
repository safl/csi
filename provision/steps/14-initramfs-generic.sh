#!/usr/bin/env bash
# nosi/provision/steps/14-initramfs-generic.sh
#
# Build a GENERIC (not host-only) initramfs on Fedora so a flashed image
# boots on ANY hardware.
#
# Fedora's dracut defaults to hostonly=yes: the initramfs it builds during
# our QEMU bake captures only the build VM's storage/driver profile plus a
# baked root cmdline (you can see the giveaway etc/cmdline.d/00-btrfs.conf
# inside the image's initramfs). nosi images are flashed to arbitrary bare
# metal (NVMe / AHCI / RAID HBAs / odd carriers), so a host-only initramfs
# can fail to find or mount the root filesystem on a box outside that
# profile and kernel-panic at boot ("unable to mount root fs"). It boots on
# hardware close to the build VM and panics on the rest -- which is exactly
# the "boots on some systems, panics on others" report this fixes.
#
# Debian / Ubuntu / Raspberry Pi OS already build a generic initramfs
# (update-initramfs defaults to MODULES=most), so this is dnf/Fedora-only.
#
# The non-dnf skip stays correct even though headless apt netboot images
# now use dracut too: at step-14 time dracut isn't installed on apt yet
# (step 34 installs it), so this step could not regenerate a dracut initrd
# here even if it tried. Step 34 therefore writes its OWN copy of the
# 00-nosi-generic.conf below (same content) right before it regenerates on
# apt. Non-netboot apt images keep initramfs-tools, which is already
# generic via MODULES=most, so they need nothing from this step either.
#
# Two parts: drop hostonly="no" into dracut.conf.d so EVERY later dracut
# run is generic (this bake's later steps, kernel upgrades on the running
# box, and the desktop derive's kernels -- the conf travels in the rootfs);
# then regenerate-all once to rebuild the host-only initramfs the cloud base
# image already shipped. Runs before 15-nouveau-blacklist so that step's
# dracut --force is generic too.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 14-initramfs-generic"
nosi_require_root

if [ "${NOSI_PKGMGR:-}" != "dnf" ]; then
    nosi_info "non-dnf (initramfs already generic via update-initramfs); skipping"
    exit 0
fi

install -d -m 0755 /etc/dracut.conf.d
nosi_write_if_changed \
'# Managed by nosi/provision/steps/14-initramfs-generic.sh
# Build a generic initramfs (all drivers), not host-only: nosi images are
# flashed to arbitrary bare metal, so the initramfs must not assume the
# build VM hardware. See the step script for the full rationale.
hostonly="no"
' /etc/dracut.conf.d/00-nosi-generic.conf 0644

# Rebuild every installed kernel initramfs as generic (the cloud base image
# shipped host-only ones). Best-effort: a regen failure warns rather than
# aborting the bake; --no-hostonly forces generic even if the conf above is
# somehow not picked up.
if command -v dracut >/dev/null 2>&1; then
    dracut --regenerate-all --no-hostonly --force 2>/dev/null \
        || nosi_warn "dracut --regenerate-all failed (initramfs may stay host-only)"
fi

nosi_info "step 14-initramfs-generic done"
