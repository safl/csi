#!/usr/bin/env bash
# nosi/provision/steps/60-proxmox-ve.sh
#
# proxmox shape only. Turns the headless Debian base into a Proxmox VE host
# (PVE 9 on Debian 13 trixie, no-subscription repo).
#
# This runs in the derive chroot (derive_pack copies the baked headless rootfs
# and chroots in). proxmox-ve's postinst scripts try to START daemons
# (pve-cluster/pmxcfs, pvedaemon, ...), which cannot run under a chroot with no
# PID 1. The standard chroot technique handles that: a policy-rc.d returning
# 101 makes invoke-rc.d skip every service start during the install, and the
# daemons come up normally on the first real boot. So the bake installs +
# configures Proxmox; first boot brings it to life (pveproxy on :8006).
#
# Networking (vmbr0 bridge) and the second-NVMe storage are deliberately NOT
# set up here -- those need the live system and the operator's hardware, and
# are handled by a first-boot helper / documented setup. The host is fully
# usable without them (add the bridge + storage from the web UI or the helper).

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 60-proxmox-ve (shape=${NOSI_SHAPE:-?})"

if [ "${NOSI_SHAPE:-}" != "proxmox" ]; then
    nosi_info "non-proxmox shape; skipping"
    exit 0
fi

nosi_require_root

if [ "${NOSI_PKGMGR:-}" != "apt" ]; then
    nosi_die "proxmox shape is Debian-only (PVE on trixie); got pkgmgr=${NOSI_PKGMGR:-?}"
fi

export DEBIAN_FRONTEND=noninteractive

# Deny service starts for the duration of the install (chroot has no PID 1).
cat >/usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 /usr/sbin/policy-rc.d

# PVE 9 no-subscription repo (Debian 13 trixie) + release key. signed-by keeps
# the key scoped to this repo rather than trusting it system-wide.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg \
    -o /etc/apt/keyrings/proxmox-release-trixie.gpg
cat >/etc/apt/sources.list.d/pve.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/proxmox-release-trixie.gpg] http://download.proxmox.com/debian/pve trixie pve-no-subscription
EOF

# postfix is pulled in by proxmox-ve; preseed it as a local-only MTA so the
# install never blocks on a debconf prompt.
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string nosi-proxmox" | debconf-set-selections

apt-get update
apt-get install -y proxmox-ve postfix open-iscsi chrony

# proxmox-ve's packages drop in the pve-enterprise repo, which requires a paid
# subscription: on the shipped host every `apt-get update` then fails with
# "401 Unauthorized ... repository is not signed" and exits 100. That breaks
# apt for the operator and for pveproxy's first-boot ExecStartPost
# (/usr/bin/pveupdate runs apt-get update inside a 90s start timeout). We use
# the no-subscription repo configured above, so drop the enterprise one, as
# Proxmox's own install-on-Debian guide instructs.
rm -f /etc/apt/sources.list.d/pve-enterprise.list \
      /etc/apt/sources.list.d/pve-enterprise.sources
if grep -Rqs enterprise.proxmox.com /etc/apt/sources.list /etc/apt/sources.list.d/; then
    nosi_die "pve-enterprise repo still configured; apt-get update fails with 401 on the shipped host"
fi

# postfix's postinst snapshots the BUILD host's FQDN into main.cf -- in the
# derive chroot that is the ephemeral CI runner (e.g.
# runnervm....internal.cloudapp.net), which then ships in the published image.
# Drop the baked myhostname so postfix derives it from the live hostname at
# runtime, and pin mydestination to runtime-derived names for the same reason.
# These edit main.cf and should succeed in the chroot, so surface a failure
# (a silent one ships the runner FQDN, the exact bug this fixes) instead of
# swallowing it.
postconf -X myhostname \
    || nosi_warn "postconf -X myhostname failed; the build-host FQDN may persist in postfix main.cf"
postconf -e 'mydestination = $myhostname, localhost.$mydomain, localhost' \
    || nosi_warn "postconf -e mydestination failed"

# Proxmox ships + boots its own kernel; drop the Debian cloud kernel and
# os-prober so GRUB defaults to the PVE kernel (per Proxmox's install-on-Debian
# guide). proxmox-ve already pulled proxmox-default-kernel, so a kernel remains.
# update-grub legitimately fails in a chroot with no /boot device (the live
# host regenerates it on first boot), so warn rather than die; the assertions
# below catch the outcomes that actually matter.
apt-get remove -y os-prober 'linux-image-amd64' 'linux-image-6.*' 2>/dev/null \
    || nosi_warn "removing the Debian cloud kernel / os-prober reported an error"
update-grub 2>/dev/null \
    || nosi_warn "update-grub failed (expected in a chroot with no /boot; the live host regenerates it on first boot)"

