"""
Render a nosi cloud-init user-data file with provision/ scripts inlined
======================================================================

The cloud-init templates under ``nosi-media/auxiliary/`` can contain a
single marker line, anywhere inside a YAML ``write_files:`` list:

    write_files:
      # __NOSI_PROVISION_FILES__
      ... other entries ...

This script replaces that marker with one ``write_files:`` entry per
file under ``provision/`` (apply.sh, lib/*.sh, steps/*.sh), pointing each
target at ``/opt/nosi/provision/<relative path>`` and chmod 0755. The
output is written next to the source as ``<name>.rendered.user`` (or to
an explicit ``--out`` path).

FreeBSD's nuageinit does not honour ``write_files:``, so FreeBSD
templates instead carry a single-quoted ``'__NOSI_PROVISION_TARBALL__'``
token used as an ``echo`` argument in a ``runcmd`` item. It is replaced
with a deterministic, one-line base64-encoded gzip tarball of the same
``provision/`` tree (plus ``.nosi-version``), which the runcmd decodes +
extracts into ``/opt/nosi/`` before invoking apply.sh. One line (not a
block scalar / heredoc) because nuageinit does not reliably deliver
multi-line runcmd content. All markers are optional and independent;
``__NOSI_VERSION__`` is always substituted.

The bake (``diskimage_build.py``) calls into ``render()`` directly so
templates pass through this step before the NoCloud seed iso is built.
Templates with no marker are copied verbatim, so existing variants keep
working until their inline blocks get migrated.

Retargetable: False
"""

from __future__ import annotations

import base64
import gzip
import io
import logging as log
import os
import tarfile
from argparse import ArgumentParser
from datetime import UTC, datetime
from pathlib import Path

MARKER = "__NOSI_PROVISION_FILES__"
MARKER_TARBALL = "__NOSI_PROVISION_TARBALL__"


def _resolve_version(repo_root: Path) -> str:
    """Return the build identifier for this bake.

    Preference order:
      1. ``NOSI_VERSION`` env var (the CI workflow pins this to the
         ISO-week rolling tag from .github/workflows/build.yml).
      2. ``YYYY.WNN`` (ISO 8601 year + zero-padded ISO week) derived
         from the current UTC time, matching what build.yml computes
         via ``date -u +'%G.W%V'``. Used on a local bake where
         ``NOSI_VERSION`` was not set.
      3. literal ``"unknown"`` (no clock available; should not happen
         on a real bake host).

    Captured here on the host so the baked image carries a stable
    identifier that survives ``cloud-init clean`` and is readable by
    provision/steps/05-nosi-release.sh from /opt/nosi/.nosi-version.

    Note: a git short-sha is intentionally NOT appended any more.
    Within a single ISO week multiple bakes share the W-tag (matching
    the release policy: clobber within the week, durable across
    weeks). For a per-commit identifier, set ``NOSI_VERSION`` from
    the caller.
    """
    env_ver = os.environ.get("NOSI_VERSION")
    if env_ver:
        return env_ver.strip()

    # repo_root is accepted for API stability with prior versions, but the
    # ISO-week tag is purely time-derived now, so no git call is needed.
    del repo_root
    return datetime.now(UTC).strftime("%G.W%V")


def add_args(parser: ArgumentParser):
    parser.add_argument(
        "--src",
        type=Path,
        required=True,
        help=(
            "Path to the cloud-init template "
            "(e.g. nosi-media/auxiliary/cloudinit-headless-debian-13.user)"
        ),
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Output path. Defaults to <src>.rendered.user next to the source.",
    )
    parser.add_argument(
        "--provision-root",
        type=Path,
        default=None,
        help="Path to the provision/ tree. Defaults to <repo-root>/provision.",
    )


def _provision_files(provision_root: Path) -> list[Path]:
    """Sorted list of every file under ``provision/``.

    Historically this filtered to ``.sh`` + ``apply.sh`` for the flat
    ``apply.sh + lib/*.sh + steps/*.sh`` layout. The layout has since
    grown ``netboot/`` with assets that don't (and can't) end in
    ``.sh`` -- the dracut config drop-in
    ``netboot/dracut/conf.d/99-nosi-netboot.conf`` must end in ``.conf``
    for dracut to read it. Include every file so subtrees can ship
    whatever mix of names they need.
    """
    return sorted(p for p in provision_root.rglob("*") if p.is_file())


def _build_provision_tarball(provision_root: Path, version: str) -> bytes:
    """Deterministic gzip tarball of the provision/ tree + .nosi-version.

    Rooted so ``tar -C /opt/nosi -xpf -`` yields ``/opt/nosi/provision/...``
    and ``/opt/nosi/.nosi-version``. Determinism (byte-identical output for
    the same inputs) is deliberate for reproducible builds: gzip mtime=0,
    every TarInfo mtime/uid/gid fixed, members sorted, USTAR format (no
    variable PAX headers). The only varying input is ``version``.
    """
    members: list[tuple[str, bytes, int]] = []
    for fp in _provision_files(provision_root):
        rel = fp.relative_to(provision_root.parent).as_posix()  # provision/...
        members.append((rel, fp.read_bytes(), 0o755))
    members.append((".nosi-version", f"{version}\n".encode(), 0o644))
    members.sort(key=lambda m: m[0])

    raw = io.BytesIO()
    gz = gzip.GzipFile(fileobj=raw, mode="wb", mtime=0)
    with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, data, mode in members:
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            ti.mtime = 0
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            ti.mode = mode
            tar.addfile(ti, io.BytesIO(data))
    gz.close()
    return raw.getvalue()


