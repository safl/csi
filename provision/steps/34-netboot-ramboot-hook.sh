#!/usr/bin/env bash
# nosi/provision/steps/34-netboot-ramboot-hook.sh
#
# Bake the pixie ramboot attach-hook into the image's initrd so the
# same disk image can either flash-boot locally (hook inert) OR
# ramboot from NBD (hook fires when ``pixie.nbd=`` -- or the legacy
# ``bty.nbd=`` for backwards compat -- is on the kernel cmdline).
#
# The pixie/bty ramboot chain used to load a bty-media-baked kernel+initrd
# (Debian 6.12) regardless of the image's own kernel version, causing
# ``uname -r`` under ramboot to not match the image's ``/lib/modules/``
# tree; any driver not in bty-media's kernel was unloadable in a
# rambooted guest (r8125 DKMS, nvidia, custom hypervisor stacks, ...).
# Shifting the hook-install to build time here means the initrd we ship
# in the image carries the ATTACH machinery + the correct kernel
# modules for the image's own kernel; pixie / bty just fetches the
# extracted vmlinuz + initrd at netboot time.
#
# ONE framework: dracut.
#
# Every netboot-capable nosi image -- Fedora, Ubuntu-26.04+, and now
# Debian / Ubuntu-24.04 too -- rides the same dracut 99pixie-ramboot
# module. We install it under /usr/lib/dracut/modules.d/, force the
# stock ``nbd`` module + nbd/overlay drivers into every initrd via
# /etc/dracut.conf.d/99-nosi-netboot.conf, then ``dracut
# --regenerate-all --force``. Boot dispatch is the module's phased
# hooks reading ``pixie.nbd=`` / ``bty.nbd=`` from cmdline.
#
# The old initramfs-tools ramboot path (a /scripts/ramboot driver +
# hooks/bty-ramboot for apt distros) is RETIRED. Its early-boot network
# bring-up hangs forever on some hardware: a dual-NIC Intel igb box
# nbd-connects in 24s under dracut but never comes up under
# initramfs-tools, and dracut's network / network-manager module drives
# the same NICs without the hang. Rather than carry two attach paths we
# converge apt onto dracut. Debian's ``dracut`` package
# ``Provides: linux-initramfs-tool``, so it satisfies the kernel
# packages' initramfs dependency and can fully replace initramfs-tools
# as the sole initrd generator (see the apt branch below).
#
# Non-headless shapes (desktop / wsl / lxc / docker / proxmox) skip
# entirely: netboot isn't a shape that ever matters for those.
# Non-Linux (FreeBSD) skips too -- kernel + initrd chain diverge and a
# BSD story is a separate design.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 34-netboot-ramboot-hook (distro=$NOSI_DISTRO shape=${NOSI_SHAPE:-headless})"
nosi_require_root

# Only headless images become bootable-from-network. desktop shapes
# might make sense for game-streaming appliances later but are out of
# scope now; wsl/lxc/docker have no kernel of their own; proxmox is a
# hypervisor host, flash-only.
if [ -n "${NOSI_SHAPE:-}" ] && [ "${NOSI_SHAPE}" != "headless" ]; then
    nosi_info "shape=${NOSI_SHAPE} is not headless; skipping"
    exit 0
fi

if [ "$NOSI_DISTRO" = "freebsd" ]; then
    nosi_info "freebsd netboot is a separate design; skipping"
    exit 0
fi

HERE="$(dirname "$(readlink -f "$0")")"
ASSETS="$HERE/../netboot"