# Assert what the suppression above could otherwise hide: a Proxmox kernel
# survived (without one the host has nothing to boot), and the Debian cloud
# kernel is gone (left installed, GRUB can default back to it on first boot).
if ! dpkg-query -W -f='${Package}\n' 'proxmox-kernel-*' 2>/dev/null | grep -q .; then
    nosi_die "no proxmox-kernel-* installed after the cloud-kernel removal; the PVE host would have no bootable kernel"
fi
if dpkg-query -W -f='${db:Status-Status}\n' linux-image-amd64 2>/dev/null | grep -q '^installed'; then
    nosi_warn "linux-image-amd64 still installed; GRUB may default to the Debian cloud kernel instead of PVE"
fi

# ---- identity ---------------------------------------------------------------
# The hostname IS the PVE node name (/etc/pve/nodes/<hostname>). 05-nosi-release
# already stamped the derive's own default (nosi-<variant>, e.g.
# nosi-debian-13-proxmox) + the matching /etc/hosts entry; the boot services
# below read the live hostname, so they work whatever the host ends up named.

# ---- first-boot: make the node hostname resolvable (pmxcfs needs it) -------
# pve-cluster (pmxcfs) refuses to start unless the node hostname resolves to an
# address, and everything else (pvedaemon, pveproxy, pvestatd, pve-firewall)
# Requires it. Cloud images ship /etc/hosts without a hostname entry and rely on
# cloud-init to add one -- but cloud-init is disabled on a flashed host, so add
# it ourselves, ordered Before=pve-cluster. Read the live hostname each boot so
# it works whatever the host ends up named (static or DHCP-assigned).
nosi_write_if_changed \
'#!/bin/sh
# Managed by nosi/provision/steps/60-proxmox-ve.sh
set -u
hn=$(hostname 2>/dev/null)
[ -n "$hn" ] && [ "$hn" != "localhost" ] || exit 0
# Already resolvable (an /etc/hosts entry or DNS) -> nothing to do.
getent hosts "$hn" >/dev/null 2>&1 && exit 0
printf "127.0.1.1\t%s.localdomain %s\n" "$hn" "$hn" >> /etc/hosts
' /usr/local/sbin/nosi-proxmox-hosts 0755

nosi_write_if_changed \
'[Unit]
Description=nosi: ensure the node hostname resolves (required by pmxcfs)
DefaultDependencies=no
After=local-fs.target
Before=pve-cluster.service basic.target
ConditionPathExists=/usr/bin/pmxcfs

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nosi-proxmox-hosts
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
' /etc/systemd/system/nosi-proxmox-hosts.service 0644
systemctl enable nosi-proxmox-hosts.service 2>/dev/null || true

# ---- every boot, once online: real-IP hosts entry + node cert + UI login ---
# The 127.0.1.1 mapping above is only good enough for pmxcfs: `pvecm
# updatecerts` refuses loopback, so a freshly flashed host came up with no
# /etc/pve/local/pve-ssl.pem and the web UI could not complete TLS (observed
# on the first real-hardware boot). Once the network is online (ordered
# Before=pveproxy so the cert exists when the proxy starts): map the live
# hostname to the primary IPv4, regenerate node files, and grant the baked
# operator web-UI admin exactly once (root ships locked, so without this no
# one can log in to :8006). Re-runs every boot so an operator rename or a
# new DHCP lease re-keys the mapping + certs automatically.
nosi_write_if_changed \
'#!/bin/sh
# Managed by nosi/provision/steps/60-proxmox-ve.sh
set -u
log(){ logger -t nosi-proxmox-online "$*" 2>/dev/null; echo "nosi-proxmox-online: $*"; }
hn=$(hostname 2>/dev/null)
[ -n "$hn" ] && [ "$hn" != "localhost" ] || exit 0
ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n "s/.* src \([0-9.]*\).*/\1/p" | head -1)
if [ -n "$ip" ]; then
    sed -i "/ # nosi-proxmox-online\$/d" /etc/hosts
    sed -i "/^127\.0\.1\.1[[:space:]].*[[:space:]]$hn\([[:space:]]\|\$\)/d" /etc/hosts
    printf "%s\t%s.localdomain %s # nosi-proxmox-online\n" "$ip" "$hn" "$hn" >> /etc/hosts
    log "mapped $hn -> $ip"
fi
pvecm updatecerts --silent 2>/dev/null || log "updatecerts failed (retries next boot)"
if [ ! -e /var/lib/nosi/proxmox-admin-granted ]; then
    if pveum user add odus@pam --comment "nosi operator" 2>/dev/null \
        || pveum user list 2>/dev/null | grep -q "odus@pam"; then
        if pveum acl modify / --users odus@pam --roles Administrator 2>/dev/null; then
            mkdir -p /var/lib/nosi
            touch /var/lib/nosi/proxmox-admin-granted
            log "granted odus@pam the Administrator role"
        else
            log "acl grant failed (retries next boot)"
        fi
    fi
fi
exit 0
' /usr/local/sbin/nosi-proxmox-online 0755

