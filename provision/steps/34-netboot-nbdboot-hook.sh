#!/usr/bin/env bash
# nosi/provision/steps/34-netboot-nbdboot-hook.sh
#
# Bake the pixie nbdboot attach-hook into the image's initrd so the
# same disk image can either flash-boot locally (hook inert) OR
# nbdboot from NBD (hook fires when ``pixie.nbd=`` -- or the legacy
# ``bty.nbd=`` for backwards compat -- is on the kernel cmdline).
#
# The pixie/bty nbdboot chain used to load a bty-media-baked kernel+initrd
# (Debian 6.12) regardless of the image's own kernel version, causing
# ``uname -r`` under nbdboot to not match the image's ``/lib/modules/``
# tree; any driver not in bty-media's kernel was unloadable in a
# nbdbooted guest (r8125 DKMS, nvidia, custom hypervisor stacks, ...).
# Shifting the hook-install to build time here means the initrd we ship
# in the image carries the ATTACH machinery + the correct kernel
# modules for the image's own kernel; pixie / bty just fetches the
# extracted vmlinuz + initrd at netboot time.
#
# ONE framework: dracut.
#
# Every netboot-capable nosi image -- Fedora, Ubuntu-26.04+, and now
# Debian / Ubuntu-24.04 too -- rides the same dracut 99pixie-nbdboot
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

nosi_info "step 34-netboot-nbdboot-hook (distro=$NOSI_DISTRO shape=${NOSI_SHAPE:-headless})"
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
        # initrd with an initramfs-tools one that carries NO nbdboot hook
        # -- the box would then flash-boot fine but never nbdboot. Guard on
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
'# Managed by nosi/provision/steps/34-netboot-nbdboot-hook.sh
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
    pacman)
        # Arch: mkinitcpio is the stock initramfs generator, so the whole
        # point here is to make DRACUT the generator instead (same "one
        # framework: dracut" convergence the header describes). dracut,
        # its network + nbd modules, and the nbd-client attach binary all
        # ship in Arch's ``dracut`` and ``nbd`` packages; the
        # ``network-manager`` dracut module our 99pixie-nbdboot depends()
        # names needs NetworkManager present at initrd-build time, so
        # install ``networkmanager`` too. It stays INSTALLED-BUT-DISABLED:
        # the booted system runs systemd-networkd (step 08); NM is only
        # bundled into the initrd for the nbdboot DHCP.
        nosi_pkg_install dracut nbd networkmanager

        # Make dracut the SOLE initramfs generator producing the file GRUB
        # references (/boot/initramfs-linux.img). On Arch both mkinitcpio
        # AND dracut ship pacman hooks that regenerate on a kernel upgrade;
        # left alone, mkinitcpio's hook would overwrite our dracut nbdboot
        # initrd with a plain one that carries NO nbdboot machinery (the
        # box would then flash-boot fine but never nbdboot -- the same
        # failure mode the apt branch's initramfs-tools purge guards
        # against). Mask both mkinitcpio hooks AND dracut's own default
        # hooks (they emit initramfs-<kver>.img + a heavy unified EFI image
        # under the wrong name); step 34 owns the single canonical initrd
        # explicitly below. Symlinking to /dev/null is the ArchWiki-blessed
        # way to neutralise a libalpm hook without removing the package.
        install -d -m 0755 /etc/pacman.d/hooks
        for h in 90-mkinitcpio-install 60-mkinitcpio-remove \
                 90-dracut-install 60-dracut-remove; do
            ln -sf /dev/null "/etc/pacman.d/hooks/${h}.hook"
        done

        # Generic-initrd conf (mirrors 14-initramfs-generic / the apt branch
        # below): nosi images are flashed to arbitrary bare metal, so the
        # initramfs must not assume the build VM's storage/driver profile.
        install -d -m 0755 /etc/dracut.conf.d
        nosi_write_if_changed \
'# Managed by nosi/provision/steps/34-netboot-nbdboot-hook.sh
# Build a generic initramfs (all drivers), not host-only: nosi images are
# flashed to arbitrary bare metal, so the initramfs must not assume the
# build VM hardware. Mirrors 14-initramfs-generic.sh (which is dnf-gated).
hostonly="no"
' /etc/dracut.conf.d/00-nosi-generic.conf 0644
        ;;
    *)
        nosi_warn "unsupported package manager for netboot hook (NOSI_PKGMGR=$NOSI_PKGMGR); skipping"
        exit 0
        ;;
