#!/bin/sh
# dracut mount hook for pixie nbdboot (priority 90).
#
# Runs after ``pixie-nbdboot-online.sh`` has attached /dev/nbd0 and
# after dracut's built-in mount hooks have (attempted to) mount
# /sysroot. Two modes gated on ``pixie.persist=1`` (or the legacy
# ``bty.persist=1``):
#
#   Ephemeral (default): mount the picked partition RO at
#   /run/pixie-lower, tmpfs at /run/pixie-upper, overlayfs at
#   /sysroot. Writes on the target go to RAM and vanish on reboot.
#
#   Persistent (``pixie.persist=1``): mount /dev/nbd0 RW directly at
#   /sysroot. Pixie's persist path spawns qemu-nbd with
#   ``--offset=<partition_1_start_bytes>`` so /dev/nbd0 is the ext4
#   partition at offset 0 (same shape ephemeral gets from nbdkit's
#   ``--filter=partition``). Writes land in the underlying qcow2 and
#   survive reboots. The image's baked /etc/fstab entries for /boot
#   and /boot/efi refer to LABELs / UUIDs on the whole-disk view we
#   are NOT exposing here; systemd-fstab-generator will fail those
#   with a warning and boot proceeds -- /boot on the target is
#   inert in nbdboot mode anyway (pixie serves the kernel).
#
# Both modes:
#
#   * Mask systemd-networkd + NetworkManager + cloud-init on the
#     pivoted rootfs so userspace does not tear down the NIC the
#     initrd owns.
#   * Propagate DNS from dracut's netroot config.
#   * POST a status ping so the pixie appliance can log nbdboot.up.

# shellcheck disable=SC1091
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

_pixie_trace() { echo "pixie-nbdboot: $*" >/dev/kmsg 2>/dev/null || echo "pixie-nbdboot: $*"; }
_pixie_die() {
    _pixie_trace "FATAL: $*"
    _pixie_status "mount.died:$*"
    type emergency_shell >/dev/null 2>&1 && emergency_shell "pixie-nbdboot: $*"
    exec sleep 2147483647
}

# Prefer ``pixie.*`` cmdline names; fall back to ``bty.*`` for legacy
# bundles booted against a bty appliance. Same payload; identical
# semantics.
_pixie_getarg() {
    key="$1"
    val="$(getarg "pixie.${key}=")"
    [ -n "$val" ] || val="$(getarg "bty.${key}=")"
    echo "$val"
}

# Best-effort HTTP status ping. Traces to /dev/kmsg vanish below the
# console loglevel on IPMI SoL, so this ships boot-phase progress to
# pixie's event log via ``POST /pxe/<mac>/status`` -- the same shape
# ``nbdboot.up`` uses. Silent on failure.
_pixie_status() {
    _srv="$(_pixie_getarg server)"
    _mac="$(_pixie_getarg mac)"
    [ -n "$_srv" ] && [ -n "$_mac" ] || return 0
    wget -q -O /dev/null --timeout=3 --tries=1 \
        --post-data="status=$1" \
        "${_srv}/pxe/${_mac}/status" 2>/dev/null || true
}

nbd_url="$(_pixie_getarg nbd)"
[ -n "$nbd_url" ] || return 0
overlay_size="$(_pixie_getarg overlay_size)"
persist="$(_pixie_getarg persist)"
: "${overlay_size:=10G}"

_pixie_status "mount.started"

[ -b /dev/nbd0 ] || _pixie_die "mount hook: /dev/nbd0 missing (online hook didn't run?)"

# Pixie serves /dev/nbd0 as the ext4 root partition directly in both
# modes: the ephemeral path via nbdkit ``--filter=partition
# partition=1``, the persist path via ``qemu-nbd
# --offset=<partition_1_start_bytes>`` on the qcow2 wrapping the
# whole raw disk. Either way the mount hook just deals with
# /dev/nbd0 and no partition scan is needed.
root_part=/dev/nbd0
_pixie_trace "mount hook: root_part=${root_part}"

# dracut may have partially mounted /sysroot already from an earlier
# mount hook trying the baked root=UUID; unmount cleanly so our own
# mount lands on a clean directory. ``umount`` on a not-mounted path
# returns non-zero which we ignore; ``mountpoint`` isn't always in
# the initrd's busybox, so we can't gate on it.
umount /sysroot 2>/dev/null || true

