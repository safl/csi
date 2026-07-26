VARIANT ?= debian-13-headless

.DEFAULT_GOAL := help

.PHONY: help deps hooks lint build build-rpi all clean docs-deps docs-html docs-pdf docs-serve docs-clean

help:
	@echo "nosi: headless/desktop system images for bare-metal and VMs (qemu, WSL2, Proxmox), and container images (OCI, LXC)"
	@echo
	@echo "Image targets:"
	@echo "  deps              Install cijoe via pipx"
	@echo "  hooks             Install the pre-commit git hooks (ruff + shellcheck + hygiene)"
	@echo "  lint              Run all pre-commit hooks over the whole tree"
	@echo "  build             Build one base (override VARIANT=...); derived shapes ride along"
	@echo "  build-rpi         Build the Raspberry Pi OS arm64 image + desktop derive (chroot bake)"
	@echo "  all               Build every base"
	@echo "  clean             Remove cijoe artifacts"
	@echo
	@echo "Docs targets:"
	@echo "  docs-deps         pipx install ./docs/tooling"
	@echo "  docs-html         Build HTML docs into docs/_build/html/"
	@echo "  docs-pdf          Build PDF docs (requires LaTeX)"
	@echo "  docs-serve        Live-rebuild on http://localhost:8000"
	@echo "  docs-clean        Remove docs/_build/"
	@echo
	@echo "Bakeable bases (VARIANT=...); each base also produces its derived shapes:"
	@echo "  debian-13-headless    Debian 13 trixie -> derives debian-13-desktop + debian-13-lxc + debian-13-proxmox"
	@echo "  ubuntu-2404-headless  Ubuntu 24.04 noble (HW vendor stacks; cudadev/rocmdev pin here)"
	@echo "  ubuntu-2604-headless  Ubuntu 26.04 resolute -> derives ubuntu-2604-wsl + ubuntu-2604-docker + ubuntu-2604-lxc"
	@echo "  fedora-44-headless    Fedora 44 -> derives fedora-44-desktop + fedora-44-lxc"
	@echo "  arch-headless         Arch Linux rolling (minimal netboot base; NO dev toolchain)"
	@echo "  freebsd-14-headless   FreeBSD 14.4-RELEASE (Phase 1 scaffold)"
	@echo "  freebsd-15-headless   FreeBSD 15.0-RELEASE (Phase 1 scaffold)"
	@echo
	@echo "Raspberry Pi (arm64; chroot bake, use 'make build-rpi' not 'make build'):"
	@echo "  rpios-13-headless     Raspberry Pi OS for Pi 4 + Pi 5 -> derives rpios-13-desktop"
	@echo "  rpios-13-desktop      Sway desktop .img.gz (Pi as a small workstation)"
	@echo
	@echo "Derived shapes (built by their base, not a standalone 'make build VARIANT='):"
	@echo "  debian-13-desktop     Sway desktop .img.gz (preferred daily-driver desktop)"
	@echo "  debian-13-lxc         LXC system-container .tar.zst (Proxmox CT / Incus)"
	@echo "  debian-13-proxmox     Proxmox VE host .img.gz (PVE 9; web UI on :8006 after first boot)"
	@echo "  ubuntu-2604-wsl       WSL2 rootfs .tar.gz (meld/gitk/git-gui via WSLg)"
	@echo "  ubuntu-2604-docker    OCI image (CI bootstrap host; docker pull / GHA container:)"
	@echo "  ubuntu-2604-lxc       LXC system-container .tar.zst (Proxmox CT / Incus)"
	@echo "  fedora-44-desktop     Sway desktop .img.gz (laptop where Debian's HW support falls short)"
	@echo "  fedora-44-lxc         LXC system-container .tar.zst (Proxmox CT / Incus)"
	@echo
	@echo "Current VARIANT=$(VARIANT)"
	@echo "Output (base):"
	@echo "  ~/system_imaging/disk/nosi-$(VARIANT)-x86_64.qcow2"
	@echo "  ~/system_imaging/disk/nosi-$(VARIANT)-x86_64.img.gz (+ .sha256)"
	@echo "Derived shapes land alongside as"
	@echo "  nosi-<variant>-x86_64.img.gz (desktop/proxmox) / nosi-<variant>.tar.gz (wsl) /"
	@echo "  nosi-<variant>.tar.zst (lxc) / a local OCI image (docker)"

deps:
	pipx install cijoe
	pipx ensurepath

# Install the git hooks. pre-commit itself: `pipx install pre-commit`.
# After this, every `git commit` runs ruff (lint+format), shellcheck, and
# the hygiene hooks on the staged files. See .pre-commit-config.yaml.
hooks:
	pre-commit install

# Run the whole hook set over every file (what CI does). Handy before a
# push, or once after `make hooks` to normalise the tree.
lint:
	pre-commit run --all-files

# Build a base. The cijoe pipeline downloads the upstream cloud image,
# resizes it, runs cloud-init in a QEMU VM, snapshots, gzip-publishes,
# and (for bases with a [[...derive]] list) derives their shapes from
# the baked rootfs. Needs qemu-system-x86_64 + KVM; deriving needs sudo
# for qemu-nbd + chroot (and docker for the docker shape).
build:
	cd cijoe && cijoe tasks/build.yaml --monitor -c configs/$(VARIANT).toml

# Raspberry Pi OS (arm64). Not a QEMU bake: loop-mounts the official image and
# runs apply.sh in a chroot (rpi_image_build), then smoketests + packs the
# headless base and the desktop derive. Needs sudo (losetup/mount/chroot) and,
# on an x86 host, binfmt + qemu-user-static; native on an arm64 host. The
# desktop derive rides along (no separate invocation).
build-rpi:
	cd cijoe && cijoe tasks/build-rpi.yaml --monitor -c configs/rpios-13-headless.toml

# Only the bases. ubuntu-2604-wsl / ubuntu-2604-docker / fedora-44-desktop
# are produced by their base's build, not invoked here.
all:
	$(MAKE) build VARIANT=debian-13-headless
	$(MAKE) build VARIANT=ubuntu-2404-headless
	$(MAKE) build VARIANT=ubuntu-2604-headless
	$(MAKE) build VARIANT=fedora-44-headless
	$(MAKE) build VARIANT=arch-headless
	$(MAKE) build VARIANT=freebsd-14-headless
	$(MAKE) build VARIANT=freebsd-15-headless

clean:
	rm -rf cijoe/cijoe-output cijoe/cijoe-archive

# ---------- Docs --------------------------------------------------------

docs-deps:
	$(MAKE) -C docs deps

docs-html:
	$(MAKE) -C docs html

docs-pdf:
	$(MAKE) -C docs pdf

docs-serve:
	$(MAKE) -C docs serve

docs-clean:
	$(MAKE) -C docs clean
