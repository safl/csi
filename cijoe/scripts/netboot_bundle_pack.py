"""
Extract the nbdboot netboot bundle from a baked headless nosi image
==================================================================

Runs after ``diskimage_build`` (specifically, after step
``34-netboot-nbdboot-hook`` inside the guest has regenerated the
initrd with the bty nbdboot attach-hook baked in). Attaches the
baked qcow2 via ``qemu-nbd`` (same mechanism ``derive_pack`` uses to
chroot into the rootfs), walks the partitions looking for the
``/boot`` filesystem (the one carrying ``vmlinuz-*`` +
``initrd.img-*`` or ``initramfs-*.img``), copies the newest kernel
+ its matching initrd out, and writes a manifest.

The bundle is what bty + nbdmux fetch at PXE-chain time: the image's
own kernel + initrd, produced at build time so runtime brittleness
(chroot regen on bty-server, apt/dnf mirror availability, gpg
timestamp drift) never enters the picture. See
PLAN-netboot-bundle.md for the full cross-repo sequencing.

Framework detection is content-based: after the shipped initrd is
staged in the bundle, ``unmkinitramfs`` splits it into early + main
cpios and the presence of ``main/var/lib/dracut/hooks/`` decides
framework=dracut. Filename shape (``initrd.img-*`` vs
``initramfs-*.img``) and chroot config (``/etc/dracut.conf.d``,
initramfs-tools stubs) both lie on Ubuntu 26.04, where the two
toolchains coexist and ``update-initramfs`` writes an
initramfs-tools-named file whose contents were built by dracut.
The unpacked-content check is ground truth: whatever dispatches at
boot is what the initrd actually is, and the manifest + strip pass
key off that instead of a filename or config guess.

Reads the new ``netboot`` section of
``system-imaging.images.<image_name>``:

  netboot.bundle_dir      output directory for vmlinuz+initrd+manifest
  netboot.source_disk_ref sibling disk-image OCI ref, recorded in manifest

Retargetable: False
"""

from __future__ import annotations

import errno
import hashlib
import json
import logging as log
import re
from argparse import ArgumentParser
from datetime import UTC, datetime
from pathlib import Path

from buildlib import default_image_name as _default_image_name

# ``qemu-nbd`` binds one qcow2 to /dev/nbd0. derive_pack.py uses the
# same convention; there is no reason to burn a second nbd slot when
# nothing else is attaching to nbd concurrently in the build task.
NBD_DEV = "/dev/nbd0"

# Match ``vmlinuz-<KVER>`` (Debian / Ubuntu / Fedora) but skip the
# ``vmlinuz`` symlink so we always pick the versioned file directly.
_KERNEL_RE = re.compile(r"^vmlinuz-([^/]+)$")

# initramfs-tools writes ``initrd.img-<KVER>``, dracut writes
# ``initramfs-<KVER>.img``; either shape yields KVER.
_INITRD_RES = (
    re.compile(r"^initrd\.img-([^/]+)$"),
    re.compile(r"^initramfs-([^/]+)\.img$"),
)


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--image_name",
        type=str,
        default=None,
        help="Override the system-imaging image to pack. Defaults to "
        "nosi-<variant>-x86_64 (variant from [nosi] in the cijoe config).",
    )


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _find_boot_dir(mount_root: Path) -> tuple[Path, str, Path]:
    """Search mounted partitions for /boot with a vmlinuz-* + initrd match.

    Returns (boot_dir_path, kver, initrd_path). Framework is NOT
    inferred here; the filename shape lies on distros where
    initramfs-tools and dracut coexist (Ubuntu 26.04 writes
    ``initrd.img-<KVER>`` even when the contents were built by
    dracut). Callers decide framework by unpacking the shipped
    initrd; see ``_detect_framework_and_strip_dracut``.

    Raises FileNotFoundError if no partition holds a matching pair.
    """
    # Each subdir under mount_root is a partition mount. Some cloud images
    # (Debian) put /boot on the root partition; others (Ubuntu, Fedora)
    # use a separate /boot. Scan each candidate directory: the root
    # partition exposes /boot as a subdir; a separate boot partition IS
    # the boot filesystem, so its kernel files live at the mount root.
    for part_mount in sorted(mount_root.iterdir()):
        if not part_mount.is_dir():
            continue
        for candidate in (part_mount, part_mount / "boot"):
            if not candidate.is_dir():
                continue
            kernels: list[tuple[Path, str]] = []
            for p in candidate.iterdir():
                if not p.is_file():
                    continue
                km = _KERNEL_RE.match(p.name)
                if km is not None:
                    kernels.append((p, km.group(1)))
            if not kernels:
                continue
            # Pick the highest-versioned kernel: cloud images sometimes
            # leave the base-image kernel + a package-manager-installed
            # newer kernel side by side.
            kernels.sort(key=lambda t: t[1])
            _, kver = kernels[-1]
            for pattern in _INITRD_RES:
                for entry in candidate.iterdir():
                    im = pattern.match(entry.name)
                    if im is not None and im.group(1) == kver:
                        return candidate, kver, entry
    raise FileNotFoundError("no /boot with vmlinuz + matching initrd found in any partition")