if [ "$persist" = "1" ]; then
    # ---- persistent path ---------------------------------------------
    _pixie_trace "mount hook: persist=1; mount rw ${root_part} -> /sysroot"
    _pixie_status "mount.persist_start"
    mkdir -p /sysroot
    mnt_rc=1
    for fstype in ext4 xfs btrfs; do
        _pixie_trace "mount hook: mount -t ${fstype} -o rw ${root_part} -> /sysroot"
        if mount -t "$fstype" -o rw "$root_part" /sysroot 2>/dev/null; then
            mnt_rc=0
            _pixie_trace "mount hook: persist rw mount succeeded (${fstype})"
            break
        fi
    done
    [ "$mnt_rc" -eq 0 ] || _pixie_die "persist: failed to mount ${root_part} rw"
    upper=/sysroot
    _pixie_status "mount.persist_mounted"
else
    # ---- ephemeral path ----------------------------------------------
    _pixie_status "mount.ephemeral_start"
    mkdir -p /run/pixie-lower /run/pixie-upper
    mnt_rc=1
    for fstype in ext4 xfs btrfs auto; do
        _pixie_trace "mount hook: mount -t ${fstype} -o ro ${root_part} -> /run/pixie-lower"
        if mount -t "$fstype" -o ro "$root_part" /run/pixie-lower 2>/dev/null; then
            mnt_rc=0
            break
        fi
    done
    [ "$mnt_rc" -eq 0 ] || _pixie_die "failed to mount ${root_part}"

    _pixie_trace "mount hook: tmpfs(${overlay_size}) -> /run/pixie-upper"
    mount -t tmpfs -o "size=${overlay_size}" tmpfs /run/pixie-upper \
        || _pixie_die "failed to mount tmpfs"
    mkdir -p /run/pixie-upper/up /run/pixie-upper/work

    _pixie_trace "mount hook: overlay -> /sysroot"
    mkdir -p /sysroot
    mount -t overlay overlay \
        -o "lowerdir=/run/pixie-lower,upperdir=/run/pixie-upper/up,workdir=/run/pixie-upper/work" \
        /sysroot \
        || _pixie_die "failed to mount overlayfs at /sysroot"

    upper=/run/pixie-upper/up
    _pixie_status "mount.ephemeral_mounted"
fi

# Override the image's baked /etc/fstab -- for BOTH modes. Its /
# (LABEL=cloudimg-rootfs), /boot (LABEL=BOOT), and /boot/efi
# (LABEL=UEFI) entries reference partitions on a whole-disk view we do
# not expose under nbdboot, so systemd-fstab-generator materialises
# boot.mount + boot-efi.mount, blocks on the
# /dev/disk/by-label/{BOOT,UEFI} device units that never appear, fails
# local-fs.target, and drops the machine into an emergency-mode loop
# that never reaches sshd (unless the target happens to carry local
# partitions with those labels). / is already mounted from the initrd
# -- the overlay upper (ephemeral) or the RW rootfs (persist) -- so
# fstab has no more work to do. ${upper} points at whichever one this
# boot used. This rewrite previously lived in the ephemeral branch
# only, so persistent boots kept the baked fstab and looped in
# emergency mode on any board without local BOOT/UEFI labels.
mkdir -p "${upper}/etc"
cat > "${upper}/etc/fstab" <<EOF
# Written by nosi pixie-nbdboot dracut hook -- nbdboot overrides the
# image's baked /etc/fstab. / is already mounted from the initrd.
EOF
_pixie_trace "mount hook: wrote minimal /etc/fstab under ${upper}"

# Mask systemd-networkd + NetworkManager + cloud-init on the
# pivoted rootfs so they don't tear down the NIC dracut's network
# module set up (we still own it from the initrd side). Ubuntu
# 26.04 Server ships NetworkManager as the default network stack;
# without the NM masks below the pivoted userspace burns 60 s on
# NetworkManager-wait-online.service before its own online check
# times out. Observed live on GIGABYTE MC12-LE0 booting 2026.W29
# ubuntu-2604-headless: systemd-analyze critical-chain reported
# ``NetworkManager-wait-online.service @3.946s +59.988s`` alongside
# the identical +59 s burn on systemd-networkd-wait-online in the
# initrd (fixed separately by the wait-online mask in
# module-setup.sh). Symlinks land on the overlay upper (ephemeral)
# or directly on the RW rootfs (persist).
mkdir -p "${upper}/etc/systemd/system"
for unit in \
    systemd-networkd.service \
    systemd-networkd.socket \
    systemd-networkd-wait-online.service \
    systemd-resolved.service \
    NetworkManager.service \
    NetworkManager-wait-online.service \
    NetworkManager-dispatcher.service \
    nm-cloud-setup.service \
    nm-cloud-setup.timer \
    cloud-init.service \
    cloud-init-local.service \
    cloud-config.service \
    cloud-final.service \
