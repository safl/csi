#!/bin/bash
# dracut module: pixie-ramboot
#
# Install-time hook. Called by ``dracut -f`` (or dracut's automatic
# runs after a kernel update) when 99pixie-ramboot is in the module
# list (pulled in by /etc/dracut.conf.d/99-nosi-netboot.conf on
# nosi-baked images). Wires up:
#
#   * kernel modules (nbd, overlay, ext4/xfs/btrfs) so the runtime
#     hooks don't have to modprobe from userspace with a missing
#     dep chain.
#   * userspace binaries (nbd-client + core utilities used by the
#     runtime hooks) baked into the initrd tree.
#   * Three phased hooks driving the ramboot chain:
#
#     - cmdline (priority 10): parse ``pixie.nbd=`` (or the legacy
#       ``bty.nbd=`` for backwards compat) off /proc/cmdline
#       and IMMEDIATELY override dracut's ``root`` var so the
#       initqueue doesn't wait for the image's baked ``root=UUID=``
#       (which never appears -- there's no local disk). Also
#       registers ``/dev/nbd0`` as the wait-for device.
#
#     - initqueue/online (priority 20): after ``network`` module
#       has DHCPed the primary NIC, run nbd-client to attach the
#       remote export at /dev/nbd0. Idempotent (touches a sentinel
#       so re-entry of the initqueue no-ops).
#
#     - mount (priority 90): last-mile pivot prep -- overlay the
#       root partition on tmpfs, rewrite /etc/fstab in the overlay
#       upper (drop /boot + /boot/efi), mask systemd-networkd +
#       cloud-init in the overlay upper, propagate DNS. Runs LAST
#       so dracut's own mount hooks have finished by the time we
#       repoint /sysroot at our overlay.
#
# The old single-hook shape ``inst_hook mount 10`` was fundamentally
# wrong: dracut's mount phase never fires when initqueue is stuck
# waiting for the image's baked ``root=UUID=`` (which never appears
# without our NBD attach). Splitting into cmdline+online+mount lets
# each phase do its job in the order dracut actually runs them.

# shellcheck disable=SC2148

# check() = 255 -> the module is only added when explicitly listed
# in add_dracutmodules= or by kernel cmdline. Nosi does the former.
check() {
    return 255
}

# Runtime deps: base for shell tooling, network-manager for the
# initrd-side DHCP + resolv.conf population that the online hook
# consumes. Fedora 40+ split ``network`` into concrete providers
# (``network-manager``, ``network-legacy``, ``network-wicked``) and
# ``network`` no longer resolves; ``network-manager`` is the
# concrete dep that works on both Fedora 44 and Ubuntu 26.04.
depends() {
    echo "base network-manager"
    return 0
}

# Kernel modules pulled into the initrd. ``instmods`` silently
# ignores modules not built for this kernel, which is what we want:
# btrfs may or may not be available; the runtime hook probes
# opportunistically.
#
# r8125 is the out-of-tree Realtek 2.5GbE DKMS driver installed by step
# 10-r8125-dkms (x86-only; skipped on arm64, where instmods just no-ops
# it). It MUST be in the netboot initrd: an RTL8125 target (e.g. ASRock
# Rack matx) does not come up on the in-tree r8169 in early userspace,
# and neither dracut's generic set nor a host-only build pulls a
# /updates/dkms/ module in -- so without this the initrd never DHCPs or
# nbd-connects and the box reboot-loops. The ``softdep r8169 pre: r8125``
# + ASPM/EEE options from step 10 ride along via /etc/modprobe.d, which
# dracut copies into the initrd, so r8125 is preferred once present.
installkernel() {
    instmods nbd overlay ext4 xfs btrfs r8125
}

# Userspace: nbd-client + shell tooling the runtime hooks use.
# ``inst_multiple`` resolves ELF interpreter + shared-lib closures
# via ldd; ``inst_hook`` copies each runtime script into the
# initrd's hook directory for the given phase.
install() {
    inst_multiple nbd-client mount umount awk sed grep sort cut wget \
                  blockdev partx udevadm blkid ip modprobe
    # ``$moddir`` is exported by dracut when it sources this file --
    # it points at the module's own directory.
    # shellcheck disable=SC2154
    inst_hook cmdline 10 "$moddir/pixie-ramboot-cmdline.sh"
    inst_hook initqueue/online 20 "$moddir/pixie-ramboot-online.sh"
    inst_hook mount 90 "$moddir/pixie-ramboot-mount.sh"

    # Mask systemd-networkd-wait-online.service in the SHIPPED initrd.
    # Ubuntu 26.04+ ships dracut with the network + systemd modules
    # that together pull in systemd-networkd-wait-online.service,
    # which then waits 120 s for a network-online.target signal that
    # never fires under nbdboot (our own online hook handles the
    # nbd-client attach after dracut's ``network`` module brought a
    # NIC up via DHCP; nothing in the initrd flips
    # network-online.target). The wait-online.service times out,
    # gives up, and boot moves on, but only after burning the full
    # 120 s right in the initrd critical path.
    #
    # Symlink the unit to /dev/null in the initrd's unit dir so it
    # can never start. ``$initdir`` is the initrd's rootfs at bake
    # time; ``ln -sf`` here writes into the shipped initrd. This is
    # separate from the equivalent mask the mount hook lays down in
    # the overlay upper, which protects the pivoted rootfs.
    # shellcheck disable=SC2154
    mkdir -p "${initdir}/etc/systemd/system"
    ln -sf /dev/null \
        "${initdir}/etc/systemd/system/systemd-networkd-wait-online.service"

    # NOTE ON THE ROOT=UUID SITUATION:
    # Ubuntu's cloud-image dracut config bakes root=UUID references into
    # the initrd in three places that keep dracut-initqueue waiting for
    # local disks when the image is netbooted:
    #
    #   /etc/cmdline.d/20-root-dev.conf
    #   /var/lib/dracut/hooks/initqueue/finished/devexists-*.sh
    #   /var/lib/dracut/hooks/emergency/80-*.sh
    #
    # We DON'T strip them here because ``dracut --regenerate-all`` inside
    # the image build (step 34) regenerates the SAME initrd the image
    # boots locally from -- stripping would break the flash-boot path.
    # The netboot bundle packer (cijoe/scripts/netboot_bundle_pack.py)
    # strips these from ONLY the copy it ships in the bundle, so the
    # ramboot path gets the stripped initrd while the local-disk path
    # keeps the pristine one.
}