# Per-package-manager prerequisites. Both paths converge on the unified
# dracut wiring below; the only difference is which packages carry
# dracut + its network/nbd modules, and (on apt) retiring
# initramfs-tools so it can't clobber the dracut initrd later.
case "$NOSI_PKGMGR" in
    apt)
        # Debian / Ubuntu-24.04 headless netboot moves off initramfs-tools
        # onto dracut (see the header for the igb hang that motivates it).
        #
        # dracut-network ships the network / network-manager + nbd dracut
        # modules our conf.d references; nbd-client is the userspace attach
        # binary the module's online hook drives. Ubuntu-26.04 already
        # ships dracut under apt, so nosi_pkg_install just tops up what's
        # missing there.
        nosi_pkg_install dracut dracut-network nbd-client

        # Make dracut the SOLE initrd generator. Debian's dracut package
        # Provides: linux-initramfs-tool, so purging initramfs-tools keeps
        # the kernel packages' initramfs dependency satisfied. Purging
        # matters: if both generators stay installed, a later
        # ``update-initramfs`` (a kernel-upgrade postinst on the running
        # box, an unrelated provision step) would overwrite our dracut
        # initrd with an initramfs-tools one that carries NO ramboot hook
        # -- the box would then flash-boot fine but never ramboot. Guard on
        # presence so this is a no-op on Ubuntu-26.04 (dracut-native, no
        # initramfs-tools to remove) and on re-runs.
        if nosi_pkg_installed initramfs-tools; then
            nosi_info "purging initramfs-tools so dracut is the sole initrd generator"
            DEBIAN_FRONTEND=noninteractive apt-get purge -y initramfs-tools
        fi

        # Guarantee a GENERIC (not host-only) initrd on apt. Step
        # 14-initramfs-generic can't have done this for us: it early-exits
        # on non-dnf AND, even if it didn't, dracut wasn't installed yet
        # when step 14 ran (dracut only arrives here, at step 34). nosi
        # images are flashed to arbitrary bare metal, so the initrd must
        # not assume the build VM's storage/driver profile. Drop the same
        # conf step 14 uses (same content + rationale) BEFORE we regenerate
        # below; the ``--no-hostonly`` flag on the regen belt-and-braces it.
        install -d -m 0755 /etc/dracut.conf.d
        nosi_write_if_changed \
'# Managed by nosi/provision/steps/34-netboot-ramboot-hook.sh
# (mirrors 14-initramfs-generic.sh; step 14 skips apt, so netboot apt
# images get their generic-initrd conf from here instead).
# Build a generic initramfs (all drivers), not host-only: nosi images are
# flashed to arbitrary bare metal, so the initramfs must not assume the
# build VM hardware. See the step script for the full rationale.
hostonly="no"
' /etc/dracut.conf.d/00-nosi-generic.conf 0644
        ;;
    dnf)
        # dracut path (Fedora).
        # ``nbd`` binary is in the stock ``nbd`` package on Fedora.
        # ``dracut-network`` ships the network-manager + nbd dracut
        # modules our conf.d references; without it the minimal
        # cloud-image dracut has only base modules and the
        # ``network-manager`` dep on our module fails to resolve.
        # Generic-initrd conf is already in place from step 14 (dnf-gated).
        nosi_pkg_install nbd dracut-network
        ;;
    *)
        nosi_warn "unsupported package manager for netboot hook (NOSI_PKGMGR=$NOSI_PKGMGR); skipping"
        exit 0
        ;;
esac

# ---- unified dracut wiring (apt + dnf) ------------------------------------
# Install the 99pixie-ramboot module + force the stock ``nbd`` module and
# our drivers into every initrd via conf.d, then regenerate every installed
# kernel's initrd. Three phased runtime hooks replace the old single
# ``pixie-ramboot.sh`` so the cmdline override lands before initqueue's
# baked root=UUID devexists polls and the mount phase runs after online has
# attached /dev/nbd0. See module-setup.sh for the full contract.
install -d -m 0755 /etc/dracut.conf.d /usr/lib/dracut/modules.d/99pixie-ramboot
install -m 0644 "$ASSETS/dracut/conf.d/99-nosi-netboot.conf" /etc/dracut.conf.d/99-nosi-netboot.conf
install -m 0755 "$ASSETS/dracut/modules.d/99pixie-ramboot/module-setup.sh" /usr/lib/dracut/modules.d/99pixie-ramboot/module-setup.sh
install -m 0755 "$ASSETS/dracut/modules.d/99pixie-ramboot/pixie-ramboot-cmdline.sh" /usr/lib/dracut/modules.d/99pixie-ramboot/pixie-ramboot-cmdline.sh
install -m 0755 "$ASSETS/dracut/modules.d/99pixie-ramboot/pixie-ramboot-online.sh" /usr/lib/dracut/modules.d/99pixie-ramboot/pixie-ramboot-online.sh
install -m 0755 "$ASSETS/dracut/modules.d/99pixie-ramboot/pixie-ramboot-mount.sh" /usr/lib/dracut/modules.d/99pixie-ramboot/pixie-ramboot-mount.sh

# ``--no-hostonly`` forces generic even if the conf above is somehow not
# picked up; it also brings the dnf path to parity with apt (step 14 already
# wrote hostonly="no" on dnf, so this changes nothing there but the flag).
nosi_info "regenerating all initramfs images (dracut --regenerate-all --no-hostonly --force)"
dracut --regenerate-all --no-hostonly --force

nosi_info "step 34-netboot-ramboot-hook done"