; do
    ln -sf /dev/null "${upper}/etc/systemd/system/${unit}"
done
_pixie_trace "mount hook: masked networkd + NetworkManager + cloud-init on ${upper}"

# Propagate DNS from dracut's network config. WHERE dracut records it
# depends on which network module brought the link up:
#   * network-manager (current Ubuntu 26.04): /run/NetworkManager/{,no-stub-}resolv.conf
#   * older "network" module:                 /tmp/net.*.resolv.conf
#   * network-legacy:                         /run/net-*.conf (DNSSERVERS= vars)
# Copy the first that lists a real nameserver. Historically this only
# checked the /tmp + /run/net-*.conf paths, so on NetworkManager-driven
# boxes (where the DHCP DNS lands in /run/NetworkManager/resolv.conf) it
# found nothing and left /etc/resolv.conf EMPTY -- the DNS was captured
# by DHCP but never applied, so glibc had no resolver at all.
#
# Ubuntu 26.04 ships /etc/resolv.conf as a SYMLINK to
# /run/systemd/resolve/stub-resolv.conf (systemd-resolved's stub).
# Two things need to happen for glibc to read our plain resolv.conf:
#
#   1. Blow the symlink away here so the ``cp`` / ``>`` below writes
#      a regular file at /etc/resolv.conf instead of following the
#      symlink into a /run tmpfs target that never gets populated
#      once we mask systemd-resolved.
#   2. Neutralise ``/usr/lib/tmpfiles.d/systemd-resolve.conf``'s
#      ``L! /etc/resolv.conf ...`` rule so systemd-tmpfiles-setup on
#      the pivoted rootfs does NOT recreate the symlink at boot,
#      clobbering our file. Drop an empty override at
#      ``/etc/tmpfiles.d/systemd-resolve.conf`` (same basename in
#      /etc wins over /usr/lib per systemd-tmpfiles.d(5)).
rm -f "${upper}/etc/resolv.conf"
mkdir -p "${upper}/etc/tmpfiles.d"
cat > "${upper}/etc/tmpfiles.d/systemd-resolve.conf" <<EOF
# Managed by nosi pixie-nbdboot dracut hook. Overrides
# /usr/lib/tmpfiles.d/systemd-resolve.conf so systemd-tmpfiles does
# not recreate /etc/resolv.conf as a symlink at boot. Pixie writes
# a plain resolv.conf at initrd time and masks systemd-resolved, so
# no one on the pivoted rootfs should touch that file.
EOF
for candidate in \
    /run/NetworkManager/no-stub-resolv.conf \
    /run/NetworkManager/resolv.conf \
    /tmp/net.*.resolv.conf \
    /run/net-*.conf \
; do
    [ -e "$candidate" ] || continue
    case "$candidate" in
        /run/net-*.conf)
            # dracut network-legacy module: sourced shell vars, not a
            # ready resolv.conf.
            # shellcheck disable=SC1090
            . "$candidate" 2>/dev/null || continue
            [ -n "${DNSSERVERS:-}" ] || continue
            {
                echo "# Written by nosi nbdboot dracut hook from ${candidate}."
                [ -n "${DOMAINSEARCH:-}" ] && echo "search ${DOMAINSEARCH}"
                for _ns in ${DNSSERVERS}; do
                    echo "nameserver ${_ns}"
                done
            } > "${upper}/etc/resolv.conf"
            ;;
        *)
            # A ready-made resolv.conf: NetworkManager's (current Ubuntu)
            # or an older dracut /tmp/net.*.resolv.conf. Accept it only if
            # it lists a real, non-stub nameserver -- skip a bare
            # systemd-resolved 127.0.0.53 stub, which resolves nothing once
            # we mask resolved on the pivoted rootfs. Pure-shell scan so the
            # hook needs no grep in the initrd.
            _have_ns=
            while read -r _kw _val _rest; do
                [ "$_kw" = "nameserver" ] || continue
                [ "$_val" = "127.0.0.53" ] && continue
                _have_ns=1
                break
            done < "$candidate"
            [ -n "$_have_ns" ] || continue
            cp "$candidate" "${upper}/etc/resolv.conf"
            ;;
    esac
    _pixie_trace "mount hook: wrote resolv.conf from ${candidate}"
    break
done

_pixie_status "nbdboot.up"
_pixie_trace "mount hook: done -- /sysroot is ${persist:+rw-nbd}${persist:-overlay-on-nbd}"
