#!/usr/bin/env bash
# nosi/provision/steps/06-package-presence.sh
#
# Pre-flight: verify cloud-init's packages: install actually populated
# the baseline tools. dnf5 (Fedora) aborts the whole transaction on a
# single missing package name, so a typo / rename in the variant's
# userdata cascades to every package being skipped -- and the symptom
# downstream is misleading (apply.sh dies at step 22 with "pipx:
# command not found" rather than naming the package that broke the
# transaction). apt is more forgiving but a baseline missing still
# cascades. This step fires immediately after the identity-log step
# so forensics keep /etc/nosi-release.
#
# Fast-fail with the list of missing tools, no recovery. The
# operator's next move is to check /var/log/cloud-init.log (or the
# smoketest forensics) for the rejected package name.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 06-package-presence"

# Commands that must exist after the baseline package install on every
# base variant: the language + VCS basics, the build toolchain (gcc /
# clang / make / cmake / meson / ninja), and the x86 qemu the docker base
# derives from. Each maps to a package in every base userdata packages:
# list (cloud-init for the cloud variants, packages-rpios-headless.txt
# for the Pi), so a silently-dropped one is caught here rather than
# cascading into a confusing later-step failure (dnf5 aborts the whole
# transaction on one bad name, so a single typo drops everything).
#
# Fedora ships `pkg-config` from `pkgconf-pkg-config`; apt distros from
# the `pkg-config` package. Both expose `pkg-config` on PATH, so the
# command-based check works.
#
# FreeBSD installs its baseline via nuageinit's packages: list (the
# .user), not pipx/gcc/bsdmake -- clang is base, `make` is bsdmake (we
# install gmake), and there is no pipx in the Phase-2a slice. Check the
# binary names that list actually provides (ripgrep->rg, helix->hx,
# git-delta->delta), same as the smoketest's FreeBSD tool assertion.
case "$NOSI_PKGMGR" in
pkg)
    must_have=(
        git git-lfs curl wget jq errno python3
        bash gmake cmake ninja meson pkgconf pahole
        hx zellij btop rg fd fzf direnv gh delta
        wg ipmitool
    )
    ;;
pacman)
    # Arch is the deliberately-lean "minimal netboot base": NO dev
    # toolchain (no base-devel / gcc / cmake / qemu). The tripwire here
    # only asserts what a minimal headless netboot image genuinely needs
    # and what the arch-headless.user actually installs -- the netboot
    # machinery (dracut, nbd-client), python for step 98's metadata
    # emitter, sudo for the operator account, sshd, growpart for step 09,
    # and the pixie live-env flash/inventory tool deps (lshw, partprobe
    # from parted, curl, nvme from nvme-cli). Keep this in lockstep with
    # the .user packages: list -- assert ONLY what that list installs (plus
    # what Arch base guarantees). Notably NO git: it is a dev-tool the other
    # variants carry but this lean base deliberately omits, and the Arch
    # cloud base does not ship it, so asserting it here would abort the bake.
    must_have=(
        python3
        sudo
        sshd
        dracut
        nbd-client
        growpart
        lshw
        partprobe
        curl
        nvme
    )
    ;;
*)
    must_have=(
        git
        git-lfs
        curl
        jq
        errno
        python3
        pipx
        make
        gcc
        pkg-config
        wg
        cmake
        meson
        clang
        pahole
        ipmitool
        qemu-img
        qemu-system-aarch64
    )
    # ninja's binary name differs by packaging: the ninja-build package
    # installs `ninja` on Debian / Ubuntu / Raspberry Pi OS but
    # `ninja-build` on Fedora.
    if [ "$NOSI_PKGMGR" = dnf ]; then
        must_have+=(ninja-build)
    else
        must_have+=(ninja)
    fi
    # qemu emulators. Every image can boot an arm64 guest, so
    # qemu-system-aarch64 is required everywhere (provided by Debian's
    # combined qemu-system-arm package, Fedora's qemu-system-aarch64, and
    # already present on the arm64 Pi). x86 images additionally run x86
    # guests -- the docker base relies on this ("cijoe + qemu are in the
    # base") -- so qemu-system-x86_64 is asserted only on x86.
    if [ "$(uname -m)" = x86_64 ]; then
        must_have+=(qemu-system-x86_64)
    fi
    ;;
esac

missing=()
for cmd in "${must_have[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

if [ ${#missing[@]} -gt 0 ]; then
    nosi_die "cloud-init package install incomplete -- missing baseline tools: ${missing[*]}. \
Likely cause: a typo / nonexistent package name in the variant's cloud-init packages: list caused \
dnf/apt to abort the transaction. Check /var/log/cloud-init.log (or the bake's smoketest-forensics) \
for the rejected name."
fi

# Bake-time tripwire for SILENTLY-dropped packages. cloud-init pre-filters the
# packages: list against the archive, installs what it can, and only WARNS
# about names it could not resolve (renamed/removed, or needing an apt
# component the image's sources don't enable -- this is how the debian images
# shipped for weeks without CPU microcode). That warning lives only in
# /var/log/cloud-init.log, which the end-of-bake `cloud-init clean --logs`
# erases, so it has to be caught HERE while the log still exists (the
# missing-command check above only catches a fully-aborted transaction; a
# partial drop slips past it). Guarded on the log being present so derives
# (chroot, no cloud-init) and FreeBSD (nuageinit) skip it.
if [ -f /var/log/cloud-init.log ] \
    && grep -q 'Failure when attempting to install packages' /var/log/cloud-init.log; then
    nosi_die "cloud-init could not install one or more requested packages (filter warning in \
/var/log/cloud-init.log). A name in the variant's packages: list is unavailable on this \
distro/release -- renamed, dropped, or needs an apt component that isn't enabled. Grep the log \
for 'Failed to install' to see the rejected names."
fi

nosi_info "step 06-package-presence ok"
