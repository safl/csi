#!/usr/bin/env bash
# nosi/provision/steps/98-metadata.sh
#
# Runs near the end of apply.sh (after every tool-install step, before
# 99-motd). Captures the baked image's identity AND inventory into
# /etc/nosi-metadata.json so consumers can answer "what is this image"
# without booting it -- the smoketest scp's the file out so it can ride
# along as an ORAS layer next to the .img.gz.
#
# Sources every fact from the running system rather than from the
# cloud-init template, so the metadata reflects what is ACTUALLY on disk
# (which version of uv landed, which packages dnf pulled in as deps,
# which kernel the cloud image shipped today), not what we intended to
# install. That is the whole point: provenance you can trust.

. "$(dirname "$(readlink -f "$0")")/../lib/common.sh"

nosi_info "step 98-metadata"
nosi_require_root

# ---- FreeBSD: emit the same JSON shape via jq -----------------------------
# The Linux path below leans on apt-mark / dnf repoquery / /lib/modules and
# a big python helper. On FreeBSD identity is single-sourced from
# /etc/nosi-release (step 05 <- /opt/nosi/.nosi-version <- renderer) and the
# JSON is assembled with jq, keeping the top-level shape aligned with Linux
# (nosi / distro / kernel / architecture / operator / packages) so the
# smoketest's nosi.variant assertion and the catalog layer are satisfied.
# FreeBSD does not force-rotate the operator password (step 29 is Linux-only
# and deferred), so default_password_state reflects that.
if [ "$NOSI_DISTRO" = "freebsd" ]; then
    JQ=/usr/local/bin/jq
    [ -x "$JQ" ] || JQ=jq
    command -v "$JQ" >/dev/null 2>&1 || nosi_die "jq missing; required to emit /etc/nosi-metadata.json"
    # shellcheck disable=SC1091
    . /etc/nosi-release
    pretty="$( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-FreeBSD}")"
    "$JQ" -n \
        --arg version "${NOSI_VERSION:-unknown}" \
        --arg shape   "${NOSI_SHAPE:-headless}" \
        --arg variant "${NOSI_VARIANT:-unknown}" \
        --arg built   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg pretty  "$pretty" \
        --arg vid     "${NOSI_DISTRO_VERSION:-unknown}" \
        --arg krel    "$(uname -r)" \
        --arg kver    "$(uname -v)" \
        --arg arch    "$(uname -m)" \
        '{
            nosi: {version: $version, shape: $shape, variant: $variant, built: $built},
            distro: {id: "freebsd", version_id: $vid, version_codename: null, pretty_name: $pretty},
            kernel: {release: $krel, version: $kver},
            architecture: $arch,
            operator: {
                username: "odus", uid: 1000,
                default_password: "odus.321",
                default_password_state: "active (no force-rotate)",
                root_locked: true,
                ssh: {password_auth: true, permit_root_login: false}
            },
            packages: {manager: "pkg"}
        }' > /etc/nosi-metadata.json
    chmod 0644 /etc/nosi-metadata.json
    nosi_info "step 98-metadata done (freebsd, $(wc -c < /etc/nosi-metadata.json) bytes -> /etc/nosi-metadata.json)"
    exit 0
fi

command -v python3 >/dev/null 2>&1 || nosi_die "python3 missing; required to emit /etc/nosi-metadata.json"

python3 - <<'PY' > /etc/nosi-metadata.json
import json
import os
import re
import subprocess
from datetime import datetime, timezone

def run(*cmd, timeout=10):
    """Run a command, return stdout's first line stripped, or None on failure."""
    try:
        p = subprocess.run(
            list(cmd), capture_output=True, text=True, timeout=timeout, check=True,
        )
        line = p.stdout.strip().splitlines()
        return line[0].strip() if line else ""
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        return None

def read_kv(path):
    out = {}
    try:
        with open(path) as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                out[k] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out

def first_version_token(s):
    """Extract the first SemVer-ish token from a --version line. None if none."""
    if not s:
        return None
    m = re.search(r"\b(\d+\.\d+(?:\.\d+)?(?:[-+.][\w.]+)?)\b", s)
    return m.group(1) if m else s.strip() or None

def ver(*cmd):
    raw = run(*cmd, timeout=5)
    return first_version_token(raw)

def image_kernel():
    """Kernel of the IMAGE, not the build host.

    Derives the release from /lib/modules/<release> (present on the
    rootfs), which is correct both when booted on the image (base bake)
    and inside a chroot during a derive -- where `uname -r` would
    instead report the build host's / runner's kernel. `uname -v` (the
    build-string) is only trustworthy when we're actually booted on the
    image (release == uname -r), so it's nulled in the chroot case
    rather than shipping the host's string. For stripped shapes the
    release still reflects what the image was built from (98-metadata
    runs before the strip).
    """
    release = None
    try:
        mods = sorted(
            d for d in os.listdir("/lib/modules")
            if os.path.isdir(os.path.join("/lib/modules", d))
        )
        if mods:
            release = mods[-1]
    except OSError:
        pass
    uname_r = run("uname", "-r")
    if release is None:
        release = uname_r
    version = run("uname", "-v") if release == uname_r else None
    return {"release": release, "version": version}