nosi_write_if_changed \
'[Unit]
Description=nosi: PVE node identity once online (hosts entry, certs, UI admin)
Wants=network-online.target
After=network-online.target pve-cluster.service
Before=pveproxy.service
ConditionPathExists=/usr/bin/pmxcfs

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nosi-proxmox-online
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
' /etc/systemd/system/nosi-proxmox-online.service 0644
systemctl enable nosi-proxmox-online.service 2>/dev/null || true

# ---- first-boot: directory storage on a blank second disk -----------------
# The operator runs the OS on one NVMe and wants VM/CT storage on a second.
# This oneshot sets that up automatically, but only for a disk that is
# DEFINITELY safe: a whole disk that is not the boot disk, has no partitions,
# and has no filesystem/partition-table signature (wipefs -n is empty). It
# never touches a disk with data, and no-ops once `nvme-data` exists.
nosi_write_if_changed \
'#!/bin/sh
# Managed by nosi/provision/steps/60-proxmox-ve.sh
set -u
log(){ logger -t nosi-proxmox-storage "$*" 2>/dev/null; echo "nosi-proxmox-storage: $*"; }
command -v pvesm >/dev/null 2>&1 || exit 0
pvesm status 2>/dev/null | grep -q "^nvme-data" && exit 0
root_src=$(findmnt -nvo SOURCE / 2>/dev/null)
root_disk=$(lsblk -ndo PKNAME "$root_src" 2>/dev/null)
cand=""
for d in $(lsblk -dno NAME); do
    [ "$(lsblk -dno TYPE /dev/$d 2>/dev/null)" = "disk" ] || continue
    [ "$d" = "$root_disk" ] && continue
    [ -n "$(lsblk -no NAME /dev/$d | tail -n +2)" ] && continue
    [ -n "$(wipefs -n /dev/$d 2>/dev/null)" ] && continue
    cand="$cand $d"
done
set -- $cand
[ "$#" -eq 1 ] || { log "need exactly one blank non-boot disk, found: $* ; skipping"; exit 0; }
disk=/dev/$1
log "formatting $disk as ext4 directory storage"
mkfs.ext4 -q -F -L nosi-vmstore "$disk" || { log "mkfs failed"; exit 0; }
mkdir -p /var/lib/nosi-vmstore
uuid=$(blkid -s UUID -o value "$disk")
grep -q "$uuid" /etc/fstab 2>/dev/null || printf "UUID=%s /var/lib/nosi-vmstore ext4 defaults,nofail 0 2\n" "$uuid" >> /etc/fstab
mount /var/lib/nosi-vmstore 2>/dev/null || true
pvesm add dir nvme-data --path /var/lib/nosi-vmstore --content images,rootdir,iso,vztmpl,backup,snippets || log "pvesm add failed"
log "done: nvme-data on $disk at /var/lib/nosi-vmstore"
' /usr/local/sbin/nosi-proxmox-storage 0755

nosi_write_if_changed \
'[Unit]
Description=nosi: set up a blank second disk as Proxmox directory storage
After=pve-cluster.service pveproxy.service
Wants=pve-cluster.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nosi-proxmox-storage
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
' /etc/systemd/system/nosi-proxmox-storage.service 0644
systemctl enable nosi-proxmox-storage.service 2>/dev/null || true

# ---- helper (manual): create the vmbr0 bridge ------------------------------
# Not run automatically: rewriting /etc/network/interfaces + handing the NIC
# from the base networking to ifupdown2 is best done where it can be verified
# (the web UI does it well). This writes the config + a backup and tells the
# operator to apply it; `ifreload -a` activates it.
nosi_write_if_changed \
'#!/bin/sh
# Managed by nosi/provision/steps/60-proxmox-ve.sh -- create vmbr0 over the
# primary NIC (DHCP). Review, then apply with: ifreload -a
set -u
log(){ echo "nosi-proxmox-mkbridge: $*"; }
ip -o link show type bridge 2>/dev/null | grep -q vmbr0 && { log "vmbr0 already exists"; exit 0; }
nic=$(ip -o route show default 2>/dev/null | sed -n "s/.* dev \([^ ]*\).*/\1/p" | head -1)
[ -n "$nic" ] || { log "no default-route NIC found; aborting"; exit 1; }
cp /etc/network/interfaces /etc/network/interfaces.nosi-bak 2>/dev/null || true
cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

iface $nic inet manual

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports $nic
    bridge-stp off
    bridge-fd 0
EOF
log "wrote vmbr0 over $nic (backup: /etc/network/interfaces.nosi-bak)"
log "apply with: ifreload -a"
' /usr/local/sbin/nosi-proxmox-mkbridge 0755

# Restore normal service-start behavior for the first real boot.
rm -f /usr/sbin/policy-rc.d
apt-get clean

nosi_info "step 60-proxmox-ve done (PVE installed; daemons + storage on first boot)"
