#!/usr/bin/env python3
"""Verify the "invisible on device" contract of the Nexus Self-Monitor test build.

A hidden test build has two observable properties that must never silently
regress:

1. No Home Screen label - `CFBundleDisplayName` for both the app and the
   embedded screen-broadcast extension must contain no visible glyphs.
2. No visible icon - the `AppIcon` asset catalog entry must reference a fully
   transparent PNG, and the app target must actually use that catalog, so the
   compiled bundle ships transparent icon artwork instead of a white tile.

This checker is deliberately stdlib-only (no Pillow, no PyYAML) so the same
command runs unchanged on the Linux dev box and on the macOS/Ubuntu CI runners:

    python3 scripts/verify_hidden_app.py                     # repo sources
    python3 scripts/verify_hidden_app.py --app build/Release-iphoneos/NexusSelfMonitor.app
    python3 scripts/verify_hidden_app.py --app build/NexusSelfMonitor-unsigned.ipa

Exit status is 0 only when every check passes.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import struct
import sys
import unicodedata
import zipfile
import zlib
from pathlib import Path
from typing import Callable, Iterable, Iterator

REPO_ROOT = Path(__file__).resolve().parents[1]
APP_DIR = REPO_ROOT / "NexusSelfMonitor"
APP_INFO_PLIST = APP_DIR / "Resources" / "Info.plist"
EXTENSION_INFO_PLIST = APP_DIR / "BroadcastExtension" / "Info.plist"
ASSET_CATALOG_DIR = APP_DIR / "Resources" / "Assets.xcassets"
APP_ICON_SET_DIR = ASSET_CATALOG_DIR / "AppIcon.appiconset"
PROJECT_YML = APP_DIR / "project.yml"

APP_TARGET = "NexusSelfMonitor"
EXTENSION_TARGET = "ScreenBroadcast"
APP_ICON_NAME = "AppIcon"
ICON_MAX_SIZE_PX = 1024

# Zero-width/blank glyphs that render as nothing. The first four are "format",
# "control" and space-separator categories; the rest are visually blank symbols
# that Unicode does not classify as separators.
INVISIBLE_CATEGORIES = {"Cf", "Cc", "Zs", "Zl", "Zp"}
BLANK_SYMBOL_CODE_POINTS = {0x2800, 0x3164, 0xFFA0}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_COLOR_TYPE_RGBA = 6


class Report:
    """Collects pass/fail lines and decides the process exit status."""

    def __init__(self) -> None:
        self.passed = 0
        self.failures: list[str] = []

    def require(self, condition: bool, description: str) -> bool:
        if condition:
            self.passed += 1
            print(f"PASS  {description}")
        else:
            self.failures.append(description)
            print(f"FAIL  {description}")
        return condition

    def finish(self) -> int:
        total = self.passed + len(self.failures)
        if self.failures:
            print(f"\n{len(self.failures)} of {total} checks FAILED")
            return 1
        print(f"\nAll {total} checks passed")
        return 0


def visible_glyphs(value: str) -> list[str]:
    """Return the code points in `value` that would render as visible text."""
    offenders = []
    for char in value:
        if char.isspace():
            continue
        if unicodedata.category(char) in INVISIBLE_CATEGORIES:
            continue
        if ord(char) in BLANK_SYMBOL_CODE_POINTS:
            continue
        offenders.append(f"U+{ord(char):04X} {unicodedata.name(char, '?')}")
    return offenders


def load_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def load_plist_bytes(payload: bytes) -> dict:
    return plistlib.loads(payload)


def check_display_name(report: Report, plist: dict, label: str) -> None:
    name = plist.get("CFBundleDisplayName")
    if not report.require(
        isinstance(name, str) and name != "",
        f"{label}: CFBundleDisplayName is present and non-empty",
    ):
        return
    offenders = visible_glyphs(name)
    report.require(
        not offenders,
        f"{label}: CFBundleDisplayName renders no visible text "
        f"(got {name!r}, offenders: {offenders})",
    )

def iter_png_chunks(data: bytes) -> Iterator[tuple[bytes, bytes]]:
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("not a PNG file")
    position = len(PNG_SIGNATURE)
    while position + 8 <= len(data):
        length, chunk_type = struct.unpack(">I4s", data[position : position + 8])
        start = position + 8
        end = start + length
        if end + 4 > len(data):
            raise ValueError(f"truncated {chunk_type!r} chunk")
        yield chunk_type, data[start:end]
        position = end + 4  # skip the 4-byte CRC


def paeth_predictor(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    distance_left = abs(estimate - left)
    distance_above = abs(estimate - above)
    distance_upper_left = abs(estimate - upper_left)
    if distance_left <= distance_above and distance_left <= distance_upper_left:
        return left
    if distance_above <= distance_upper_left:
        return above
    return upper_left


def unfilter_scanlines(raw: bytes, width: int, height: int, bytes_per_pixel: int) -> bytes:
    stride = width * bytes_per_pixel
    pixels = bytearray()
    previous = bytearray(stride)
    position = 0
    for _ in range(height):
        if position >= len(raw):
            raise ValueError("truncated image data")
        filter_type = raw[position]
        position += 1
        line = bytearray(raw[position : position + stride])
        if len(line) != stride:
            raise ValueError("truncated scanline")
        position += stride
        if filter_type == 0:
            pass
        elif filter_type == 1:
            for index in range(bytes_per_pixel, stride):
                line[index] = (line[index] + line[index - bytes_per_pixel]) & 0xFF
        elif filter_type == 2:
            for index in range(stride):
                line[index] = (line[index] + previous[index]) & 0xFF
        elif filter_type == 3:
            for index in range(stride):
                left = line[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
                line[index] = (line[index] + ((left + previous[index]) >> 1)) & 0xFF
        elif filter_type == 4:
            for index in range(stride):
                left = line[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
                above = previous[index]
                upper_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
                line[index] = (line[index] + paeth_predictor(left, above, upper_left)) & 0xFF
        else:
            raise ValueError(f"unsupported PNG filter type {filter_type}")
        pixels += line
        previous = line
    return bytes(pixels)


def png_alpha_extrema(data: bytes) -> tuple[int, int, int, int]:
    """Return (width, height, min_alpha, max_alpha) for an 8-bit RGBA PNG."""
    header = None
    compressed = bytearray()
    for chunk_type, payload in iter_png_chunks(data):
        if chunk_type == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        elif chunk_type == b"IDAT":
            compressed += payload
    if header is None:
        raise ValueError("missing IHDR chunk")
    width, height, bit_depth, color_type, compression, filter_method, interlace = header
    if (bit_depth, color_type) != (8, PNG_COLOR_TYPE_RGBA):
        raise ValueError(f"icon must be 8-bit RGBA (got bit depth {bit_depth}, colour type {color_type})")
    if compression != 0 or filter_method != 0 or interlace != 0:
        raise ValueError("unsupported PNG encoding (compression/filter/interlace)")
    try:
        raw = zlib.decompress(bytes(compressed))
    except zlib.error:
        try:
            raw = zlib.decompress(bytes(compressed), -zlib.MAX_WBITS)
        except zlib.error:
            raw = zlib.decompress(bytes(compressed), zlib.MAX_WBITS | 32)
    if not raw:
        raise ValueError("empty image data")
    # Fast path: an all-zero stream means every scanline is filter 0 and empty,
    # i.e. the whole image is fully transparent.
    if max(raw) == 0:
        return width, height, 0, 0
    pixels = unfilter_scanlines(raw, width, height, 4)
    stride = width * 4
    minimum, maximum = 255, 0
    for row in range(height):
        alpha = pixels[row * stride + 3 : (row + 1) * stride : 4]
        minimum = min(minimum, min(alpha))
        maximum = max(maximum, max(alpha))
    return width, height, minimum, maximum


def check_icon_catalog(report: Report, icon_set_dir: Path, label: str) -> None:
    contents_path = icon_set_dir / "Contents.json"
    if not report.require(contents_path.is_file(), f"{label}: AppIcon.appiconset/Contents.json exists"):
        return
    try:
        contents = json.loads(contents_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        report.require(False, f"{label}: AppIcon.appiconset/Contents.json parses ({error})")
        return
    report.require(True, f"{label}: AppIcon.appiconset/Contents.json parses")

    filenames = [
        image["filename"]
        for image in contents.get("images", [])
        if isinstance(image, dict) and image.get("filename")
    ]
    if not report.require(bool(filenames), f"{label}: AppIcon.appiconset declares icon artwork"):
        return

    for filename in filenames:
        icon_path = icon_set_dir / filename
        if not report.require(icon_path.is_file(), f"{label}: {filename} exists"):
            continue
        try:
            width, height, minimum, maximum = png_alpha_extrema(icon_path.read_bytes())
        except (OSError, ValueError, zlib.error) as error:
            report.require(False, f"{label}: {filename} is a readable 8-bit RGBA PNG ({error})")
            continue
        report.require(
            width <= ICON_MAX_SIZE_PX and height <= ICON_MAX_SIZE_PX,
            f"{label}: {filename} is at most {ICON_MAX_SIZE_PX}px ({width}x{height})",
        )
        report.require(
            maximum == 0,
            f"{label}: {filename} is fully transparent (alpha {minimum}..{maximum}, {width}x{height})",
        )


def parse_target_appicon_settings(text: str) -> tuple[dict[str, str], dict[str, list[str]]]:
    """Read the app-icon setting and source paths per target from project.yml.

    Only the shapes used by this file are understood (top-level `targets:`,
    two-space-indented target keys, `ASSETCATALOG_COMPILER_APPICON_NAME:` keys and
    `- path:` source entries), which avoids a PyYAML dependency on CI runners.
    """
    settings: dict[str, str] = {}
    source_paths: dict[str, list[str]] = {}
    current_target: str | None = None
    in_targets = False
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("targets:"):
            in_targets = True
            current_target = None
            continue
        if not in_targets:
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*:", line):
            in_targets = False
            current_target = None
            continue
        target_match = re.match(r"^ {2}([A-Za-z0-9_]+):\s*$", line)
        if target_match:
            current_target = target_match.group(1)
            source_paths.setdefault(current_target, [])
            continue
        if current_target is None:
            continue
        setting_match = re.match(r"^\s+([A-Za-z0-9_]+):\s*(.*?)\s*$", line)
        if setting_match:
            key = setting_match.group(1)
            value = setting_match.group(2).strip("\"'")
            if key == "ASSETCATALOG_COMPILER_APPICON_NAME":
                settings[current_target] = value
        source_match = re.match(r"^\s*-\s*path:\s*(.*?)\s*$", line)
        if source_match:
            source_paths[current_target].append(source_match.group(1).strip("\"'"))
    return settings, source_paths


def verify_sources(report: Report) -> None:
    print("== Source configuration ==")
    for label, path in (("app", APP_INFO_PLIST), ("extension", EXTENSION_INFO_PLIST)):
        if not report.require(path.is_file(), f"{label}: {path.relative_to(REPO_ROOT)} exists"):
            continue
        try:
            plist = load_plist(path)
        except (OSError, ValueError) as error:
            report.require(False, f"{label}: {path.name} parses ({error})")
            continue
        check_display_name(report, plist, label)

    check_icon_catalog(report, APP_ICON_SET_DIR, "app")

    if not report.require(PROJECT_YML.is_file(), "project.yml exists"):
        return
    settings, source_paths = parse_target_appicon_settings(PROJECT_YML.read_text(encoding="utf-8"))
    report.require(
        settings.get(APP_TARGET) == APP_ICON_NAME,
        f"project.yml: {APP_TARGET} sets ASSETCATALOG_COMPILER_APPICON_NAME={APP_ICON_NAME} "
        f"(got {settings.get(APP_TARGET)!r})",
    )
    report.require(
        settings.get(EXTENSION_TARGET) != APP_ICON_NAME,
        f"project.yml: {EXTENSION_TARGET} carries no Home Screen icon setting",
    )
    report.require(
        "Resources" in source_paths.get(APP_TARGET, []),
        f"project.yml: {APP_TARGET} compiles the Resources folder holding the catalog "
        f"(got {source_paths.get(APP_TARGET)!r})",
    )


def read_app_bundle(app_path: Path) -> tuple[dict, list[str], list[tuple[str, dict]], "Callable[[str], bytes]"]:
    """Return (Info.plist, file names, [(appex name, Info.plist)], file reader)."""
    if app_path.is_dir():
        plist_path = app_path / "Info.plist"
        if not plist_path.is_file():
            raise ValueError("no Info.plist inside the bundle directory")
        names = [str(item.relative_to(app_path)) for item in app_path.rglob("*") if item.is_file()]
        extensions = [
            (info.parent.name, load_plist(info)) for info in sorted(app_path.glob("PlugIns/*.appex/Info.plist"))
        ]

        def read_from_directory(name: str) -> bytes:
            return (app_path / name).read_bytes()

        return load_plist(plist_path), names, extensions, read_from_directory

    if zipfile.is_zipfile(app_path):
        with zipfile.ZipFile(app_path) as archive:
            names = archive.namelist()
            app_plists = [name for name in names if re.match(r"^Payload/[^/]+\.app/Info\.plist$", name)]
            if not app_plists:
                raise ValueError("no Payload/*.app/Info.plist inside the archive")
            extensions = [
                (Path(name).parent.name, load_plist_bytes(archive.read(name)))
                for name in sorted(names)
                if re.match(r"^Payload/[^/]+\.app/PlugIns/[^/]+\.appex/Info\.plist$", name)
            ]
            plist = load_plist_bytes(archive.read(app_plists[0]))

        def read_from_archive(name: str) -> bytes:
            with zipfile.ZipFile(app_path) as archive:
                return archive.read(name)

        return plist, names, extensions, read_from_archive

    raise ValueError("not a bundle directory and not a zip/IPA archive")


def verify_bundle(report: Report, app_path: Path) -> None:
    print(f"== Built artifact: {app_path} ==")
    try:
        plist, names, extensions, read_file = read_app_bundle(app_path)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        report.require(False, f"artifact: readable .app bundle or .ipa ({error})")
        return

    check_display_name(report, plist, "app bundle")
    icon_name = plist.get("CFBundleIconName")
    report.require(
        icon_name in (None, APP_ICON_NAME),
        f"app bundle: CFBundleIconName is {APP_ICON_NAME} when present (got {icon_name!r})",
    )
    has_catalog = any(name.endswith("Assets.car") for name in names)
    loose_icons = [name for name in names if Path(name).name.startswith(APP_ICON_NAME) and name.endswith(".png")]
    report.require(
        has_catalog or bool(loose_icons),
        f"app bundle: compiled icon artwork present (Assets.car={has_catalog}, loose={loose_icons})",
    )
    for name in loose_icons:
        try:
            width, height, minimum, maximum = png_alpha_extrema(read_file(name))
        except (OSError, ValueError, zlib.error, KeyError) as error:
            report.require(False, f"app bundle: {Path(name).name} is a readable 8-bit RGBA PNG ({error})")
            continue
        report.require(
            maximum == 0,
            f"app bundle: {Path(name).name} is fully transparent "
            f"(alpha {minimum}..{maximum}, {width}x{height})",
        )
    report.require(
        bool(extensions),
        "app bundle: the screen-broadcast extension is embedded under PlugIns/*.appex",
    )
    for extension_name, extension_plist in extensions:
        check_display_name(report, extension_plist, f"extension bundle {extension_name}")


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify the invisible-on-device test-build contract.")
    parser.add_argument(
        "--app",
        type=Path,
        default=None,
        help="optional built .app bundle or .ipa to verify in addition to the repository sources",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    report = Report()
    verify_sources(report)
    if args.app is not None:
        verify_bundle(report, args.app)
    return report.finish()


if __name__ == "__main__":
    sys.exit(main())

