#!/usr/bin/env bash
# nosi/provision/steps/09-growroot.sh
#
# Grow the root partition + filesystem to fill the target disk on first
# boot -- on bare metal, where cloud-init does NOT run.
#
# Why this exists: the build VM bakes a 12 GiB image (see DISK_SIZE in
# cijoe/scripts/diskimage_build.py). On a real cloud instance cloud-init's
# growpart/resize_rootfs modules expand the rootfs to the operator's disk
# on first boot -- but a nosi image flashed to bare metal has no
# cloud-init datasource, so cloud-init self-disables and those modules
# never run. Without this step the rootfs is stuck at ~12 GiB no matter
# how large the target NVMe/SSD is. The flasher (bty) doesn't resize
# either. So nosi owns the grow itself, via systemd, exactly as it owns
# SSH host-key regen (28-ssh-config) rather than leaning on cloud-init.
#
# Mechanism: a oneshot unit runs /usr/local/sbin/nosi-growroot early in
# boot (after local-fs, root mounted rw). growpart reports NOCHANGE once
# the partition already fills the disk and the fs resize is a no-op at
# max size, so it is idempotent and a no-op on every boot after the
# first. It is best-effort: unusual layouts (LVM, whole-disk, unknown
# fstype) are logged to the journal and skipped rather than failing boot.
# This same unit also covers VMs/cloud, making cloud-init's growpart
# redundant there.
#
# Idempotent: nosi_write_if_changed rewrites only on content change;
# enable is idempotent.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 09-growroot (distro=$NOSI_DISTRO)"

if nosi_is_wsl; then
    nosi_info "WSL detected; the host owns the disk, skipping"
    exit 0
fi

nosi_require_root

# ---- FreeBSD: grow root via base rc.d/growfs ------------------------------
# FreeBSD ships /etc/rc.d/growfs which, when growfs_enable=YES, runs
# `gpart recover` + `gpart resize` on the root partition and then grows
# the filesystem (growfs for UFS, `zpool online -e` for ZFS) on boot --
# precisely the "disk is physically larger than the baked image" case,
# so no nosi-owned helper is needed. growfs_swap_size=0 stops it carving
# a swap partition out of the freed space, so root fills the whole disk
# (matches the Linux growroot intent). Fail loud if the base mechanism is
# missing rather than ship a silent-degrade stub.
if [ "$NOSI_PKGMGR" = "pkg" ]; then
    [ -r /etc/rc.d/growfs ] || nosi_die "/etc/rc.d/growfs absent; cannot grow root on first boot"
    sysrc growfs_enable="YES" >/dev/null
    sysrc growfs_swap_size="0" >/dev/null
    nosi_info "step 09-growroot done (freebsd: growfs_enable=YES via /etc/rc.d/growfs)"
    exit 0
fi

# ---- 1. ensure growpart is present ---------------------------------------
# growpart ships in cloud-guest-utils (apt) / cloud-utils-growpart (dnf).
# cloud-init usually pulls it in, but install explicitly so the unit never
# fails for a missing tool. resize2fs (e2fsprogs), xfs_growfs (xfsprogs)
# and btrfs (btrfs-progs) are already present for whichever fs roots /.
case "$NOSI_PKGMGR" in
apt) nosi_pkg_install cloud-guest-utils ;;
dnf) nosi_pkg_install cloud-utils-growpart ;;
# Arch ships growpart in cloud-guest-utils (extra). resize2fs is in
# e2fsprogs (part of Arch base), so the ext4 rootfs resize is covered.
pacman) nosi_pkg_install cloud-guest-utils ;;
esac

# ---- 2. the grow helper --------------------------------------------------
nosi_write_if_changed \
'#!/bin/sh
# Managed by nosi/provision/steps/09-growroot.sh
# Grow the root partition to fill its disk, then grow the filesystem.
# Best-effort: log + skip on layouts we do not handle; never fail boot.
set -u

log() { echo "nosi-growroot: $*"; }

src=$(findmnt -nvo SOURCE / 2>/dev/null)
fstype=$(findmnt -nvo FSTYPE / 2>/dev/null)
[ -n "$src" ] || { log "cannot determine root source device; skipping"; exit 0; }

# Only the plain-partition-on-a-disk case (the cloud-image layout).
base=$(basename "$src")
partfile="/sys/class/block/$base/partition"
parent=$(lsblk -ndo PKNAME "$src" 2>/dev/null || true)
if [ ! -r "$partfile" ] || [ -z "$parent" ]; then
    log "root ($src) is not a plain disk partition (LVM/whole-disk?); skipping"
    exit 0
fi
partnum=$(cat "$partfile")
disk="/dev/$parent"

log "growing $disk partition $partnum (root=$src fstype=$fstype)"
out=$(growpart "$disk" "$partnum" 2>&1); rc=$?
log "growpart(rc=$rc): $out"
# growpart: 0 = resized, NOCHANGE = already full (both fine); else error.
if [ "$rc" -ne 0 ] && ! printf "%s" "$out" | grep -qi NOCHANGE; then
    log "growpart failed; leaving filesystem as-is"
    exit 0
fi

udevadm settle 2>/dev/null || true

case "$fstype" in
    ext2|ext3|ext4) resize2fs "$src" || log "resize2fs failed" ;;
    xfs)            xfs_growfs / || log "xfs_growfs failed" ;;
    btrfs)          btrfs filesystem resize max / || log "btrfs resize failed" ;;
    *)              log "unhandled root fstype \"$fstype\"; partition grown, fs not resized"; exit 0 ;;
esac
log "done"
exit 0
' /usr/local/sbin/nosi-growroot 0755

# ---- 3. the oneshot unit -------------------------------------------------
nosi_write_if_changed \
'[Unit]
Description=nosi: grow root partition + filesystem to fill the disk
Documentation=man:growpart(1)
DefaultDependencies=no
After=local-fs.target
Before=basic.target shutdown.target
Conflicts=shutdown.target
ConditionPathIsReadWrite=/

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nosi-growroot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
' /etc/systemd/system/nosi-growroot.service 0644

systemctl daemon-reload 2>/dev/null || true
systemctl enable nosi-growroot.service 2>/dev/null \
    || nosi_warn "could not enable nosi-growroot.service"

nosi_info "step 09-growroot done"
