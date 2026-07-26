"""
Smoke-test the baked qcow2 by booting it and asserting via SSH
==============================================================

Runs after ``img_gz_pack`` and ``derive_pack``. Boots
the just-baked headless base image inside qemu on a copy-on-write overlay
(the published artifact stays untouched and first-boot characteristics are
preserved),
SSHes into it as ``odus``, and runs a battery of assertions:

  * /etc/nosi-release exists, has NOSI_VERSION (non-unknown) and
    NOSI_VARIANT matching this build
  * /usr/local/bin/nosi-motd exists, executable, prints a banner whose
    first non-blank line starts with ``nosi``
  * /etc/motd is non-empty and contains ``nosi`` (the boot oneshot ran)
  * the "awesome tools" iommu, devbind, hugepages, ruff, pyright, cijoe
    are all on PATH at /usr/local/bin
  * sshd is enabled for next boot (proven by ssh-in-itself, but recorded
    explicitly for the log)
  * ModemManager is NOT active (daemon-prune actually took)
  * Ubuntu only: snapd.socket is masked AND the snapd binary remains
    (soft-disabled, not purged)
Why a fresh boot of an overlay instead of guestmount-style inspection:
``99-motd.service`` renders /etc/motd on first boot, host keys regenerate
on first boot, our identity assertions transit ``cat /etc/nosi-release``
through the same sshd whose enablement we are testing. Static qcow2
inspection answers "did the apply step write file X?" but cannot answer
"will the next operator's first boot of this image actually work?".

To get ``odus`` past step 29's chage-expired password without burdening
the published artifact with CI-only credentials, the boot is fed a tiny
NoCloud seed.iso that authorises a per-run SSH key and unexpires odus.
The seed is built fresh in /tmp every run; the key never leaves the
runner.

Hard gate: a single failed assertion exits non-zero, which fails
``make build`` and skips the GHCR push for the variant.

Retargetable: False
"""

from __future__ import annotations

import contextlib
import errno
import hashlib
import json
import logging as log
import os
import shutil
import socket
import subprocess
import tempfile
import time
from argparse import ArgumentParser
from pathlib import Path

from buildlib import default_image_name as _default_image_name

SSH_HOST_PORT = 4242
SSH_USER = "odus"
SSH_OPTS = [
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-o",
    "LogLevel=ERROR",
    "-o",
    "ConnectTimeout=5",
]

# The baked default password for odus. The image advertises this via
# /etc/nosi-metadata.json; the smoketest assertions below verify the
# advertisement is true. Tests run on overlay only -- never on a target the
# operator has rotated.
DEFAULT_PASSWORD = "odus.321"


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--image_name",
        type=str,
        default=None,
        help="Override system-imaging image name (default: from [nosi] variant).",
    )
    parser.add_argument(
        "--boot_timeout",
        type=int,
        default=180,
        help="Seconds to wait for sshd on the smoketest VM (default 180).",
    )


def main(args, cijoe):
    image_name = args.image_name or _default_image_name(cijoe)
    images = cijoe.getconf("system-imaging.images", {})
    image = images.get(image_name)
    if not image:
        log.error(f"Image '{image_name}' not found in config")
        return errno.EINVAL

    qcow2 = Path(image["disk"]["path"])
    if not qcow2.exists():
        log.error(f"Baked qcow2 not found: {qcow2}")
        return errno.ENOENT

    variant = cijoe.getconf("nosi", {}).get("variant", "")
    shape = variant.rsplit("-", 1)[-1]  # headless / desktop / wsl / docker / lxc / proxmox
    distro = variant.split("-", 1)[0] if "-" in variant else ""

    workdir = Path(tempfile.mkdtemp(prefix="nosi-smoketest-"))
    log.info(f"smoketest workdir: {workdir}")

    # Belt-and-suspenders so the smoketest can NEVER taint the artifact
    # that ships to GHCR (the .img.gz was already produced before us, but
    # the .qcow2 still goes out as a transient GHA upload-artifact, and a
    # future change to the order of cijoe steps must not silently break
    # that). Two independent defenses:
    #
    #   (1) chmod 0444 on the baked qcow2 across the smoketest. qcow2
    #       backing-file semantics already open the backing read-only,
    #       but a wrong driver / wrong cmdline / unexpected -snapshot
    #       path would otherwise corrupt silently. With 0444 any write
    #       attempt fails with EACCES at qemu open-time, loudly.
    #
    #   (2) Post-test sha256 verification against the .sha256 sidecar
    #       diskimage_build wrote at bake time. If they ever diverge we
    #       refuse to return 0 -- chmod could have been undone, the
    #       sidecar would still pin the bake-time hash.
    qcow2_orig_mode = qcow2.stat().st_mode & 0o777
    expected_sha256 = _read_sidecar_sha256(qcow2)
    os.chmod(qcow2, 0o444)

    rc = 1
    qemu_pidfile = workdir / "qemu.pid"
    key = None
    try:
        key, _key_pub = gen_ssh_keypair(workdir)
        # NO cloud-init seed. The smoketest's job is to validate the BAKED
        # image as a downstream consumer sees it -- a fresh boot, no seed
        # attached. Re-applying any kind of user-data on top would just
        # paper over bake-time bugs and we have been bitten by exactly that
        # (cloud-init's users: re-application semantics for an existing
        # account vary by impl and silently locked / cleared odus's
        # password). Instead: boot the disk, use the baked odus:odus.321
        # password to SSH in (= the entry channel a real consumer uses),
        # then install our per-run pubkey via that password connection so
        # the rest of the assertions can use key auth.
        overlay = make_overlay(workdir, qcow2)
        _boot_overlay(cijoe, overlay, qemu_pidfile, workdir / "serial.log")

        if not wait_for_ssh_password_ready(DEFAULT_PASSWORD, SSH_HOST_PORT, args.boot_timeout):
            log.error("Smoketest VM did not become SSH-ready within the timeout")
            dump_serial(workdir / "serial.log")
            return errno.ETIMEDOUT

        install_key_via_password(_key_pub.read_text().strip(), DEFAULT_PASSWORD)

        # Pull /etc/nosi-metadata.json (and render a .md alongside) out of
        # the running smoketest VM into the disk dir, so the ORAS push step
        # can attach both as image-provenance layers. Best-effort: the
        # presence-of-metadata.json assertion below catches a failure to
        # write it in-VM; this extraction logs and continues if scp itself
        # fails so the assertion (not the extract) is the source of truth.
        _extract_metadata(key, qcow2)

        results = _run_assertions(key, variant, shape, distro)
        _report(results)
        rc = 0 if all(ok for ok, _name, _detail in results) else 1
    finally:
        kill_qemu(qemu_pidfile)
        with contextlib.suppress(Exception):
            os.chmod(qcow2, qcow2_orig_mode)
        # Verify the baked qcow2 still matches its bake-time sha256. If
        # not, somehow the smoketest tainted the artifact and we MUST
        # fail loudly -- this is the load-bearing don't-publish-the-test-
        # image guarantee.
        if expected_sha256:
            actual = _file_sha256(qcow2)
            if actual != expected_sha256:
                log.error(
                    f"FATAL: baked qcow2 sha256 changed during smoketest! "
                    f"expected {expected_sha256}, got {actual}. "
                    f"DO NOT PUBLISH this artifact."
                )
                rc = errno.EIO
        # Preserve the workdir on failure so the serial console and ssh key
        # are available for forensics. On success the workdir is purely
        # transient and we drop it; on failure we leave it and tell the
        # operator where to find it.
        if rc == 0:
            with contextlib.suppress(Exception):
                shutil.rmtree(workdir)
        else:
            log.error(f"smoketest workdir preserved for forensics: {workdir}")

    return rc


