"""Unit tests for tools/gen_catalog.py + variants.yml schema sanity."""

from __future__ import annotations

import gen_catalog
import pytest

KNOWN_SHAPES = {"headless", "desktop", "wsl", "docker", "lxc", "proxmox"}


@pytest.fixture(scope="module")
def registry():
    return gen_catalog._load_registry()


def test_registry_schema(registry):
    """Guard the variant registry itself: a malformed entry should fail
    here in seconds, not after a 50-minute bake."""
    assert registry, "variants.yml has no variants"
    for name, spec in registry.items():
        assert spec.get("shape") in KNOWN_SHAPES, f"{name}: bad shape {spec.get('shape')!r}"
        assert isinstance(spec.get("flashable"), bool), f"{name}: flashable must be a bool"


def test_every_variant_has_a_description_file(registry):
    """Each variant's use-case prose lives in its own descriptions/<name>.md
    (and <name>.wsl.md for the wsl shape). A registered variant without its
    file would fail the ORAS --describe push, so catch it here instead."""
    for name, spec in registry.items():
        assert (gen_catalog.DESCRIPTIONS_DIR / f"{name}.md").is_file(), (
            f"{name}: missing descriptions/{name}.md"
        )
        assert gen_catalog._load_description(name), f"{name}: empty description file"
        if spec["shape"] == "wsl":
            assert (gen_catalog.DESCRIPTIONS_DIR / f"{name}.wsl.md").is_file(), (
                f"{name}: wsl shape needs descriptions/{name}.wsl.md"
            )
            assert gen_catalog._load_description(name, wsl=True), (
                f"{name}: empty wsl description file"
            )


def test_no_orphan_description_files(registry):
    """Every descriptions/*.md maps to a registered variant, so a renamed or
    removed variant does not leave dead prose behind."""
    for path in gen_catalog.DESCRIPTIONS_DIR.glob("*.md"):
        name = path.name[: -len(".wsl.md")] if path.name.endswith(".wsl.md") else path.stem
        assert name in registry, f"{path.name}: no such variant in variants.yml"


def test_variant_names_match_their_shape_suffix(registry):
    for name, spec in registry.items():
        assert name.endswith(f"-{spec['shape']}"), f"{name}: name does not end in -{spec['shape']}"


def test_describe_happy_path(registry):
    text = gen_catalog._describe(registry, "debian-13-headless", key="description")
    assert "Debian 13" in text


def test_describe_unknown_variant_fails_loudly(registry):
    with pytest.raises(SystemExit):
        gen_catalog._describe(registry, "no-such-variant", key="description")


def test_catalog_lists_only_flashable_for_each_ref_tag(registry):
    """Both render modes (rolling ``:latest`` and a pinned ``:YYYY.WNN``)
    must carry every flashable variant and omit every non-flashable one.
    The unique per-image marker is the oras src ``.../<name>:<ref-tag>``,
    not a bare name substring and not ``[images.<name>]``: the renderer
    emits ``[[images]]`` table-arrays, so the bracket form never appears
    and asserting its absence would prove nothing.
    """
    for ref_tag in ("latest", "2026.W25"):
        out = gen_catalog._render_catalog(registry, ref_tag=ref_tag)
        for name, spec in registry.items():
            ref = f"/{name}:{ref_tag}"
            if spec["flashable"]:
                assert ref in out, f"flashable {name} missing from catalog (ref_tag={ref_tag})"
            else:
                assert ref not in out, (
                    f"non-flashable {name} leaked into catalog (ref_tag={ref_tag})"
                )


def test_catalog_parses_and_every_image_is_complete(registry):
    """Parse the rendered TOML and assert each image carries the four fields
    bty needs, so a renderer regression fails here, not in bty."""
    import tomllib

    doc = tomllib.loads(gen_catalog._render_catalog(registry, ref_tag="latest"))
    assert doc.get("version") == 1
    flashable = [n for n, s in registry.items() if s["flashable"]]
    netboot = [n for n, s in registry.items() if s.get("netboot")]
    # Every ``flashable: true`` variant emits its disk-image entry;
    # every ``netboot: true`` variant emits a companion bundle entry
    # right after it. So the total image count is flashable + netboot.
    assert len(doc.get("images", [])) == len(flashable) + len(netboot)
    for img in doc["images"]:
        for field in ("name", "src", "format", "arch", "description"):
            assert img.get(field), f"{img.get('name', '?')}: missing {field}"
        assert img["src"].startswith("oras://")
        assert img["description"].strip()


