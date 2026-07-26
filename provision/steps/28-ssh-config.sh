#!/usr/bin/env bash
# nosi/provision/steps/28-ssh-config.sh
#
# Make sshd ready for login on every shape: drop a config snippet and
# make sure the daemon is enabled (so it comes up on the next boot of a
# flashed image, and right away on a re-run on a live VM).
#
# /etc/ssh/sshd_config.d/00-nosi.conf, two settings:
#   PasswordAuthentication yes
#       Fedora's sshd_config ships with PasswordAuthentication=no by
#       default, which makes the baked `odus:odus.321` credentials
#       useless without an SSH key. Debian / Ubuntu cloud images ship
#       with it on; the drop-in is redundant there but harmless.
#   PermitRootLogin no
#       Defense in depth on top of step 31-root-lock's `passwd -l root`
#       (and the cloud-init runcmd). If something rotates the root
#       password later, sshd still won't accept root logins.
#
# Enablement: openssh-server's postinst enables ssh.service on
# Debian/Ubuntu, and Fedora Cloud enables sshd.service via preset, so in
# practice the daemon is already on. We enable it explicitly anyway so
# the "ready for login" guarantee does not depend on those defaults (and
# survives a minimal base or an accidental mask). Unit name differs:
# `ssh` on Debian/Ubuntu, `sshd` on Fedora.
#
# Host-key regen: the bake strips /etc/ssh/ssh_host_* at the very end for
# per-instance identity. On Ubuntu the openssh-server stack's
# ssh-keygen handling eventually regenerates them on first boot (ssh.service
# restart-loops for ~30-60s until a separate path regenerates the keys).
# On Debian Trixie that path does NOT trigger reliably without cloud-init
# running cc_ssh -- a flashed bare-metal box without a NoCloud seed sits
# in a permanent ssh.service restart loop forever. Fix is a tiny
# nosi-owned oneshot ordered Before
# ssh.service / ssh.socket that runs `ssh-keygen -A`, which is idempotent
# (only generates missing key types, no-op when keys exist). Pair it with
# a drop-in adding Wants= + After= to ssh.service AND ssh.socket so it
# always runs before either activation path.
#
# Idempotency: nosi_write_if_changed only touches mtime when the content
# differs; enable/unmask are idempotent.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 28-ssh-config"
nosi_require_root

# ---- FreeBSD: base OpenSSH + rc.conf, host keys via rc.d/sshd -------------
# Same intent as the Linux drop-in (password auth on for the baked
# odus:odus.321 creds, no root login), expressed for base OpenSSH:
#   * a /etc/ssh/sshd_config.d/00-nosi.conf drop-in;
#   * base FreeBSD sshd_config ships NO `Include` line, so PREPEND one
#     (sshd uses the FIRST value for each keyword, so prepending makes
#     the drop-in authoritative even if a later base config sets these);
#   * sshd_enable=YES in rc.conf;
#   * NO keygen oneshot: the .user strips /etc/ssh/ssh_host_*, and
#     /etc/rc.d/sshd runs `ssh-keygen -A` on boot when keys are absent,
#     so first boot regenerates per-instance host keys (the Debian-Trixie
#     restart-loop problem does not exist on FreeBSD).
if [ "$NOSI_DISTRO" = "freebsd" ]; then
    mkdir -p /etc/ssh/sshd_config.d
    nosi_write_if_changed \
'# Managed by nosi/provision/steps/28-ssh-config.sh
PasswordAuthentication yes
PermitRootLogin no
' /etc/ssh/sshd_config.d/00-nosi.conf 0644

    if ! grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
        { printf 'Include /etc/ssh/sshd_config.d/*.conf\n\n'; cat /etc/ssh/sshd_config; } \
            > /etc/ssh/sshd_config.nosi && mv /etc/ssh/sshd_config.nosi /etc/ssh/sshd_config
    fi

    sysrc sshd_enable="YES" >/dev/null
    nosi_info "step 28-ssh-config done (freebsd)"
    exit 0
fi

install -d -m 0755 /etc/ssh/sshd_config.d
nosi_write_if_changed \
'# Managed by nosi/provision/steps/28-ssh-config.sh
PasswordAuthentication yes
PermitRootLogin no
' /etc/ssh/sshd_config.d/00-nosi.conf 0644

# ---- nosi-sshd-keygen.service: regen host keys if missing -----------------
# Runs before ssh.service / ssh.socket. ssh-keygen -A only generates the
# missing host-key types and is fast when they all already exist, so this
# is a no-op after the first boot of a flashed image. ConditionFileNotEmpty
# would short-circuit further but ssh-keygen -A is already cheap enough.
nosi_write_if_changed \
'[Unit]
Description=nosi: regenerate any missing SSH host keys
Documentation=man:ssh-keygen(1)
DefaultDependencies=no
After=local-fs.target
Before=ssh.service ssh.socket sshd.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
' /etc/systemd/system/nosi-sshd-keygen.service 0644