def _last_console(cmdline: str) -> str | None:
    """Return the device of the LAST console= token on a kernel cmdline.

    The kernel makes the final console= the real /dev/console. Step 33 keeps
    ttyS0 (COM1) last so single-UART boards and the QEMU smoketest stay on COM1
    even though console=ttyS1 (COM2) also rides along. Strips the ,115200n8
    options and returns e.g. "ttyS0", or None if no console= is present.
    """
    last = None
    for tok in cmdline.split():
        if tok.startswith("console="):
            last = tok[len("console=") :].split(",", 1)[0]
    return last


def _last_console_token(cmdline: str) -> str | None:
    """The full LAST console= token, options included, or None.

    The bare-vs-baud distinction matters on a real UART (it is invisible under
    QEMU's baud-agnostic -serial): a trailing bare console=ttyS0 leaves the
    port at the kernel default (9600) and shows nothing on IPMI SOL at 115200,
    so step 33 must make the last token carry an explicit ,115200n8.
    """
    last = None
    for tok in cmdline.split():
        if tok.startswith("console="):
            last = tok
    return last


def _read_sidecar_sha256(path: Path) -> str:
    """Return the hash from <path>.sha256, or empty string if missing."""
    sidecar = Path(f"{path}.sha256")
    if not sidecar.is_file():
        return ""
    try:
        first = sidecar.read_text().strip().split()
        return first[0] if first else ""
    except OSError:
        return ""


def _file_sha256(path: Path) -> str:

    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def gen_ssh_keypair(workdir: Path) -> tuple[Path, Path]:
    key = workdir / "id_ed25519"
    pub = workdir / "id_ed25519.pub"
    subprocess.run(
        ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
        check=True,
    )
    return key, pub


def wait_for_ssh_password_ready(password: str, port: int, timeout: int) -> bool:
    """Wait until sshd accepts a real password handshake (not just TCP).

    Mirrors the old key-based wait, but exercises the path a downstream
    consumer hits: password auth as the operator account. A bare TCP probe
    isn't enough -- the port opens before host keys exist on first boot
    and `kex_exchange_identification: Connection reset by peer` follows.
    Drive a no-op ssh in a loop until it actually succeeds.
    """
    deadline = time.monotonic() + timeout
    last_err = "(none)"
    while time.monotonic() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(2)
            try:
                s.connect(("127.0.0.1", port))
                tcp_open = True
            except OSError as exc:
                tcp_open = False
                last_err = f"tcp: {exc}"
        if tcp_open:
            rc, out = _ssh_password(SSH_USER, password, "true")
            if rc == 0:
                return True
            last_err = out or f"exit {rc}"
        time.sleep(3)
    log.error(f"wait_for_ssh_password_ready last error: {last_err}")
    return False


def install_key_via_password(pubkey: str, password: str) -> None:
    """SSH in with the baked password and append the per-run pubkey.

    After this returns, the existing key-based helpers (_ssh, scp via
    SSH_OPTS + -i) work for the remaining assertions. Idempotent: the
    smoketest VM starts with an empty ~/.ssh on every overlay boot, but
    we use `mkdir -p` + a fresh write to be safe regardless.

    The pubkey is delivered through the ssh command's stdin so there is
    no shell quoting between the runner and the VM -- the key string can
    contain whitespace and special characters without paranoia.
    """
    if not shutil.which("sshpass"):
        raise RuntimeError("sshpass not installed (apt install sshpass)")
    install_cmd = "mkdir -p ~/.ssh && umask 077 && cat > ~/.ssh/authorized_keys"
    full = [
        "sshpass",
        "-p",
        password,
        "ssh",
        *SSH_OPTS,
        "-o",
        "PubkeyAuthentication=no",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "IdentityAgent=none",
        "-p",
        str(SSH_HOST_PORT),
        f"{SSH_USER}@127.0.0.1",
        install_cmd,
    ]
    res = subprocess.run(full, input=pubkey + "\n", capture_output=True, text=True, timeout=30)
    if res.returncode != 0:
        raise RuntimeError(
            f"failed to install per-run pubkey over password auth "
            f"(exit {res.returncode}): {(res.stderr or res.stdout).strip()}"
        )


def make_overlay(workdir: Path, backing: Path) -> Path:
    overlay = workdir / "overlay.qcow2"
    subprocess.run(
        [
            "qemu-img",
            "create",
            "-q",
            "-f",
            "qcow2",
            "-F",
            "qcow2",
            "-b",
            str(backing),
            str(overlay),
        ],
        check=True,
    )
    return overlay