def test_netboot_entries_pair_with_their_disk_image(registry):
    """Every ``netboot: true`` variant emits BOTH:
    - a disk-image entry (format=img.gz) with ``netboot_ref`` naming
      the companion bundle by its actual ``name`` field, and
    - a companion bundle entry (format=tar.gz) whose src is the
      ``<disk-src>-netboot`` sibling.

    Nbdmux's Warmer resolves the pairing with
    ``_lookup_withcache_entry_by_name(netboot_ref)`` -- an EXACT
    string match against the sibling's ``name`` field, not a
    substring or a slug-derivation. Previously ``netboot_ref`` held
    the slug ``<variant>-netboot`` while the sibling's ``name`` was
    the display string ``nosi <variant> netboot bundle (<arch>,
    <label>)``, so the lookup silently failed for every entry
    loaded from a published catalog TOML and the nbdboot chain fell
    all the way back to bty-media's kernel. Pin the equality here
    so a future drift fails this test rather than the deploy.
    """
    import tomllib

    doc = tomllib.loads(gen_catalog._render_catalog(registry, ref_tag="latest"))
    # Two indices: by variant (the slug baked into the oras src's
    # path segment) so we can walk the registry, and by name so we
    # can prove the netboot_ref lookup succeeds structurally.
    imgs_by_variant = {img["src"].rsplit("/", 1)[1].split(":", 1)[0]: img for img in doc["images"]}
    imgs_by_name = {img["name"]: img for img in doc["images"]}
    for name, spec in registry.items():
        if not spec.get("netboot"):
            if spec.get("flashable"):
                assert "netboot_ref" not in imgs_by_variant[name], (
                    f"{name}: netboot_ref set but variant has no netboot bundle"
                )
            continue
        disk = imgs_by_variant[name]
        # Disk-image's netboot_ref must be resolvable via a plain
        # name lookup -- the exact wire contract nbdmux uses.
        ref = disk["netboot_ref"]
        assert ref in imgs_by_name, f"{name}: netboot_ref {ref!r} does not name any catalog entry"
        bundle = imgs_by_name[ref]
        # Bundle also happens to sit at ``<variant>-netboot`` by src slug.
        assert imgs_by_variant[f"{name}-netboot"] is bundle
        assert bundle["format"] == "tar.gz"
        assert bundle["arch"] == disk["arch"]
        # No chaining: the bundle itself never carries netboot_ref.
        assert "netboot_ref" not in bundle


def test_arch_field_matches_registry(registry):
    """Each emitted entry's ``arch`` field equals what variants.yml
    declares (or ``x86_64`` when the variant omits the key). Catches
    a renderer drift where ``arch`` is hard-coded or lost."""
    import tomllib

    doc = tomllib.loads(gen_catalog._render_catalog(registry, ref_tag="latest"))
    by_variant = {
        img["src"].rsplit("/", 1)[1].split(":", 1)[0]: img["arch"] for img in doc["images"]
    }
    for name, spec in registry.items():
        if not spec.get("flashable"):
            continue
        expected = str(spec.get("arch", "x86_64"))
        assert by_variant[name] == expected, (
            f"{name}: catalog arch {by_variant[name]!r} != registry {expected!r}"
        )


def test_pinned_catalog_refs_pin_to_ref_tag(registry):
    """A ``ref_tag`` other than ``latest`` must show up in every emitted
    oras src AND in each image's ``name`` label. Otherwise the dual-
    catalog model (rolling vs frozen) silently degrades to two copies
    of the same rolling catalog.
    """
    import tomllib

    doc = tomllib.loads(gen_catalog._render_catalog(registry, ref_tag="2026.W25"))
    for img in doc["images"]:
        assert img["src"].endswith(":2026.W25"), (
            f"{img['name']}: src {img['src']} not pinned to :2026.W25"
        )
        assert "2026.W25" in img["name"], f"{img['name']}: human-readable label missing the W-tag"