def _expand_tarball_marker(template: str, provision_root: Path, version: str) -> str:
    """Replace the single-quoted '__NOSI_PROVISION_TARBALL__' token (an echo
    argument in a FreeBSD runcmd item) with the base64 tarball as ONE line.

    Single-line on purpose: FreeBSD's nuageinit does not reliably deliver a
    multi-line YAML block scalar / shell heredoc to the runcmd shell, so the
    tarball ships as a plain single-line ``echo '<base64>' | ... | tar``
    list item instead. Base64's alphabet (A-Za-z0-9+/=) contains no single
    quote, so the surrounding quotes stay intact. Only the *quoted* token is
    replaced; the bare name may still appear in comments, untouched. No-op
    when the quoted token is absent.
    """
    token = f"'{MARKER_TARBALL}'"
    if token not in template:
        return template
    b64 = base64.b64encode(_build_provision_tarball(provision_root, version)).decode("ascii")
    return template.replace(token, f"'{b64}'")


def render(src: Path, provision_root: Path) -> str:
    """Return the user-data text with markers expanded.

    Three markers are honoured, all optional and independent:

      * ``__NOSI_VERSION__`` is replaced inline anywhere in the template
        with the build identifier (ISO-week tag from the runner's clock,
        or the ``NOSI_VERSION`` env var). Always substituted.

      * a single-quoted ``'__NOSI_PROVISION_TARBALL__'`` token (an echo
        argument in a ``runcmd`` item) is replaced with a one-line base64
        gzip tarball of the provision/ tree + .nosi-version, for nuageinit
        (FreeBSD) which does not honour ``write_files:``.

      * ``# __NOSI_PROVISION_FILES__`` as a standalone comment line in a
        ``write_files:`` list is expanded into write_files entries for
        every provision script + an ``/opt/nosi/.nosi-version`` file, for
        Python cloud-init (Linux).
    """
    template = src.read_text()

    # 1. Inline __NOSI_VERSION__ substitution -- always.
    version = _resolve_version(provision_root.parent)
    template = template.replace("__NOSI_VERSION__", version)

    # 2. Tarball marker (nuageinit delivery) -- independent of the
    #    write_files marker below; runs even when that marker is absent.
    template = _expand_tarball_marker(template, provision_root, version)

    # 3. write_files marker expansion.
    expected = f"# {MARKER}"
    marker_line = next(
        (line for line in template.splitlines() if line.strip() == expected),
        None,
    )
    if marker_line is None:
        return template
    indent = marker_line[: len(marker_line) - len(marker_line.lstrip())]

    files = _provision_files(provision_root)
    if not files:
        log.warning("no scripts found under %s; marker will be removed", provision_root)

    blocks = []
    for fp in files:
        rel = fp.relative_to(provision_root.parent)  # e.g. "provision/apply.sh"
        target = f"/opt/nosi/{rel.as_posix()}"
        body = fp.read_text()
        # cloud-init's `content: |` block requires every body line to be
        # indented one level deeper than the `content:` key. Two spaces
        # over the entry indent (which is the marker's indent).
        body_indent = indent + "    "
        # Drop the trailing newline (the `|` preserves trailing newlines
        # only if the body ends with one and we re-add it below); strip
        # any line-final whitespace to keep YAML happy.
        body_lines = "\n".join(
            body_indent + line if line else body_indent.rstrip() for line in body.splitlines()
        )
        blocks.append(
            f"{indent}- path: {target}\n"
            f"{indent}  permissions: '0755'\n"
            f"{indent}  content: |\n"
            f"{body_lines}"
        )

    # Build identifier captured at render time. Same value already
    # substituted inline above for __NOSI_VERSION__ users; the
    # write_files entry below is for the apply.sh step 05 path on
    # Linux (which reads /opt/nosi/.nosi-version via the cloud-init
    # users + files modules).
    body_indent = indent + "    "
    blocks.append(
        f"{indent}- path: /opt/nosi/.nosi-version\n"
        f"{indent}  permissions: '0644'\n"
        f"{indent}  content: |\n"
        f"{body_indent}{version}"
    )

    rendered = "\n\n".join(blocks)
    return template.replace(marker_line, rendered)


def main(args, cijoe):
    src: Path = args.src.resolve()
    if not src.is_file():
        log.error("source not found: %s", src)
        return 2

    provision_root: Path = (
        args.provision_root.resolve()
        if args.provision_root
        else (src.parents[2] / "provision").resolve()
    )
    if not provision_root.is_dir():
        log.error("provision root not found: %s", provision_root)
        return 2

    out: Path = args.out.resolve() if args.out else src.with_suffix(".rendered.user")
    out.write_text(render(src, provision_root))
    log.info("rendered %s -> %s", src, out)
    return 0
