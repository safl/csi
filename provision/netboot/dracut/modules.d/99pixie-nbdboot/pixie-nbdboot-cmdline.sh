#!/bin/sh
# dracut cmdline hook for pixie nbdboot (priority 10).
#
# Runs during dracut's cmdline phase, before ANY device lookups. Its
# only job is to override dracut's baked ``root=UUID=`` with our NBD
# device so the initqueue doesn't sit for 3 minutes waiting for a
# disk UUID that will never appear (there's no local disk in a
# nbdboot).
#
# Does NOT do the actual nbd-client attach -- that needs the
# ``network`` module to have brought a NIC up, which happens later
# in the initqueue/online phase. See ``pixie-nbdboot-online.sh``.

# shellcheck disable=SC1091
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

_pixie_trace() { echo "pixie-nbdboot: $*" >/dev/kmsg 2>/dev/null || echo "pixie-nbdboot: $*"; }

# Prefer ``pixie.nbd=`` (current cmdline shape); fall back to
# ``bty.nbd=`` for legacy bundles.
nbd_url="$(getarg pixie.nbd=)"
[ -n "$nbd_url" ] || nbd_url="$(getarg bty.nbd=)"
[ -n "$nbd_url" ] || return 0

_pixie_trace "cmdline hook: nbd=${nbd_url}; overriding baked root= to block:/dev/nbd0"

# The image bakes ``root=UUID=<image-root-uuid>`` (etc.) into
# ``/etc/cmdline.d/20-root-dev.conf`` inside the initrd; that file's
# contents are merged into the effective kernel cmdline BEFORE any
# hook runs, and systemd's fstab-generator (also earlier than us)
# emits ``dev-disk-by-uuid-<uuid>.device`` units from it. Redact the
# file so those units never get emitted; the local-disk root= is
# meaningless for nbdboot.
if [ -e /etc/cmdline.d/20-root-dev.conf ]; then
    _pixie_trace "cmdline hook: redacting /etc/cmdline.d/20-root-dev.conf"
    : > /etc/cmdline.d/20-root-dev.conf
fi

# dracut convention: set $root + $rootok, then register a wait-for
# hook so the initqueue polls until /dev/nbd0 appears. The online
# hook actually creates it.
root="block:/dev/nbd0"
rootok=1
export root rootok
wait_for_dev /dev/nbd0
