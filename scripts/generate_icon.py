#!/usr/bin/env python3
from __future__ import annotations

import io
import shutil
import struct
import subprocess
from pathlib import Path
from xml.etree import ElementTree as ET

from PIL import Image


SVG_NS = "http://www.w3.org/2000/svg"


def load_icon_paths(svg_path: Path) -> list[str]:
    tree = ET.parse(svg_path)
    root = tree.getroot()
    paths: list[str] = []
    for node in root.findall(f".//{{{SVG_NS}}}path"):
        path_data = node.attrib.get("d")
        if not path_data:
            continue
        if node.attrib.get("fill") == "none":
            continue
        paths.append(path_data)
    return paths


def build_composite_svg(keyboard_paths: list[str], lock_paths: list[str]) -> str:
    keyboard_svg = "\n".join(f'      <path d="{path}" />' for path in keyboard_paths)
    lock_svg = "\n".join(f'      <path d="{path}" />' for path in lock_paths)
    return f"""<svg xmlns="{SVG_NS}" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#ffffff" />
      <stop offset="100%" stop-color="#edf4ff" />
    </linearGradient>
    <linearGradient id="badge" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#6db4ff" />
      <stop offset="100%" stop-color="#2458e8" />
    </linearGradient>
    <filter id="cardShadow" x="-20%" y="-20%" width="140%" height="150%">
      <feDropShadow dx="0" dy="26" stdDeviation="24" flood-color="#193c86" flood-opacity="0.16" />
    </filter>
    <filter id="badgeShadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#133a91" flood-opacity="0.3" />
    </filter>
  </defs>

  <g filter="url(#cardShadow)">
    <rect x="120" y="160" width="784" height="596" rx="178" fill="url(#tile)" />
    <rect x="134" y="174" width="756" height="568" rx="164" fill="none" stroke="rgba(152, 182, 235, 0.45)" stroke-width="6" />
  </g>

  <g transform="translate(192 146) scale(27)" fill="#5f83c9">
{keyboard_svg}
  </g>

  <g transform="translate(748 748)" filter="url(#badgeShadow)">
    <rect x="-123" y="-123" width="246" height="246" rx="74" fill="url(#badge)" />
    <rect x="-113" y="-113" width="226" height="226" rx="66" fill="none" stroke="rgba(255,255,255,0.3)" stroke-width="6" />
    <g transform="translate(-72 -72) scale(6)" fill="#ffffff">
{lock_svg}
    </g>
  </g>
</svg>
"""


def rasterize_svg(svg_path: Path, output_dir: Path) -> Path:
    subprocess.run(
        ["qlmanage", "-t", "-s", "1024", "-o", str(output_dir), str(svg_path)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return output_dir / f"{svg_path.name}.png"


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    build_dir = root / "build"
    iconset = build_dir / "AppIcon.iconset"
    icns_out = root / "Resources" / "AppIcon.icns"
    icon_sources_dir = root / "Resources" / "icon-sources"

    keyboard_svg_source = icon_sources_dir / "material-keyboard.svg"
    lock_svg_source = icon_sources_dir / "material-lock.svg"

    build_dir.mkdir(parents=True, exist_ok=True)
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True, exist_ok=True)

    composite_svg = build_dir / "AppIcon_library.svg"
    composite_png = build_dir / "AppIcon_library_1024.png"
    app_png = build_dir / "AppIcon_1024.png"

    svg_contents = build_composite_svg(
        keyboard_paths=load_icon_paths(keyboard_svg_source),
        lock_paths=load_icon_paths(lock_svg_source),
    )
    composite_svg.write_text(svg_contents, encoding="utf-8")

    rendered_png = rasterize_svg(composite_svg, build_dir)
    Image.open(rendered_png).save(composite_png, format="PNG")
    Image.open(rendered_png).save(app_png, format="PNG")

    sizes: list[tuple[str, int]] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    base = Image.open(composite_png).convert("RGBA")
    for filename, size in sizes:
        image = base if size == 1024 else base.resize((size, size), Image.Resampling.LANCZOS)
        image.save(iconset / filename, format="PNG")

    def png_bytes(image: Image.Image) -> bytes:
        buffer = io.BytesIO()
        image.save(buffer, format="PNG")
        return buffer.getvalue()

    variants: list[tuple[str, int]] = [
        ("ic11", 32),
        ("ic12", 64),
        ("ic07", 128),
        ("ic08", 256),
        ("ic13", 256),
        ("ic09", 512),
        ("ic14", 512),
        ("ic10", 1024),
    ]

    chunks: list[tuple[str, bytes]] = []
    for code, size in variants:
        image = base if size == 1024 else base.resize((size, size), Image.Resampling.LANCZOS)
        chunks.append((code, png_bytes(image)))

    total_length = 8 + sum(8 + len(data) for _, data in chunks)
    output = bytearray()
    output += b"icns"
    output += struct.pack(">I", total_length)
    for code, data in chunks:
        output += code.encode("latin1")
        output += struct.pack(">I", 8 + len(data))
        output += data
    icns_out.write_bytes(output)

    print(f"Wrote: {icns_out} (from {composite_png})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