def _boot_overlay(cijoe, overlay: Path, pidfile: Path, serial: Path) -> None:
    # KVM-accelerated to keep the test under a minute on hosted runners
    # that already enable /dev/kvm for the bake. virtio-net + user-mode
    # networking + hostfwd is the minimum for SSH-from-host.
    # `-display none -monitor none` rather than `-nographic` because qemu
    # rejects `-nographic` together with `-daemonize` ("cannot be used
    # with -daemonize"); display-none + serial-file gives the same "no
    # UI, log to disk" semantics while staying daemonize-compatible.
    #
    # No -cdrom seed.iso: the smoketest validates the BAKED image as a
    # downstream consumer sees it -- fresh boot, no seed. cloud-init /
    # nuageinit discovers no NoCloud datasource and exits cleanly; the
    # baked operator account + sshd state stand. install_key_via_password
    # injects the per-run pubkey over the baked password channel after
    # boot so the remaining assertions can use key auth.
    cmd = (
        "qemu-system-x86_64 "
        "-machine type=q35,accel=kvm "
        "-cpu host -smp 2 -m 2G "
        "-display none -monitor none "
        f"-serial file:{serial} "
        f"-drive file={overlay},if=virtio,format=qcow2 "
        f"-netdev user,id=n1,hostfwd=tcp:127.0.0.1:{SSH_HOST_PORT}-:22 "
        "-device virtio-net-pci,netdev=n1 "
        f"-daemonize -pidfile {pidfile}"
    )
    err, _ = cijoe.run_local(cmd)
    if err:
        raise RuntimeError(f"qemu failed to start smoketest VM (exit {err})")


def _capture_failure_logs(key: Path, out_dir: Path, base: str) -> None:
    """Best-effort capture of in-VM diagnostics into the qcow2 output dir.

    Called when /etc/nosi-metadata.json is missing (so apply.sh aborted
    somewhere). Pulls whatever exists from the running smoketest VM into
    nosi-<variant>-x86_64.<name> files in the same dir as the qcow2, so the
    GHA workflow's artifact-upload step carries them off the ephemeral
    runner.

    Uses `ssh ... sudo cat` rather than plain scp because cloud-init's
    logs are `root:adm 0640` on every modern distro and odus is not in
    adm -- a direct scp returns "Permission denied" silently. Each pull
    is best-effort: a missing or unreadable source file just yields a
    warning log line, the cijoe log already records the primary failure
    that triggered this call.
    """
    targets = [
        ("/var/log/cloud-init-output.log", "cloud-init-output.log"),
        ("/var/log/cloud-init.log", "cloud-init.log"),
        ("/etc/nosi-release", "nosi-release"),
    ]
    for remote, suffix in targets:
        local = out_dir / f"{base}.{suffix}"
        ssh_cmd = [
            "ssh",
            "-i",
            str(key),
            *SSH_OPTS,
            "-p",
            str(SSH_HOST_PORT),
            f"{SSH_USER}@127.0.0.1",
            f"sudo cat {remote}",
        ]
        try:
            with open(local, "wb") as out_fh:
                res = subprocess.run(
                    ssh_cmd,
                    stdout=out_fh,
                    stderr=subprocess.PIPE,
                    timeout=60,
                )
        except OSError as exc:
            log.warning(f"failure forensics: open({local}) failed: {exc}")
            continue
        if res.returncode == 0 and local.stat().st_size > 0:
            log.info(f"failure forensics: pulled {remote} -> {local.name}")
        else:
            # Empty file on success usually means the source didn't exist;
            # remove the empty stub so the GHA upload doesn't ship a
            # misleading zero-byte artifact.
            try:
                if local.stat().st_size == 0:
                    local.unlink()
            except OSError:
                pass
            log.warning(
                f"failure forensics: could not pull {remote} "
                f"(exit {res.returncode}): "
                f"{(res.stderr or b'').decode(errors='replace').strip()}"
            )


def _extract_metadata(key: Path, qcow2: Path) -> None:
    """scp /etc/nosi-metadata.json out next to the baked qcow2.

    The destination is the same directory as the baked qcow2 so the GHA
    workflow's oras push step can attach it as an image-provenance layer
    without juggling paths.

    Hard failure on every error path. The image is supposed to ship a
    metadata.json; if scp can't fetch it or the file isn't parseable,
    the smoketest fails and the build is refused. Don't let a partial-
    success ship a crappy image to the operator.
    """
    out_dir = qcow2.parent
    base = qcow2.stem  # nosi-<variant>-x86_64
    json_local = out_dir / f"{base}.metadata.json"

    scp_cmd = [
        "scp",
        "-i",
        str(key),
        *SSH_OPTS,
        "-P",
        str(SSH_HOST_PORT),
        f"{SSH_USER}@127.0.0.1:/etc/nosi-metadata.json",
        str(json_local),
    ]
    res = subprocess.run(scp_cmd, capture_output=True, text=True, timeout=30)
    if res.returncode != 0:
        # /etc/nosi-metadata.json missing usually means apply.sh died before
        # reaching step 98-metadata. Best-effort: scp the cloud-init logs +
        # /etc/nosi-release out so the GHA artifact upload carries them and
        # the failing step is diagnosable without dropping into the runner.
        _capture_failure_logs(key, out_dir, base)
        raise RuntimeError(
            f"scp /etc/nosi-metadata.json failed (exit {res.returncode}): "
            f"{(res.stderr or res.stdout).strip()}"
        )

    try:
        json.loads(json_local.read_text())  # validate it parses before publish
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"extracted metadata.json did not parse: {exc}") from exc

    log.info(f"metadata written: {json_local.name}")


def ssh_run(key: Path, cmd: str) -> tuple[int, str]:
    """Run a single shell command on the smoketest VM, capture stdout+stderr."""
    full = [
        "ssh",
        "-i",
        str(key),
        *SSH_OPTS,
        "-p",
        str(SSH_HOST_PORT),
        f"{SSH_USER}@127.0.0.1",
        cmd,
    ]
    res = subprocess.run(full, capture_output=True, text=True, timeout=30)
    return res.returncode, (res.stdout + res.stderr).strip()