esac

# ---- unified dracut wiring (apt + dnf) ------------------------------------
# Install the 99pixie-nbdboot module + force the stock ``nbd`` module and
# our drivers into every initrd via conf.d, then regenerate every installed
# kernel's initrd. Three phased runtime hooks replace the old single
# ``pixie-nbdboot.sh`` so the cmdline override lands before initqueue's
# baked root=UUID devexists polls and the mount phase runs after online has
# attached /dev/nbd0. See module-setup.sh for the full contract.
install -d -m 0755 /etc/dracut.conf.d /usr/lib/dracut/modules.d/99pixie-nbdboot
install -m 0644 "$ASSETS/dracut/conf.d/99-nosi-netboot.conf" /etc/dracut.conf.d/99-nosi-netboot.conf
install -m 0755 "$ASSETS/dracut/modules.d/99pixie-nbdboot/module-setup.sh" /usr/lib/dracut/modules.d/99pixie-nbdboot/module-setup.sh
install -m 0755 "$ASSETS/dracut/modules.d/99pixie-nbdboot/pixie-nbdboot-cmdline.sh" /usr/lib/dracut/modules.d/99pixie-nbdboot/pixie-nbdboot-cmdline.sh
install -m 0755 "$ASSETS/dracut/modules.d/99pixie-nbdboot/pixie-nbdboot-online.sh" /usr/lib/dracut/modules.d/99pixie-nbdboot/pixie-nbdboot-online.sh
install -m 0755 "$ASSETS/dracut/modules.d/99pixie-nbdboot/pixie-nbdboot-mount.sh" /usr/lib/dracut/modules.d/99pixie-nbdboot/pixie-nbdboot-mount.sh

# Regenerate the initrd(s). ``--no-hostonly`` forces generic even if the
# conf above is somehow not picked up.
#
# apt/dnf: ``--regenerate-all`` rebuilds every installed kernel's initrd at
# its distro-default path (initrd.img-<kver> / initramfs-<kver>.img), which
# the netboot packer pairs with vmlinuz-<kver>.
#
# Arch differs: the kernel is ``/boot/vmlinuz-linux`` (token ``linux``, not
# a version), and the packer pairs vmlinuz-<TOKEN> with initramfs-<TOKEN>.img
# / initrd.img-<TOKEN>. ``dracut --regenerate-all`` would instead write
# initramfs-<real-kver>.img, which has no matching vmlinuz-<real-kver> and
# so the bundle pack would find no pair. Generate the single canonical
# ``/boot/initramfs-linux.img`` explicitly for the installed ``linux``
# kernel: that name matches vmlinuz-linux for the packer AND is exactly the
# file GRUB's grub.cfg references, so the local flash-boot path keeps
# working too.
if [ "$NOSI_PKGMGR" = "pacman" ]; then
    # Resolve the kernel version dir the ``linux`` package installed. Arch
    # drops a ``pkgbase`` file next to each module tree naming the source
    # package, so pick the one whose pkgbase is ``linux``. Fall back to the
    # sole/newest module dir if pkgbase is somehow absent.
    kver=""
    for d in /usr/lib/modules/*/; do
        [ -r "${d}pkgbase" ] || continue
        if [ "$(cat "${d}pkgbase")" = "linux" ]; then
            kver="$(basename "$d")"
            break
        fi
    done
    if [ -z "$kver" ]; then
        # shellcheck disable=SC2012
        kver="$(basename "$(ls -d /usr/lib/modules/*/ 2>/dev/null | sort -V | tail -n1)")"
    fi
    [ -n "$kver" ] || nosi_die "cannot resolve installed kernel version under /usr/lib/modules"
    nosi_info "regenerating /boot/initramfs-linux.img via dracut (kver=$kver, --no-hostonly)"
    dracut --no-hostonly --force /boot/initramfs-linux.img "$kver"
else
    nosi_info "regenerating all initramfs images (dracut --regenerate-all --no-hostonly --force)"
    dracut --regenerate-all --no-hostonly --force
fi

nosi_info "step 34-netboot-nbdboot-hook done"
