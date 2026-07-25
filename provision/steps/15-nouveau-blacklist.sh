#!/usr/bin/env bash
# nosi/provision/steps/15-nouveau-blacklist.sh
#
# Blacklist the in-kernel `nouveau` (Linux's reverse-engineered NVIDIA
# driver) on every nosi image. Always-on, not gated on shape or distro.
#
# Why always-on:
#
#   * nouveau and the proprietary NVIDIA driver are mutually exclusive.
#     Any future cudadev install on top of this image hits a hard
#     conflict if nouveau is loaded -- the proprietary stack refuses
#     to bind. Pre-blacklisting removes the post-flash gotcha.
#
#   * nouveau-rendering-the-system-unusable on mixed-vendor hosts is a
#     real failure mode: a server with an AMD compute card plus a tiny
#     NVIDIA card for display output will, by default, let nouveau
#     drive the NVIDIA card and that driver can wedge or wreck the box
#     under any non-trivial display load.
#
#   * On headless servers nouveau provides nothing useful (no compute,
#     no remote display) but happily consumes a kernel module slot,
#     fights for PCI BARs, and adds boot noise.
#
# It costs nothing to load: nouveau still ships in the kernel package,
# the blacklist just refuses to bind. Operators who actively want
# nouveau (a workstation running a desktop on an NVIDIA card without
# the proprietary driver) can `rm /etc/modprobe.d/nosi-nouveau-
# blacklist.conf` and update-initramfs to opt back in.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 15-nouveau-blacklist"
nosi_require_root

install -d -m 0755 /etc/modprobe.d
nosi_write_if_changed \
'# Managed by nosi/provision/steps/15-nouveau-blacklist.sh
# Always blacklist nouveau across all nosi images. See the step script
# for the full rationale; tl;dr: nouveau conflicts with the
# proprietary NVIDIA driver, can wedge mixed-vendor hosts, and gives
# headless servers nothing useful.
blacklist nouveau
options nouveau modeset=0
' /etc/modprobe.d/nosi-nouveau-blacklist.conf 0644

# Regenerate initramfs so a boot-time module load doesn't bypass the
# blacklist. Cloud-init kernels typically don't include nouveau in
# initramfs, but a kernel-upgrade postinst on the operator's box may
# re-add it; the blacklist file is honoured by the rebuilt initramfs.
#
# Pick the generator by what is actually installed, not by package
# manager: apt images may run either initramfs-tools OR dracut. On
# Ubuntu-26.04 dracut is the apt-native generator; on headless netboot
# images step 34 later purges initramfs-tools and leaves dracut sole. If
# we blindly called ``update-initramfs`` on a dracut-only apt box the
# command would be missing and this regen would silently no-op (the
# blacklist still lands via /etc/modprobe.d, but the initrd copy would be
# stale). Detect dracut the same way step 34 does and prefer it.
if command -v dracut >/dev/null 2>&1 && [ -d /etc/dracut.conf.d ]; then
    dracut --force 2>/dev/null \
        || nosi_warn "dracut --force failed (initramfs not regenerated)"
elif command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u 2>/dev/null \
        || nosi_warn "update-initramfs -u failed (initramfs not regenerated)"
else
    nosi_warn "no initramfs generator found (dracut / update-initramfs); skipping regen"
fi

nosi_info "step 15-nouveau-blacklist done"