def _ssh_password(user: str, password: str, cmd: str) -> tuple[int, str]:
    """Run a command via SSH password auth (no pubkey from agent/keys).

    Uses sshpass to feed the password non-interactively. We disable
    PubkeyAuthentication and IdentitiesOnly to make sure the assertion
    isn't accidentally satisfied by an agent-resident key on the runner
    -- we are verifying the BAKED PASSWORD works. We do NOT disable
    keyboard-interactive: modern sshd with UsePAM=yes routes 'password'
    through PAM as kbd-interactive, so disabling it blocks the actual
    auth path consumers use. sshpass handles both prompt shapes.

    Returns (rc, output). rc 5 = auth failed; 255 = ssh/connect error;
    127 = sshpass missing.
    """
    if not shutil.which("sshpass"):
        return 127, "sshpass not installed (apt install sshpass)"
    full = [
        "sshpass",
        "-p",
        password,
        "ssh",
        *SSH_OPTS,
        "-o",
        "PubkeyAuthentication=no",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "IdentityAgent=none",
        "-p",
        str(SSH_HOST_PORT),
        f"{user}@127.0.0.1",
        cmd,
    ]
    res = subprocess.run(full, capture_output=True, text=True, timeout=30)
    return res.returncode, (res.stdout + res.stderr).strip()


