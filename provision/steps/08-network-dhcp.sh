#!/usr/bin/env bash
# nosi/provision/steps/08-network-dhcp.sh
#
# Deterministic, NIC-agnostic networking, valid whether or not cloud-init
# runs on the target.
#
# Why this exists: nosi images are flashed to bare metal with NO
# cloud-init datasource. cloud-init runs exactly once -- inside the QEMU
# build VM -- where it renders /etc/netplan/50-cloud-init.yaml pinned to
# the BUILD VM's NIC (match: macaddress and/or set-name). The end-of-bake
# `cloud-init clean --logs --seed` does NOT remove that file (plain clean
# keeps generated netplan; only `clean --configs network` would), so the
# build VM's netplan ships verbatim. On the target box cloud-init finds
# no datasource and self-disables for the boot (`cloud-init status` =>
# disabled), so it never re-renders networking -- the stale, build-VM
# netplan is the ONLY network config present, and the real NIC (different
# MAC/name) never comes up. Observed: ubuntu-2404-headless dead on HW
# while ubuntu-2604-headless lived on the same box, purely by which pin
# each build happened to bake.
#
# Fix: own networking ourselves with ONE NIC-agnostic policy expressed in
# two places that carry the identical glob, so it holds in both worlds:
#
#   * /etc/cloud/cloud.cfg.d/90-nosi-network.cfg -- for every host where
#     cloud-init DOES run (VMs/cloud). cloud-init renders a correct,
#     glob-matched netplan from it; if that rendered file later lingers,
#     it is still useful (matched by NAME, not a dead MAC). As cloud-init
#     "system config", it sits BELOW datasource network-config in
#     priority, so a real cloud that pushes a static address still wins.
#   * /etc/netplan/50-nosi.yaml -- the concrete config for the
#     datasource-less bare-metal boot, where cloud-init is disabled and
#     the drop-in above never gets rendered. Same nosi-en/nosi-eth ids as
#     the drop-in, so when cloud-init DOES render its own file the two
#     deep-merge cleanly (identical definitions, no duplicate-iface race).
#
# Either way: DHCP on any wired interface matched by NAME GLOB (en*
# predictable + eth* legacy/VM, never by MAC), so the same image works on
# whatever NIC the target box happens to have. We also delete the
# build-VM 50-cloud-init.yaml so its dead pin cannot win on HW. Fedora
# cloud images render via NetworkManager, whose default already DHCPs any
# ethernet, so there the drop-in (for the cloud-init case) plus clearing
# the baked keyfile is the whole fix.
#
# An apt system that uses NetworkManager instead of netplan (Raspberry Pi
# OS) takes that same NM path: NM's default DHCP covers every wired NIC, so
# nosi writes no netplan there, and the cloud-init drop-in is skipped when
# cloud-init is not installed. Both guards key off what is actually present
# (netplan, cloud-init), so the same step stays correct across renderers.
#
# We write config but never `netplan apply`: the build VM keeps its live
# (cloud-init-brought-up) link through the rest of the bake; the new
# config takes effect on the next boot -- first boot on the real box, and
# the smoketest's fresh boot, which validates it.
#
# Idempotent: nosi_write_if_changed rewrites only on content change;
# rm -f no-ops when the file is already absent.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 08-network-dhcp (distro=$NOSI_DISTRO)"

if nosi_is_wsl; then
    nosi_info "WSL detected; networking is managed by the WSL host, skipping"
    exit 0
fi

nosi_require_root

# ---- FreeBSD: NIC-name-agnostic DHCP via rc.conf --------------------------
# FreeBSD has no netplan / cloud.cfg; networking is /etc/rc.conf. The
# ifconfig_DEFAULT pseudo-interface applies to whichever single ethernet
# NIC the box has (vtnet0 in the build VM, em0/igb0/re0/... on bare
# metal), so it is the FreeBSD analog of the Linux en*/eth* glob and just
# as portable across hardware. async DHCP (not SYNCDHCP) mirrors the
# Linux netplan `optional: true` posture: boot does not block on a NIC
# with no carrier. IPv6 via router-advertised SLAAC. sysrc edits rc.conf
# idempotently (replaces, never duplicates), so no nosi_write_if_changed.
# Config-only, no `service netif restart`: the build VM keeps its live
# nuageinit-brought-up link for the rest of the bake; the next boot (the
# operator's first boot, and the smoketest's fresh boot) applies it.
if [ "$NOSI_PKGMGR" = "pkg" ]; then
    sysrc ifconfig_DEFAULT="DHCP inet6 accept_rtadv" >/dev/null
    sysrc ipv6_activate_all_interfaces="YES" >/dev/null
    sysrc rtsold_enable="YES" >/dev/null

    # Drop any per-NIC pin the base image / nuageinit may have baked
    # (e.g. ifconfig_vtnet0=...), which would shadow ifconfig_DEFAULT on
    # hardware whose NIC has a different name. Keep only the DEFAULT vars.
    for v in $(sysrc -a 2>/dev/null | awk -F: '/^ifconfig_/{print $1}'); do
        case "$v" in
        ifconfig_DEFAULT | ifconfig_DEFAULT_ipv6) : ;;
        ifconfig_*) sysrc -x "$v" >/dev/null 2>&1 || true ;;
        esac
    done

    nosi_info "step 08-network-dhcp done (freebsd: ifconfig_DEFAULT=DHCP+accept_rtadv)"
    exit 0
fi