nosi_release = read_kv("/etc/nosi-release")
osr = read_kv("/etc/os-release")

meta = {
    "nosi": {
        "version": nosi_release.get("NOSI_VERSION"),
        "shape": nosi_release.get("NOSI_SHAPE"),
        "variant": nosi_release.get("NOSI_VARIANT"),
        "built": nosi_release.get("NOSI_BUILT")
                 or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    },
    "distro": {
        "id": osr.get("ID"),
        "version_id": osr.get("VERSION_ID"),
        "version_codename": osr.get("VERSION_CODENAME"),
        "pretty_name": osr.get("PRETTY_NAME"),
    },
    "kernel": image_kernel(),
    "architecture": run("uname", "-m"),
    "operator": {
        "username": "odus",
        "uid": 1000,
        "default_password": "odus.321",
        # Matches step 29-rotate-password: the default is NOT force-expired
        # (the old `chage -d 0` was removed); it just works, and the motd
        # warns at every interactive login until the operator rotates it.
        "default_password_state": "active (default, not force-rotated; motd warns until changed)",
        "root_locked": True,
        "ssh": {
            "password_auth": True,
            "permit_root_login": False,
        },
    },
    "tools": {
        # step 20: upstream-release binaries pulled from GitHub releases
        "upstream_releases": {
            "uv": ver("uv", "--version"),
            "rustc": ver("/usr/local/cargo/bin/rustc", "--version"),
            "rust_analyzer": ver("/usr/local/cargo/bin/rust-analyzer", "--version"),
            "hx": ver("hx", "--version"),
            "zellij": ver("zellij", "--version"),
            "lazygit": ver("lazygit", "--version"),
            "yazi": ver("yazi", "--version"),
            "taplo": ver("taplo", "--version"),
            # marksman --version aborts cleanly when libicu present; if it still
            # fails for some reason, record None rather than blowing up.
            "marksman": ver("marksman", "--version"),
            "oras": ver("oras", "version"),
            # static install from pkgs.tailscale.com; daemon ships disabled.
            # None on the stripped shapes (wsl / docker / lxc remove it).
            "tailscale": ver("tailscale", "version"),
        },
        # step 22: pipx --global installs
        "pipx_global": {
            "ruff": ver("ruff", "--version"),
            "pyright": ver("pyright", "--version"),
            "devbind": ver("devbind", "--version"),
            "hugepages": ver("hugepages", "--version"),
            "iommu": ver("iommu", "--version"),
            # cijoe: base tool (step 22), present on every shape.
            "cijoe": ver("cijoe", "--version"),
        },
    },
}

# Manually-installed packages from the distro's package manager. Captures
# what the cloud-init template's packages: list (plus anything apply.sh
# explicitly installed) put on the system, sorted. Excludes the cloud
# image's pre-baked deps so the output reflects nosi's additions.
distro_id = osr.get("ID")
manual_pkgs = []
if distro_id in ("debian", "ubuntu"):
    out = run("apt-mark", "showmanual", timeout=20)
    if out is not None:
        # run() returns first line; re-run capturing all
        try:
            p = subprocess.run(
                ["apt-mark", "showmanual"],
                capture_output=True, text=True, check=True, timeout=20,
            )
            manual_pkgs = sorted(p.stdout.split())
        except subprocess.SubprocessError:
            pass
elif distro_id == "fedora":
    try:
        p = subprocess.run(
            ["dnf", "repoquery", "--userinstalled", "--qf=%{name}\\n"],
            capture_output=True, text=True, check=True, timeout=60,
        )
        manual_pkgs = sorted({line for line in p.stdout.split() if line})
    except subprocess.SubprocessError:
        pass
elif distro_id == "arch":
    # ``pacman -Qqe`` lists explicitly-installed packages (the pacman
    # analog of apt-mark showmanual / dnf --userinstalled): everything
    # requested by name rather than pulled in as a dependency.
    try:
        p = subprocess.run(
            ["pacman", "-Qqe"],
            capture_output=True, text=True, check=True, timeout=30,
        )
        manual_pkgs = sorted({line for line in p.stdout.split() if line})
    except subprocess.SubprocessError:
        pass

pkg_manager = {
    "debian": "apt", "ubuntu": "apt", "fedora": "dnf", "arch": "pacman",
}.get(distro_id, "unknown")
meta["packages"] = {
    "manager": pkg_manager,
    "manually_installed": manual_pkgs,
    "count": len(manual_pkgs),
}

print(json.dumps(meta, indent=2, sort_keys=False))
PY

chmod 0644 /etc/nosi-metadata.json
nosi_info "step 98-metadata done ($(wc -c < /etc/nosi-metadata.json) bytes -> /etc/nosi-metadata.json)"