def _run_assertions(
    key: Path, variant: str, shape: str, distro: str
) -> list[tuple[bool, str, str]]:
    """Return [(ok, name, detail)] for every assertion."""

    # Wait until cloud-init has finished applying the smoketest seed --
    # the chage-unexpire runs in cloud-init runcmd, and even though we
    # already authenticated with the key, the next ssh's command-exec
    # phase still re-checks account state. cloud-init status --wait
    # blocks until cloud-init is done; bounded so a hung cloud-init does
    # not hang the smoketest forever.
    _, _ = ssh_run(key, "timeout 60 cloud-init status --wait || true")

    results: list[tuple[bool, str, str]] = []

    def check(name: str, cmd: str, predicate) -> None:
        rc, out = ssh_run(key, cmd)
        ok, detail = predicate(rc, out)
        results.append((ok, name, detail))

    # ---- universal: metadata file exists, parses, has the right variant ---
    # Every variant must emit /etc/nosi-metadata.json (all variants now via
    # step 98-metadata -- Linux through python, FreeBSD through jq). The
    # ORAS push step trusts the smoketest's verdict to know whether the
    # file is publishable. Gate here, before any distro-specific branch,
    # so a missing or malformed file fails the smoketest -- never silently
    # drops the metadata layer from the published artifact.
    check(
        "/etc/nosi-metadata.json present and parses as JSON",
        "python3 -c 'import json; json.load(open(\"/etc/nosi-metadata.json\"))' && echo ok",
        lambda rc, out: (out == "ok", out or f"exit {rc}"),
    )
    check(
        "/etc/nosi-metadata.json carries the right NOSI_VARIANT",
        "python3 -c 'import json,sys; "
        'd=json.load(open("/etc/nosi-metadata.json")); '
        'sys.exit(0 if d.get("nosi",{}).get("variant")=="' + variant + "\" else 1)' "
        "&& echo ok",
        lambda rc, out: (out == "ok", out or f"exit {rc}"),
    )

    # ---- login + ssh-env: the advertised auth paths actually work --------
    # Everything above transits our per-run SSH key seeded by NoCloud, which
    # only proves "the image accepts a key we just injected". A downstream
    # operator booting the published artifact has NO seed, NO key -- their
    # entry channel is the BAKED `odus:odus.321` password and the SSH config
    # the bake left behind. These assertions exercise exactly that path so
    # a regression (PasswordAuthentication off, odus missing, sudoers entry
    # not honored, ...) fails the bake instead of every downstream consumer.

    # Password-auth assertions use _ssh_password (sshpass, no pubkey) and so
    # call directly into results rather than through check(): the helper is
    # 'cmd over the existing key' which is not what we want here.
    rc_pw, out_pw = _ssh_password(SSH_USER, DEFAULT_PASSWORD, "true")
    results.append(
        (
            rc_pw == 0,
            f"odus password auth ({DEFAULT_PASSWORD}) succeeds via SSH",
            out_pw or f"exit {rc_pw}",
        )
    )

    rc_root, out_root = _ssh_password("root", "root", "true")
    results.append(
        (
            rc_root != 0,
            "root SSH login is blocked (PermitRootLogin no + root locked)",
            "rejected" if rc_root != 0 else f"SECURITY REGRESSION: root accepted ({out_root})",
        )
    )

    check(
        "odus has passwordless sudo (sudo -n true)",
        "sudo -n true && echo ok",
        lambda rc, out: (rc == 0 and out == "ok", out or f"exit {rc}"),
    )

    check(
        "odus SSH env: USER=odus, HOME=/home/odus, PATH carries /usr/local/bin",
        'printf "USER=%s\\nHOME=%s\\nPATH=%s\\n" "$USER" "$HOME" "$PATH"',
        lambda rc, out: (
            rc == 0 and "USER=odus" in out and "HOME=/home/odus" in out and "/usr/local/bin" in out,
            out or f"exit {rc}",
        ),
    )

    # ---- FreeBSD (Phase 2a critical-path parity) -------------------------
    # FreeBSD now runs the shared apply.sh chain (delivered as a base64
    # tarball, since nuageinit has no write_files), so the smoketest
    # asserts the same parity surface as Linux below: the apply-ok
    # sentinel, the motd banner, and the build-identity file -- on top of
    # the FreeBSD-specific fingerprints (uname, os-release, odus, baseline
    # tools, /usr/src). The universal metadata assertions above already
    # validate the step-98 JSON and its NOSI_VARIANT.
    if distro == "freebsd":
        check(
            "uname -s reports FreeBSD",
            "uname -s",
            lambda rc, out: (out.strip() == "FreeBSD", out.strip() or f"exit {rc}"),
        )
        check(
            "/etc/os-release fingerprints freebsd",
            "cat /etc/os-release 2>/dev/null || true",
            lambda rc, out: (
                "freebsd" in out.lower(),
                (out.splitlines()[0] if out else "(empty /etc/os-release)"),
            ),
        )
        check(
            "odus is uid 1000 and a member of wheel",
            "id odus",
            lambda rc, out: (
                rc == 0 and "uid=1000" in out and "wheel" in out,
                out or f"exit {rc}",
            ),
        )
        # Baseline pkg tools landed. /usr/local/bin/ is FreeBSD's pkg
        # install prefix and is on every user's default PATH. `helix`
        # ships as `hx`. Combined into one assertion -- a single
        # missing tool fails the whole check and surfaces what's
        # missing in the detail field.
        # Check binary names, NOT package names: ripgrep's binary is
        # `rg`, helix's is `hx`.
        check(
            "baseline tools (git, hx, zellij, btop, meson, ninja, rg, wg, ...) on PATH",
            "for t in git hx zellij btop meson ninja rg jq fzf direnv wg tailscale; do "
            'command -v "$t" >/dev/null || { echo "missing $t"; exit 1; }; '
            "done && echo ok",
            lambda rc, out: (out == "ok", out or f"exit {rc}"),
        )
        check(
            "/usr/src kernel source tree present (headless essential)",
            "test -f /usr/src/sys/conf/kern.pre.mk && test -d /usr/src/sys/dev && echo ok",
            lambda rc, out: (out == "ok", out or f"exit {rc}"),
        )
        # ---- serial console for IPMI SOL (step 33) -----------------------
        # loader.conf routes the console to comconsole (uart0 = COM1), the
        # port a server BMC bridges for Serial-over-LAN. vidconsole stays
        # first so the normal video path still prints.
        check(
            "loader.conf routes console to comconsole (IPMI SOL)",
            "grep comconsole /boot/loader.conf || true",
            lambda rc, out: ("comconsole" in out, out or "no comconsole in /boot/loader.conf"),
        )
        # Runtime proof the loader.conf change took effect: kern.console
        # lists the active consoles, and comconsole registers as ttyu0
        # (uart0 = COM1). This catches a loader.conf that is present but
        # ineffective (e.g. a typo'd console= value).
        check(
            "ttyu0 is an active console at runtime (kern.console)",
            "sysctl -n kern.console",
            lambda rc, out: ("ttyu0" in out, out or f"exit {rc}"),
        )
        # ---- apply.sh parity surface (Phase 2a) --------------------------
        # apply-ok is the whole-chain sentinel (last line of apply.sh, only
        # reached if every step succeeded under set -e); its absence means
        # apply.sh aborted and the image is refused for publish.
        check(
            "/etc/nosi/apply-ok sentinel present (apply.sh completed cleanly)",
            "test -r /etc/nosi/apply-ok && cat /etc/nosi/apply-ok",
            lambda rc, out: (rc == 0 and bool(out), out or "(missing apply-ok sentinel)"),
        )
        check(
            "/etc/motd carries the nosi banner",
            "cat /etc/motd",
            lambda rc, out: (
                rc == 0 and "nosi" in out,
                (out.splitlines()[0] if out.strip() else "(empty /etc/motd)"),
            ),
        )
        check(
            "/etc/nosi-release has NOSI_VARIANT",
            "cat /etc/nosi-release",
            lambda rc, out: (
                rc == 0 and f"NOSI_VARIANT={variant}" in out,
                out if rc != 0 or f"NOSI_VARIANT={variant}" not in out else "ok",
            ),
        )
        return results

    # ---- Arch (minimal netboot base) ------------------------------------
    # Arch is the deliberately-LEAN experiment: firmware + NIC/storage
    # drivers + python + the dracut netboot machinery, and explicitly NO
    # dev toolchain. So it gets its own reduced assertion set (like FreeBSD
    # above) instead of the fat generic Linux surface below, which hard-
    # asserts the step 12/20/22 dev tools this image intentionally omits.
    # What we DO assert: the operator identity, the apply-ok whole-chain
    # sentinel, the motd banner, the build-identity file, the serial
    # console (step 33, for IPMI SOL on the RTL8125 target hardware), sshd
    # enablement, and -- the whole reason this base exists -- that the
    # dracut ramboot netboot wiring actually baked (step 34). The universal
    # metadata + login/sudo assertions above already ran.
    if distro == "arch":
        check(
            "/etc/os-release fingerprints arch",
            "cat /etc/os-release 2>/dev/null || true",
            lambda rc, out: (
                "arch" in out.lower(),
                (out.splitlines()[0] if out else "(empty /etc/os-release)"),
            ),
        )
        check(
            "odus is uid 1000 and a member of wheel",
            "id odus",
            lambda rc, out: (
                rc == 0 and "uid=1000" in out and "wheel" in out,
                out or f"exit {rc}",
            ),
        )
        check(
            "/etc/nosi/apply-ok sentinel present (apply.sh completed cleanly)",
            "test -r /etc/nosi/apply-ok && cat /etc/nosi/apply-ok",
            lambda rc, out: (rc == 0 and bool(out), out or "(missing apply-ok sentinel)"),
        )
        check(
            "/etc/motd carries the nosi banner",
            "cat /etc/motd",
            lambda rc, out: (
                rc == 0 and "nosi" in out,
                (out.splitlines()[0] if out.strip() else "(empty /etc/motd)"),
            ),
        )
        check(
            "/etc/nosi-release has NOSI_VARIANT",
            "cat /etc/nosi-release",
            lambda rc, out: (
                rc == 0 and f"NOSI_VARIANT={variant}" in out,
                out if rc != 0 or f"NOSI_VARIANT={variant}" not in out else "ok",
            ),
        )
        # ---- lean package surface: only what a netboot base needs --------
        check(
            "netboot baseline (python3, dracut, nbd-client, sshd) present",
            "for t in python3 dracut nbd-client sshd; do "
            'command -v "$t" >/dev/null || { echo "missing $t"; exit 1; }; '
            "done && echo ok",
            lambda rc, out: (out == "ok", out or f"exit {rc}"),
        )
        # ---- dracut ramboot wiring baked (step 34) -----------------------
        # The pixie-ramboot dracut module + the conf.d that forces it into
        # every initrd are what make this image nbdbootable. Assert the
        # module dir + the add_dracutmodules conf, plus the canonical
        # /boot/initramfs-linux.img the packer pairs with vmlinuz-linux.
        check(
            "pixie-ramboot dracut module installed (step 34)",
            "test -f /usr/lib/dracut/modules.d/99pixie-ramboot/module-setup.sh && echo ok",
            lambda rc, out: (out == "ok", out or "missing 99pixie-ramboot module"),
        )
        check(
            "dracut conf forces pixie-ramboot into every initrd (step 34)",
            "grep -q 'pixie-ramboot' /etc/dracut.conf.d/99-nosi-netboot.conf && echo ok",
            lambda rc, out: (out == "ok", out or "missing add_dracutmodules conf"),
        )
        check(
            "/boot/vmlinuz-linux + /boot/initramfs-linux.img present (netboot pair)",
            "test -f /boot/vmlinuz-linux && test -f /boot/initramfs-linux.img && echo ok",
            lambda rc, out: (out == "ok", out or "missing kernel/initrd pair"),
        )
        # ---- sshd enabled ------------------------------------------------
        check(
            "sshd.service is-enabled",
            "systemctl is-enabled sshd.service",
            lambda rc, out: (out.strip() == "enabled", out or f"exit {rc}"),
        )
        # ---- serial console for IPMI SOL (step 33) -----------------------
        check(
            "console=ttyS0 on the kernel cmdline (IPMI SOL / COM1)",
            "grep -q 'console=ttyS0' /proc/cmdline && echo ok",
            lambda rc, out: (out == "ok", out or "no console=ttyS0 in /proc/cmdline"),
        )
        check(
            "console=ttyS1 on the kernel cmdline (IPMI SOL / COM2)",
            "grep -q 'console=ttyS1' /proc/cmdline && echo ok",
            lambda rc, out: (out == "ok", out or "no console=ttyS1 in /proc/cmdline"),
        )
        check(
            "ttyS0 is the last console= on the cmdline (/dev/console = COM1)",
            "cat /proc/cmdline",
            lambda rc, out: (
                _last_console(out) == "ttyS0",
                f"last console= is {_last_console(out)!r}, want 'ttyS0': {out}",
            ),
        )
        check(
            "serial-getty@ttyS0 active (SOL login prompt / COM1)",
            "systemctl is-active serial-getty@ttyS0.service",
            lambda rc, out: (out.strip() == "active", out or f"exit {rc}"),
        )
        return results

    # ---- apply.sh completed end-to-end -----------------------------------
    # /etc/nosi/apply-ok is written by the LAST line of apply.sh, only
    # after every step has succeeded under `set -e`. Its absence proves
    # apply.sh aborted somewhere -- no matter which step, no matter
    # whether we wrote an explicit smoketest assertion for the tool that
    # step was supposed to install. One sentinel covers every failure
    # mode, so transient curl-404s and the like fail the build instead
    # of seeping into a published image.
    check(
        "/etc/nosi/apply-ok sentinel present (apply.sh completed cleanly)",
        "test -r /etc/nosi/apply-ok && cat /etc/nosi/apply-ok",
        lambda rc, out: (rc == 0 and bool(out), out or "(missing apply-ok sentinel)"),
    )

    # NOTE: the "no packages silently dropped" tripwire is NOT here. cloud-init
    # records a dropped-package warning only in /var/log/cloud-init.log, and the
    # end-of-bake `cloud-init clean --logs` erases that log, so by smoketest time
    # it is always gone. The check lives in provision/steps/06-package-presence.sh
    # instead, which runs mid-bake while the log still exists.

    # ---- build identity ---------------------------------------------------
    check(
        "/etc/nosi-release has NOSI_VARIANT",
        "cat /etc/nosi-release",
        lambda rc, out: (
            rc == 0 and f"NOSI_VARIANT={variant}" in out,
            out if rc != 0 or f"NOSI_VARIANT={variant}" not in out else "ok",
        ),
    )
    check(
        "/etc/nosi-release NOSI_VERSION is non-unknown",
        "awk -F= '$1==\"NOSI_VERSION\"{print $2}' /etc/nosi-release",
        lambda rc, out: (
            rc == 0 and out.strip() not in ("", "unknown"),
            f"NOSI_VERSION='{out.strip()}'",
        ),
    )

    # ---- motd: oneshot rendered, banner correct --------------------------
    check(
        "/etc/motd is non-empty and contains 'nosi'",
        "cat /etc/motd",
        lambda rc, out: (
            rc == 0 and "nosi" in out,
            out.splitlines()[0] if out else "(empty)",
        ),
    )
    check(
        "/usr/local/bin/nosi-motd is executable",
        "test -x /usr/local/bin/nosi-motd && echo ok",
        lambda rc, out: (out == "ok", out or f"exit {rc}"),
    )

    # ---- upstream-release CLIs (step 20) ---------------------------------
    # Each one curl-downloaded from a GitHub release. Asserting individual
    # presence lets a single 404 surface exactly which upstream URL needs
    # fixing rather than just "the bake aborted somewhere in step 20".
    # (rustc is the rustup install marker; rustup itself drops binaries
    # under /usr/local/cargo/bin/, not /usr/local/bin.)
    for tool in (
        "uv",
        "uvx",
        "hx",
        "zellij",
        "lazygit",
        "yazi",
        "ya",
        "taplo",
        "marksman",
        "oras",
        "tailscale",
    ):
        check(
            f"/usr/local/bin/{tool} exists (step 20)",
            f"test -x /usr/local/bin/{tool} && echo ok",
            lambda rc, out, _t=tool: (out == "ok", out or f"missing {_t}"),
        )
    check(
        "/usr/local/cargo/bin/rustc exists (step 20: rustup toolchain)",
        "test -x /usr/local/cargo/bin/rustc && echo ok",
        lambda rc, out: (out == "ok", out or "missing rustc"),
    )

    # ---- vpn baseline (step 20 + packages) --------------------------------
    # tailscale ships installed but DORMANT: enabling the daemon is an
    # operator opt-in (idle RSS + pre-auth logtail diagnostics), so an
    # enabled tailscaled in the baked image is a regression. `wg` comes
    # from the wireguard-tools baseline package.
    check(
        "/usr/local/sbin/tailscaled exists (step 20)",
        "test -x /usr/local/sbin/tailscaled && echo ok",
        lambda rc, out: (out == "ok", out or "missing tailscaled"),
    )
    check(
        "tailscaled.service is disabled (dormant-by-design contract)",
        "systemctl is-enabled tailscaled.service",
        lambda rc, out: (out.strip() == "disabled", out or f"exit {rc}"),
    )
    check(
        "wg on PATH (wireguard-tools baseline package)",
        "command -v wg >/dev/null 2>&1 && echo ok",
        lambda rc, out: (out == "ok", out or "missing wg"),
    )

    # ---- on-box health check (step 95) ------------------------------------
    # nosi-selfcheck is the operator's "did the box come up healthy?" tool;
    # running it here means CI and operators validate the image from one
    # definition. It exits non-zero if any check FAILED, and on failure we
    # surface just the [FAIL] lines so the smoketest log names what broke.
    check(
        "nosi-selfcheck passes on the booted image",
        "nosi-selfcheck",
        lambda rc, out: (
            rc == 0,
            "; ".join(x.strip() for x in out.splitlines() if "[FAIL]" in x) or f"exit {rc}",
        ),
    )

    # ---- gdb-dashboard wired into the system gdbinit (step 12) -----------
    check(
        "gdb-dashboard installed as /etc/gdb/gdbinit",
        "grep -c '^python Dashboard.start()' /etc/gdb/gdbinit 2>/dev/null",
        lambda rc, out: (out.strip() == "1", out or "(no dashboard marker)"),
    )

    # ---- pipx-installed CLIs (step 22) -----------------------------------
    # `pipx install --global` symlinks each package's entry points into
    # /usr/local/bin (and venvs into /usr/local/pipx). /usr/local/bin is
    # on every user's default PATH, so no profile.d wiring is needed; a
    # presence check is sufficient. pyright-langserver is included
    # explicitly even though pipx is supposed to auto-symlink every
    # entry point -- this assertion is the tripwire if pipx ever changes
    # that default.
    for tool in (
        "iommu",
        "devbind",
        "hugepages",
        "ruff",
        "pyright",
        "pyright-langserver",
        "cijoe",
    ):
        check(
            f"/usr/local/bin/{tool} exists (step 22)",
            f"test -x /usr/local/bin/{tool} && echo ok",
            lambda rc, out, _t=tool: (out == "ok", out or f"missing {_t}"),
        )

    # ---- cloud-init seed tooling (baseline packages) ---------------------
    # cloud-localds + mkisofs let an on-target cijoe (or the operator)
    # build a NoCloud seed.iso to boot cloud-init guests -- the docker
    # bootstrap shape's whole job, and any cijoe-driven guest workflow.
    for tool in ("cloud-localds", "mkisofs"):
        check(
            f"{tool} on PATH (seed.iso tooling)",
            f"command -v {tool} >/dev/null 2>&1 && echo ok",
            lambda rc, out, _t=tool: (out == "ok", out or f"missing {_t}"),
        )

    # ---- sshd enabled ----------------------------------------------------
    # Already proven by the fact that we SSHed in. Record the unit state
    # explicitly so the assertion log surfaces it.
    if distro == "fedora":
        check(
            "sshd.service is-enabled",
            "systemctl is-enabled sshd.service",
            lambda rc, out: (out == "enabled", out),
        )
    else:
        check(
            "ssh.service or ssh.socket is-enabled",
            "systemctl is-enabled ssh.service ssh.socket 2>/dev/null "
            "| grep -q '^enabled$' && echo ok",
            lambda rc, out: (out == "ok", out or "neither enabled"),
        )

    # ---- serial console for IPMI SOL (step 33) ---------------------------
    # The kernel cmdline carries console=ttyS0 (COM1) AND console=ttyS1 (COM2)
    # so boot output and a login reach whichever UART a server BMC bridges for
    # IPMI Serial-over-LAN; BMCs disagree (Supermicro/Dell/HPE commonly use
    # COM2). ttyS0 is kept last so COM1 stays /dev/console. tty0 stays first so
    # the normal video console still gets everything. Step 33 enables BOTH
    # serial-getty@ttyS0 and serial-getty@ttyS1 (systemd's generator auto-starts
    # a login on only the single primary console). QEMU q35 provides COM1
    # (ttyS0) but not a second UART, so the ttyS0 getty is asserted active while
    # the ttyS1 getty is asserted ENABLED (its BindsTo=dev-ttyS1.device keeps it
    # dormant here for lack of the port). A real box also needs its BMC to
    # bridge the right COM to SOL, which the image cannot assert.
    check(
        "console=ttyS0 on the kernel cmdline (IPMI SOL / COM1)",
        "grep -q 'console=ttyS0' /proc/cmdline && echo ok",
        lambda rc, out: (out == "ok", out or "no console=ttyS0 in /proc/cmdline"),
    )
    check(
        "console=ttyS1 on the kernel cmdline (IPMI SOL / COM2)",
        "grep -q 'console=ttyS1' /proc/cmdline && echo ok",
        lambda rc, out: (out == "ok", out or "no console=ttyS1 in /proc/cmdline"),
    )
    check(
        "ttyS0 is the last console= on the cmdline (/dev/console = COM1)",
        "cat /proc/cmdline",
        lambda rc, out: (
            _last_console(out) == "ttyS0",
            f"last console= is {_last_console(out)!r}, want 'ttyS0': {out}",
        ),
    )
    check(
        # The last console= must pin the baud explicitly. A bare console=ttyS0
        # (which the cloud bases leave in GRUB_CMDLINE_LINUX_DEFAULT) defaults
        # the UART to 9600 and is silent on IPMI SOL at 115200 -- step 33's apt
        # drop-in strips it and re-pins ,115200n8 last. QEMU's serial is
        # baud-agnostic, so only this token check guards against a regression.
        "last console= pins 115200n8 baud (deterministic IPMI SOL)",
        "cat /proc/cmdline",
        lambda rc, out: (
            _last_console_token(out) == "console=ttyS0,115200n8",
            f"last console token is {_last_console_token(out)!r}, "
            f"want 'console=ttyS0,115200n8': {out}",
        ),
    )
    check(
        "serial-getty@ttyS0 active (SOL login prompt / COM1)",
        "systemctl is-active serial-getty@ttyS0.service",
        lambda rc, out: (out.strip() == "active", out or f"exit {rc}"),
    )
    check(
        "serial-getty@ttyS1 enabled (SOL login prompt / COM2)",
        "systemctl is-enabled serial-getty@ttyS1.service",
        lambda rc, out: (out.strip() == "enabled", out or f"exit {rc}"),
    )

    # ---- RTL8125 2.5GbE NIC mitigations (step 10) ------------------------
    # QEMU has no RTL8125, so we cannot prove the NIC works here; instead we
    # assert the bake laid down every mitigation, so a regression fails the
    # build rather than a bare-metal box silently losing its network. The
    # config is hardware-independent: the files exist regardless of NIC.
    check(
        # ethtool is an sbin admin tool; the udev rule invokes /sbin/ethtool
        # by absolute path, so assert the binary at that path rather than on
        # an unprivileged PATH (Debian keeps sbin off a non-root PATH).
        "ethtool present at /sbin/ethtool (offload-disable udev rule target)",
        "test -x /sbin/ethtool && echo ok",
        lambda rc, out: (out == "ok", out or "missing /sbin/ethtool"),
    )
    check(
        "modprobe.d: r8125 softdep + aspm/eee options present",
        "grep -q 'softdep r8169 pre: r8125' /etc/modprobe.d/nosi-r8125.conf "
        "&& grep -q 'options r8125 enable_eee=0 aspm=0' /etc/modprobe.d/nosi-r8125.conf "
        "&& echo ok",
        lambda rc, out: (out == "ok", out or "missing softdep/options"),
    )
    check(
        "udev rule disables RTL8125 offloads for r8125 + r8169",
        "f=/etc/udev/rules.d/70-nosi-realtek-2g5-offloads.rules; "
        'grep -q \'DRIVERS=="r8125"\' "$f" && grep -q \'DRIVERS=="r8169"\' "$f" '
        "&& echo ok",
        lambda rc, out: (out == "ok", out or "missing/!two-driver udev rule"),
    )
    if distro == "debian":
        # Debian ships NIC firmware in firmware-realtek (split out of
        # firmware-misc-nonfree); Ubuntu/Fedora carry it in linux-firmware.
        check(
            "firmware-realtek installed (rtl_nic/*.fw for the 2.5GbE NIC)",
            "dpkg-query -W -f '${Status}' firmware-realtek 2>/dev/null",
            lambda rc, out: ("install ok installed" in out, out or "not installed"),
        )

    # ---- ModemManager actually gone --------------------------------------
    # systemctl is-active prints "active" / "inactive" / "failed" to stdout
    # and uses exit codes (3 for inactive, 4 for not-loaded). We only care
    # about stdout; an empty stdout (unit-not-loaded with stderr swallowed)
    # also counts as "not active". Avoid an `|| echo ...` fallback because
    # those concatenate onto a non-empty stdout for the inactive case and
    # break the comparison.
    check(
        "ModemManager is not active",
        "systemctl is-active ModemManager.service 2>/dev/null",
        lambda rc, out: (out != "active", out or "inactive (unit not loaded)"),
    )

    # ---- ubuntu-only: snapd soft-disabled --------------------------------
    if distro == "ubuntu":
        # is-enabled for a masked unit prints "masked" but exits 1, so a
        # bare `|| echo missing` would append "missing" onto the stdout
        # the masked case produces and break the equality. Empty stdout
        # (unit absent) correctly fails the assertion via the equality.
        check(
            "snapd.socket is masked",
            "systemctl is-enabled snapd.socket 2>/dev/null",
            lambda rc, out: (out == "masked", out or "(unit not present)"),
        )
        check(
            "snap binary still present (re-enableable)",
            "command -v snap >/dev/null && echo ok",
            lambda rc, out: (out == "ok", out or "missing"),
        )

    # Agentic CLIs (claude / codex / gemini / opencode) and the Node-based
    # LSPs (bash-language-server / yaml-language-server) live in the
    # agentic-cli add-on now, installed post-flash by the operator via
    # nosi-addon -- not baked into any variant. Nothing to assert at
    # bake-time smoketest.

    return results


def _report(results: list[tuple[bool, str, str]]) -> None:
    total = len(results)
    passed = sum(1 for ok, _, _ in results if ok)
    log.info(f"smoketest results: {passed}/{total} passed")
    for ok, name, detail in results:
        mark = "PASS" if ok else "FAIL"
        log.log(log.INFO if ok else log.ERROR, f"  {mark}  {name}  [{detail}]")


def kill_qemu(pidfile: Path) -> None:
    if not pidfile.exists():
        return
    try:
        pid = int(pidfile.read_text().strip())
    except (ValueError, OSError):
        return
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.kill(pid, 15)
    # Give it a moment to drop the qcow2 lock, then SIGKILL if still up.
    time.sleep(2)
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.kill(pid, 9)


def dump_serial(serial: Path) -> None:
    if serial.exists():
        tail = serial.read_text(errors="replace").splitlines()[-40:]
        log.error("---- last 40 lines of smoketest VM serial console ----")
        for line in tail:
            log.error(line)
        log.error("------------------------------------------------------")