def _detect_framework_and_strip_dracut(cijoe, initrd_path: Path) -> str:
    """Decide framework from initrd contents, and if dracut, strip the
    baked ``root=UUID=`` fragment + the initqueue ``devexists-`` polls
    + emergency handlers that would otherwise block nbdboot.

    Returns ``"dracut"`` or ``"initramfs-tools"``. The framework is
    read from ground truth: ``main/var/lib/dracut/hooks/`` inside the
    unpacked initrd exists iff dracut generated the initrd. Filename
    shape and chroot config are both misleading on Ubuntu 26.04,
    where ``update-initramfs`` writes ``initrd.img-<KVER>`` but the
    contents were built by dracut.

    Ubuntu 26.04's cloud-image dracut config bakes the strip targets
    when the image is built with ``hostonly=yes`` (default on Ubuntu
    cloud images). They're correct for the local-disk boot path and
    fatal for netboot: on a netboot the polls never resolve (no
    local disks) and dracut-initqueue blocks for 3 min before
    entering emergency mode. The pixie-nbdboot dracut module can't
    strip them at install() time, since that would break the same
    image booting from a local disk; strip only the copy we ship in
    the bundle.

    Uses ``unmkinitramfs`` to split the initrd into early
    (uncompressed microcode cpio) + main filesystem, edits the main
    tree, then re-cpio's both parts and concatenates, same shape the
    upstream ``mkinitramfs`` produces. Kernel accepts uncompressed
    concatenated cpio initrds fine.

    On initramfs-tools initrds this is a detection-only pass with no
    strip: those dispatch via ``/scripts/${BOOT}`` (which does the
    nbdboot work directly) and never carry the baked root=UUID
    artefacts. If ``unmkinitramfs`` fails or the initrd has no
    ``main/`` split we can't inspect the contents; fall back to
    initramfs-tools since that keeps the strip a no-op and matches
    the historical default for the Debian family.
    """
    import tempfile as _tmp

    work = Path(_tmp.mkdtemp(prefix="nosi-initrd-strip-"))
    try:
        err, _ = cijoe.run_local(f"sudo unmkinitramfs {initrd_path} {work}")
        if err:
            log.warning(f"unmkinitramfs failed on {initrd_path}; assuming initramfs-tools")
            return "initramfs-tools"
        main_dir = work / "main"
        early_dir = work / "early"
        if not main_dir.is_dir():
            log.info(f"initrd {initrd_path} has no ``main/`` split; assuming initramfs-tools")
            return "initramfs-tools"
        # Ground-truth framework check: dracut's runtime dispatcher
        # is a tree of shell hooks staged under /var/lib/dracut/hooks
        # inside the initrd; initramfs-tools doesn't create it.
        # ``sudo test`` because ``unmkinitramfs`` extracts as root
        # and the intermediate dirs may not be world-traversable.
        err, _ = cijoe.run_local(f"sudo test -d {main_dir}/var/lib/dracut/hooks")
        if err:
            log.info(f"initrd {initrd_path} has no dracut hooks; framework=initramfs-tools")
            return "initramfs-tools"
        # Redact + remove the artefact families that pin initrd boot
        # to devices that only exist on a local disk:
        #   * /etc/cmdline.d/20-root-dev.conf pins root=UUID=<rootfs>
        #   * initqueue/finished/devexists-*.sh polls for each fs
        #   * emergency/80-*.sh trips into the emergency shell when the
        #     polls time out
        #   * initrd.target.wants/dev-disk-by*.device symlinks + their
        #     .device.d/ drop-ins pull /boot + /boot/efi filesystem
        #     UUIDs into initrd.target's dependency graph, which
        #     systemd waits ~90s for per device before giving up.
        redact_conf = f"{main_dir}/etc/cmdline.d/20-root-dev.conf"
        finished_glob = f"{main_dir}/var/lib/dracut/hooks/initqueue/finished/devexists-*.sh"
        emergency_glob = f"{main_dir}/var/lib/dracut/hooks/emergency/80-*.sh"
        target_wants = f"{main_dir}/etc/systemd/system/initrd.target.wants"
        device_wants_pat = f"{target_wants}/dev-disk-by*.device"
        device_dropins = f"{main_dir}/etc/systemd/system/dev-disk-by*.device.d"
        cijoe.run_local(f"sudo bash -c ': > {redact_conf}' 2>/dev/null || true")
        cijoe.run_local(f"sudo bash -c 'rm -f {finished_glob}' 2>/dev/null || true")
        cijoe.run_local(f"sudo bash -c 'rm -f {emergency_glob}' 2>/dev/null || true")
        cijoe.run_local(f"sudo bash -c 'rm -f {device_wants_pat}' 2>/dev/null || true")
        cijoe.run_local(f"sudo bash -c 'rm -rf {device_dropins}' 2>/dev/null || true")
        # Repack. cpio order + newc format matches mkinitramfs output.
        cpio = "sudo find . -mindepth 1 -printf '%P\\n' | sudo cpio -H newc -o --quiet"
        cijoe.run_local(f"cd {early_dir} && {cpio} > {work}/initrd.early")
        cijoe.run_local(f"cd {main_dir} && {cpio} > {work}/initrd.main")
        cijoe.run_local(
            f"sudo bash -c 'cat {work}/initrd.early {work}/initrd.main > {initrd_path}.stripped'"
        )
        cijoe.run_local(f"sudo mv {initrd_path}.stripped {initrd_path}")
        cijoe.run_local(f"sudo chown $(id -un):$(id -gn) {initrd_path}")
        log.info(f"stripped dracut root=UUID polls from {initrd_path}")
        return "dracut"
    finally:
        cijoe.run_local(f"sudo rm -rf {work}")