# ---- 1. cloud-init drop-in: glob DHCP for hosts where cloud-init runs -----
# Only meaningful where cloud-init actually runs (VMs/cloud, and the x86
# bake itself). On an image baked without cloud-init, the Raspberry Pi
# chroot bake on NetworkManager-managed Raspberry Pi OS, it would drop an
# inert file under /etc/cloud, so gate it on cloud-init being present.
# Skip on Arch: cloud-init's netplan renderer does not exist there (Arch
# ships no netplan), and we own networking directly via a systemd-networkd
# .network in part 2 below, so this drop-in would be inert at best.
if [ "$NOSI_PKGMGR" != "pacman" ] && command -v cloud-init >/dev/null 2>&1; then
nosi_write_if_changed \
"# Managed by nosi/provision/steps/08-network-dhcp.sh
# DHCP on any wired interface, matched by NAME (en* predictable + eth*
# legacy/VM), never by MAC. Mirrors /etc/netplan/50-nosi.yaml so the two
# agree when cloud-init renders this. Below datasource network-config in
# priority, so a cloud pushing a static address still wins.
network:
  version: 2
  ethernets:
    nosi-en:
      match: {name: \"en*\"}
      dhcp4: true
      dhcp6: true
      optional: true
    nosi-eth:
      match: {name: \"eth*\"}
      dhcp4: true
      dhcp6: true
      optional: true
" /etc/cloud/cloud.cfg.d/90-nosi-network.cfg 0644
else
    nosi_info "cloud-init not installed; skipping cloud-init network drop-in"
fi

# ---- 2. concrete netplan for the datasource-less bare-metal boot ----------
case "$NOSI_PKGMGR" in
apt)
    if command -v netplan >/dev/null 2>&1; then
        # netplan/networkd is the renderer (Debian/Ubuntu cloud images).
        # Same glob + same ids as the cloud-init drop-in above.
        nosi_write_if_changed \
"# Managed by nosi/provision/steps/08-network-dhcp.sh
# DHCP on any wired interface, matched by NAME (en* predictable + eth*
# legacy/VM), never by MAC. optional:true keeps boot from blocking on a
# NIC with no carrier. Mirrors /etc/cloud/cloud.cfg.d/90-nosi-network.cfg.
network:
  version: 2
  renderer: networkd
  ethernets:
    nosi-en:
      match: {name: \"en*\"}
      dhcp4: true
      dhcp6: true
      optional: true
    nosi-eth:
      match: {name: \"eth*\"}
      dhcp4: true
      dhcp6: true
      optional: true
" /etc/netplan/50-nosi.yaml 0600

        # Drop the build-VM artifact pinned to the QEMU NIC. Our config
        # supersedes it; leaving it would let a dead MAC pin win on HW.
        rm -f /etc/netplan/50-cloud-init.yaml

        # Validate the YAML we just wrote (generate backends only, no apply,
        # so the live link stays up for the rest of the bake). Fail on a typo.
        netplan generate || nosi_die "netplan generate rejected /etc/netplan/50-nosi.yaml"
    else
        # apt with no netplan means NetworkManager-managed (Raspberry Pi OS):
        # NM already DHCPs every wired interface by default, so a netplan file
        # would be inert here (and would fight NM if netplan were later
        # installed). Mirror the dnf/NM path: clear any baked per-NIC keyfile
        # pinned to the build NIC and rely on NM's default auto-DHCP.
        rm -f /etc/NetworkManager/system-connections/cloud-init-*.nmconnection
        nosi_info "apt + no netplan (NetworkManager-managed); relying on NM default DHCP"
    fi
    ;;
dnf)
    # Fedora cloud images use NetworkManager; its default connection
    # auto-DHCPs any ethernet, so the cloud-init drop-in (for the VM case)
    # plus clearing the build-VM keyfile is the whole fix on HW.
    rm -f /etc/NetworkManager/system-connections/cloud-init-*.nmconnection
    ;;
pacman)
    # Arch cloud image (arch-boxes) uses systemd-networkd with predictable
    # interface names DISABLED, so NICs surface as eth0/eth1... Own the
    # policy ourselves with ONE NIC-agnostic .network matched by NAME GLOB
    # (en* predictable + eth* legacy/VM), never by MAC, so the same image
    # DHCPs on whatever NIC the target box has. RequiredForOnline=no keeps
    # boot from blocking on a NIC with no carrier (the networkd analog of
    # netplan's optional:true). Config-only, no `networkctl reload`: the
    # build VM keeps its live link for the rest of the bake; the next boot
    # (operator first boot, smoketest fresh boot) applies it. Drop any
    # per-NIC .network the arch-boxes base may ship that could shadow ours.
    install -d -m 0755 /etc/systemd/network
    rm -f /etc/systemd/network/20-ethernet.network
    nosi_write_if_changed \
'# Managed by nosi/provision/steps/08-network-dhcp.sh
# DHCP on any wired interface, matched by NAME (en* predictable + eth*
# legacy/VM), never by MAC. RequiredForOnline=no keeps boot from blocking
# on a NIC with no carrier.
[Match]
Name=en*
Name=eth*

[Network]
DHCP=yes

[Link]
RequiredForOnline=no
' /etc/systemd/network/50-nosi-dhcp.network 0644

    # systemd-networkd + resolved are the arch-boxes cloud defaults; enable
    # them explicitly so the "networking comes up on next boot" guarantee
    # does not depend on the base image keeping them enabled. Point
    # /etc/resolv.conf at the resolved stub so DNS follows the DHCP lease.
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable systemd-networkd.service 2>/dev/null \
            || nosi_warn "could not enable systemd-networkd.service"
        systemctl enable systemd-resolved.service 2>/dev/null \
            || nosi_warn "could not enable systemd-resolved.service"
    fi
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    ;;
esac

# The default hostname (nosi-<variant>) is set in 05-nosi-release, which
# runs in every build path so each derive stamps its own variant name;
# this base-only step would leave derives with the headless base's name.

nosi_info "step 08-network-dhcp done"