# Drop-in on ssh.service. The reliable fix is to regenerate the host keys
# IN-PROCESS as ssh.service's first ExecStartPre, so they exist no matter what
# else did or did not run. Keys are stripped at bake end; on a fresh boot
# ssh.service's own `sshd -t` ExecStartPre (Debian/Ubuntu) fails when they are
# missing, which is the smoketest flake. A separately-ordered oneshot was not
# enough: in the failing boots nosi-sshd-keygen did not run before ssh.service.
# An empty `ExecStartPre=` first RESETS the inherited list, then `ssh-keygen -A`
# (idempotent, only creates missing keys) runs BEFORE the re-added `sshd -t`
# config test, so the keys are guaranteed present when sshd starts. Wants= keeps
# the keygen oneshot best-effort rather than a hard gate.
install -d -m 0755 /etc/systemd/system/ssh.service.d
nosi_write_if_changed \
'[Unit]
Wants=nosi-sshd-keygen.service
After=nosi-sshd-keygen.service

[Service]
ExecStartPre=
ExecStartPre=/usr/bin/ssh-keygen -A
ExecStartPre=/usr/sbin/sshd -t
' /etc/systemd/system/ssh.service.d/10-nosi-keygen.conf 0644

# Same for ssh.socket (socket-activated path on newer Ubuntu). Socket units
# take no ExecStartPre; the keys come from ssh.service's ExecStartPre above
# when the socket activates it. Keep the oneshot ordered ahead, best-effort.
install -d -m 0755 /etc/systemd/system/ssh.socket.d
nosi_write_if_changed \
'[Unit]
Wants=nosi-sshd-keygen.service
After=nosi-sshd-keygen.service
' /etc/systemd/system/ssh.socket.d/10-nosi-keygen.conf 0644

# Same for sshd.service on Fedora: in-process ssh-keygen -A before the config
# test, identical to ssh.service above.
install -d -m 0755 /etc/systemd/system/sshd.service.d
nosi_write_if_changed \
'[Unit]
Wants=nosi-sshd-keygen.service
After=nosi-sshd-keygen.service

[Service]
ExecStartPre=
ExecStartPre=/usr/bin/ssh-keygen -A
ExecStartPre=/usr/sbin/sshd -t
' /etc/systemd/system/sshd.service.d/10-nosi-keygen.conf 0644

# Enablement: openssh-server on Debian/Ubuntu ships BOTH ssh.service and
# (more recent versions) ssh.socket; the cloud image may have either enabled
# by default. Walk every candidate, enable each that actually exists, and
# log the resulting state so the bake log makes "is sshd ready for login?"
# answerable without booting the image. Fedora + Arch ship sshd.service
# only (openssh's unit is named sshd.service on both).
case "$NOSI_DISTRO" in
fedora) ssh_units=(sshd.service) ;;
arch)   ssh_units=(sshd.service) ;;
*)      ssh_units=(ssh.service ssh.socket) ;;
esac

systemctl daemon-reload 2>/dev/null || true

# Enable our keygen oneshot. WantedBy in the unit pulls it in via
# ssh.service and ssh.socket as well, but enable also creates the
# multi-user.target wants symlink as a belt-and-suspenders independent
# activation path.
systemctl enable nosi-sshd-keygen.service 2>/dev/null \
    || nosi_warn "enable nosi-sshd-keygen.service failed"

for u in "${ssh_units[@]}"; do
    if ! systemctl cat "$u" >/dev/null 2>&1; then
        nosi_info "$u not present on this system; skipping"
        continue
    fi
    if ! systemctl unmask "$u" 2>/dev/null; then
        nosi_warn "unmask $u failed"
    fi
    if systemctl enable "$u" 2>/dev/null; then
        nosi_info "enabled $u"
    else
        nosi_warn "enable $u failed"
    fi
done

# On a live system (Hetzner-VM re-run), pick up the new drop-in now. No-op
# at bake time when systemd isn't running for that unit.
for u in "${ssh_units[@]}"; do
    if systemctl is-active --quiet "$u" 2>/dev/null; then
        systemctl reload "$u" 2>/dev/null \
            || systemctl try-restart "$u" 2>/dev/null \
            || nosi_warn "reload/restart $u failed"
    fi
done

# Final visible state. Surfaces in the bake log as e.g.
#   [nosi] ssh.service is-enabled: enabled
#   [nosi] ssh.socket  is-enabled: disabled
# so we can tell from the log alone whether the next boot will start sshd.
for u in "${ssh_units[@]}"; do
    if systemctl cat "$u" >/dev/null 2>&1; then
        state="$(systemctl is-enabled "$u" 2>/dev/null || echo unknown)"
        nosi_info "$u is-enabled: $state"
    fi
done

# ---- firewall: allow SSH (Fedora ships firewalld; Debian doesn't) ----
# Fedora's base carries firewalld enabled by default. The cloud zone
# usually permits ssh already, but a more restrictive default zone
# silently blocks ``ssh`` even though sshd is up and listening. Add the
# ssh service to the permanent config so port 22 is reachable regardless
# of the zone default. ``--permanent`` edits the on-disk zone XML without
# a running daemon (works in the chroot bake); guarded on firewall-cmd so
# it is a no-op on Debian/Ubuntu/RPi OS, and idempotent where ssh is
# already allowed.
if command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1; then
        nosi_info "firewalld: ssh service allowed (permanent)"
    else
        nosi_warn "firewalld present but adding ssh service failed (non-fatal)"
    fi
fi

nosi_info "step 28-ssh-config done"