def _connect_qemu_nbd(cijoe, qcow2_path: Path, mount_root: Path):
    """qemu-nbd --connect + partprobe + mount every partition RO."""
    # The ``nbd`` module is loadable on the GHA runners but not loaded
    # by default: ``/dev/nbd0`` is absent until modprobe fires, which
    # makes qemu-nbd fail with ``Failed to open /dev/nbd0: No such
    # file or directory``. ``max_part=8`` matches derive_pack.py so
    # the two scripts inhabit the same nbd device / partition-node
    # layout when they run in the same job.
    cijoe.run_local("sudo modprobe nbd max_part=8")
    # Preemptive disconnect in case a previous aborted run left the
    # device attached; same defensive pattern as derive_pack.
    cijoe.run_local(f"sudo qemu-nbd --disconnect {NBD_DEV} >/dev/null 2>&1 || true")
    err, _ = cijoe.run_local(f"sudo qemu-nbd --connect={NBD_DEV} --read-only {qcow2_path}")
    if err:
        raise RuntimeError(f"qemu-nbd connect failed on {qcow2_path}")
    cijoe.run_local(f"sudo partprobe {NBD_DEV} >/dev/null 2>&1 || true")
    cijoe.run_local("sudo udevadm settle --timeout=10")

    mount_root.mkdir(parents=True, exist_ok=True)
    part_paths = sorted(Path("/dev").glob(f"{Path(NBD_DEV).name}p*"))
    for pn in part_paths:
        target = mount_root / pn.name
        target.mkdir(exist_ok=True)
        # Some partitions (BIOS boot, empty ESB-reserved) refuse to
        # mount cleanly; skip them silently. Only the /boot-carrying
        # one has to succeed for _find_boot_dir to return.
        cijoe.run_local(f"sudo mount -o ro {pn} {target}")


def _cleanup(cijoe, mount_root: Path):
    if mount_root.exists():
        for part_mount in sorted(mount_root.iterdir()):
            if part_mount.is_dir():
                cijoe.run_local(f"sudo umount {part_mount} 2>/dev/null || true")
    cijoe.run_local(f"sudo qemu-nbd --disconnect {NBD_DEV} >/dev/null 2>&1 || true")


