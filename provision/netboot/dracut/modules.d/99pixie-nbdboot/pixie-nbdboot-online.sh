#!/bin/sh
# dracut initqueue/online hook for pixie nbdboot (priority 20).
#
# Runs after the ``network`` module has brought the primary NIC up
# with DHCP. This is when we can finally reach the NBD server.
# Attaches ``/dev/nbd0`` to the remote export named in
# ``pixie.image=`` (or the legacy ``bty.image=``), waits for
# capacity + partition nodes, then returns; dracut's initqueue
# polling sees /dev/nbd0 appear and advances.
#
# Overlay + fstab rewrite + resolv.conf population land in the
# subsequent ``mount`` phase hook so we don't block initqueue on
# tasks that need the block device to be settled first.

# shellcheck disable=SC1091
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

_pixie_trace() { echo "pixie-nbdboot: $*" >/dev/kmsg 2>/dev/null || echo "pixie-nbdboot: $*"; }
_pixie_die() {
    _pixie_trace "FATAL: $*"
    _pixie_status "online.died:$*"
    type emergency_shell >/dev/null 2>&1 && emergency_shell "pixie-nbdboot: $*"
    exec sleep 2147483647
}

# Prefer ``pixie.*`` cmdline names; fall back to ``bty.*`` for
# legacy bundles booted against a bty appliance.
_pixie_getarg() {
    key="$1"
    val="$(getarg "pixie.${key}=")"
    [ -n "$val" ] || val="$(getarg "bty.${key}=")"
    echo "$val"
}

# Best-effort HTTP status ping. Traces via /dev/kmsg vanish below the
# console loglevel on IPMI SoL, so this ships boot-phase progress to
# pixie's event log via ``POST /pxe/<mac>/status`` -- the same shape
# ``nbdboot.up`` uses. Silent on failure (DHCP may not have completed
# yet, wget may be missing). Reports the value passed as ``$1`` as
# the status token (e.g. ``online.nbd_connected``).
_pixie_status() {
    _srv="$(_pixie_getarg server)"
    _mac="$(_pixie_getarg mac)"
    [ -n "$_srv" ] && [ -n "$_mac" ] || return 0
    wget -q -O /dev/null --timeout=3 --tries=1 \
        --post-data="status=$1" \
        "${_srv}/pxe/${_mac}/status" 2>/dev/null || true
}

# Idempotent: initqueue/online can fire multiple times as the network
# module reports readiness on each carrier event. Attach once.
[ -e /tmp/pixie-nbd-attached ] && return 0

nbd_url="$(_pixie_getarg nbd)"
[ -n "$nbd_url" ] || return 0
image="$(_pixie_getarg image)"
[ -n "$image" ] || _pixie_die "missing pixie.image / bty.image on kernel cmdline"

_pixie_status "online.started"

# tcp://host:port -> host, port.
nbd_host="${nbd_url#tcp://}"; nbd_host="${nbd_host%%:*}"
nbd_port="${nbd_url##*:}"

_pixie_status "online.modprobe_start"
_pixie_trace "online hook: modprobe nbd (nbds_max=1 max_part=16) + overlay"
rmmod nbd 2>/dev/null || true
modprobe nbd nbds_max=1 max_part=16 || _pixie_die "modprobe nbd failed"
modprobe overlay || _pixie_die "modprobe overlay failed"
_pixie_status "online.modprobe_done"

# nbd-client argument shape: modern nbd-client requires flag options
# BEFORE positional (host, port, device). ``-N NAME`` selects the
# newstyle export name; ``-persist`` re-connects on drop; ``-block-size
# 4096`` avoids the mis-sized-io warnings some kernels emit. Capture
# stderr into a scratch file we can log if the connect fails.
_pixie_trace "online hook: nbd-client -N ${image} -persist ${nbd_host} ${nbd_port} /dev/nbd0"
# TCP-level pre-check: some initrds see nbd-client return before it
# has actually made a syscall; wrap the real attempt in a retry loop
# so a single lost SYN doesn't drop us to emergency.
attempt=0
while [ "$attempt" -lt 5 ]; do
    _pixie_status "online.nbd_attempt_${attempt}"
    nbd_out="$(nbd-client -N "$image" -persist "$nbd_host" "$nbd_port" /dev/nbd0 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        break
    fi
    _pixie_trace "online hook: nbd-client attempt $((attempt + 1)) rc=${rc}: ${nbd_out}"
    _pixie_status "online.nbd_attempt_${attempt}_failed_rc${rc}"
    attempt=$((attempt + 1))
    sleep 1
done
[ "$rc" -eq 0 ] || _pixie_die "nbd-client failed to connect to ${nbd_host}:${nbd_port} after ${attempt} tries: ${nbd_out}"
_pixie_status "online.nbd_connected"

# Capacity ready.
i=0
while [ "$i" -lt 100 ]; do
    sz="$(blockdev --getsize64 /dev/nbd0 2>/dev/null || echo 0)"
    [ "${sz:-0}" -gt 0 ] && break
    sleep 0.1
    i=$((i + 1))
done
_pixie_trace "online hook: nbd0 capacity ready after ${i} tick(s): ${sz:-0} bytes"

# Settle udev so the block device is fully published before the
# mount hook fires. Pixie serves /dev/nbd0 as the ext4 root partition
# directly in both modes now (ephemeral via nbdkit
# ``--filter=partition``; persist via qemu-nbd ``--offset=<part1>``),
# so there is no partition-table rescan work for this hook to do.
udevadm settle --timeout=10 || true

: > /tmp/pixie-nbd-attached  # pure-shell truncate, no ``touch`` dep (busybox in initrd may lack it)
_pixie_trace "online hook: done -- /dev/nbd0 attached"