def main(args, cijoe):
    image_name = args.image_name or _default_image_name(cijoe)
    images = cijoe.getconf("system-imaging.images", {})
    image = images.get(image_name)
    if not image:
        log.error(f"Image '{image_name}' not found in config")
        return errno.EINVAL

    netboot = image.get("netboot")
    if not netboot:
        # Not an error: images without a [netboot] section explicitly
        # opt out (wsl / lxc / docker never had a kernel to ship). Log
        # + return 0 so build.yaml can leave this step in for every
        # variant unconditionally.
        log.info(f"Image '{image_name}' has no [netboot] section; skipping")
        return 0

    disk = image.get("disk", {})
    qcow2_path = Path(disk["path"])
    bundle_dir = Path(netboot["bundle_dir"])
    source_disk_ref = netboot.get("source_disk_ref", "")

    if not qcow2_path.exists():
        log.error(f"Baked qcow2 not found: {qcow2_path}")
        return errno.ENOENT

    mount_root = qcow2_path.with_suffix(".netboot-mnt")
    try:
        _connect_qemu_nbd(cijoe, qcow2_path, mount_root)
        boot_dir, kver, initrd_src = _find_boot_dir(mount_root)
        log.info(f"Found /boot at {boot_dir}, kver={kver}, initrd_src={initrd_src.name}")

        kernel_src = boot_dir / f"vmlinuz-{kver}"

        bundle_dir.mkdir(parents=True, exist_ok=True)
        vmlinuz_out = bundle_dir / "vmlinuz"
        initrd_out = bundle_dir / "initrd"

        # ``sudo cp`` because the mount inherits the qcow2's UID/GID
        # via qemu-nbd (usually root). Restore ownership after so the
        # sha256 / manifest writes don't need sudo.
        err, _ = cijoe.run_local(f"sudo cp {kernel_src} {vmlinuz_out}")
        if err:
            return err
        err, _ = cijoe.run_local(f"sudo cp {initrd_src} {initrd_out}")
        if err:
            return err
        cijoe.run_local(f"sudo chown -R $(id -un):$(id -gn) {bundle_dir}")

        # Decide framework from the shipped initrd's contents, not
        # from the filename or the chroot's config: Ubuntu 26.04 lays
        # down both initramfs-tools stubs AND the real dracut, so
        # ``update-initramfs`` writes ``initrd.img-<KVER>`` even
        # though the contents were built by dracut. If it's dracut,
        # this call also strips the baked root=UUID artefacts that
        # would otherwise block dracut-initqueue on netboot (no local
        # disks to resolve). The pixie-nbdboot dracut module can't do
        # the strip at install() time; it would break local-disk boot
        # of the same image. Strip only the copy we ship.
        framework = _detect_framework_and_strip_dracut(cijoe, initrd_out)
        log.info(f"Framework={framework}")
        # Recompute sha + size below picks up the modified file.

        manifest = {
            "variant": image_name.replace("nosi-", "").rsplit("-", 1)[0],
            "arch": image_name.rsplit("-", 1)[-1],
            "built_at": datetime.now(UTC).isoformat(timespec="seconds"),
            "kernel_version": kver,
            "framework": framework,
            "source_disk_ref": source_disk_ref,
            "files": {
                "vmlinuz": {
                    "sha256": _sha256(vmlinuz_out),
                    "size": vmlinuz_out.stat().st_size,
                },
                "initrd": {
                    "sha256": _sha256(initrd_out),
                    "size": initrd_out.stat().st_size,
                },
            },
        }
        manifest_path = bundle_dir / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

        # Sidecar sha256s so ORAS consumers can verify each file
        # independently of the manifest.
        for name in ("vmlinuz", "initrd", "manifest.json"):
            f = bundle_dir / name
            (bundle_dir / f"{name}.sha256").write_text(f"{_sha256(f)}  {name}\n")

        log.info(
            f"Wrote netboot bundle to {bundle_dir}: "
            f"vmlinuz={vmlinuz_out.stat().st_size} bytes, "
            f"initrd={initrd_out.stat().st_size} bytes, "
            f"kver={kver}, framework={framework}"
        )
    finally:
        _cleanup(cijoe, mount_root)
        # Best-effort mount_root removal (empty dirs after umount).
        try:
            for d in sorted(mount_root.iterdir()):
                d.rmdir()
            mount_root.rmdir()
        except OSError:
            pass

    return 0
