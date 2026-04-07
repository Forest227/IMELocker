#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path
import io
import struct

from PIL import Image, ImageDraw, ImageFilter


def lerp(a: int, b: int, t: float) -> int:
    return int(round(a * (1.0 - t) + b * t))


def render_base(size: int = 1024) -> Image.Image:
    w = h = 1024
    transparent = Image.new("RGBA", (w, h), (0, 0, 0, 0))

    # WeChat-ish green glass background.
    top = (28, 230, 130)
    bottom = (7, 193, 96)
    gradient = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gradient)
    for y in range(h):
        t = y / (h - 1)
        gd.line(
            [(0, y), (w, y)],
            fill=(lerp(top[0], bottom[0], t), lerp(top[1], bottom[1], t), lerp(top[2], bottom[2], t), 255),
        )

    pad = 44
    radius = 220
    mask = Image.new("L", (w, h), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle([pad, pad, w - pad, h - pad], radius=radius, fill=255)

    img = transparent.copy()
    img.paste(gradient, (0, 0), mask)

    # Glass highlights.
    highlights = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    hd = ImageDraw.Draw(highlights)
    hd.ellipse([-240, -260, int(w * 0.95), int(h * 0.62)], fill=(255, 255, 255, 90))
    hd.ellipse([int(w * 0.15), -320, int(w * 1.25), int(h * 0.42)], fill=(255, 255, 255, 45))
    highlights = highlights.filter(ImageFilter.GaussianBlur(42))
    img = Image.alpha_composite(img, highlights)

    # Subtle border.
    bd = ImageDraw.Draw(img)
    bd.rounded_rectangle([pad, pad, w - pad, h - pad], radius=radius, outline=(255, 255, 255, 120), width=10)

    # Keyboard layer (white).
    keyboard = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    kd = ImageDraw.Draw(keyboard)
    kb_w, kb_h = 690, 370
    kb_x, kb_y = (w - kb_w) // 2, 318
    kb_r = 110
    kb_rect = [kb_x, kb_y, kb_x + kb_w, kb_y + kb_h]

    # Shadow.
    shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(kb_rect, radius=kb_r, fill=(0, 0, 0, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(34))
    shadow_offset = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    shadow_offset.paste(shadow, (0, 18), shadow)
    img = Image.alpha_composite(img, shadow_offset)

    kd.rounded_rectangle(kb_rect, radius=kb_r, fill=(255, 255, 255, 235))
    kd.rounded_rectangle(
        [kb_x + 22, kb_y + 22, kb_x + kb_w - 22, kb_y + kb_h - 22],
        radius=kb_r - 22,
        outline=(255, 255, 255, 120),
        width=6,
    )

    # Keys (subtle emboss).
    key_color = (0, 70, 40, 55)
    key_w, key_h, gap = 56, 48, 16
    top_margin = 78
    for row, count in enumerate([8, 7, 6]):
        total = count * key_w + (count - 1) * gap
        x0 = kb_x + (kb_w - total) // 2
        y0 = kb_y + top_margin + row * (key_h + gap)
        for i in range(count):
            x = x0 + i * (key_w + gap)
            kd.rounded_rectangle([x, y0, x + key_w, y0 + key_h], radius=12, fill=key_color)

    # Space bar.
    space_w = key_w * 3 + gap * 2
    space_x0 = kb_x + (kb_w - space_w) // 2
    space_y0 = kb_y + top_margin + 3 * (key_h + gap)
    kd.rounded_rectangle([space_x0, space_y0, space_x0 + space_w, space_y0 + key_h], radius=14, fill=key_color)

    img = Image.alpha_composite(img, keyboard)

    # Badge + lock.
    badge = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    bdg = ImageDraw.Draw(badge)
    cx, cy = 770, 770
    d = 276
    bbox = [cx - d // 2, cy - d // 2, cx + d // 2, cy + d // 2]
    bdg.ellipse(bbox, fill=(4, 92, 54, 240))
    bdg.ellipse([bbox[0] + 14, bbox[1] + 10, bbox[2] - 24, bbox[3] - 60], fill=(255, 255, 255, 40))

    white = (255, 255, 255, 245)
    sh_r = 58
    arc_bbox = [cx - sh_r, cy - 118, cx + sh_r, cy - 2]
    bdg.arc(arc_bbox, start=180, end=0, fill=white, width=18)
    bdg.line([(cx - sh_r, cy - 60), (cx - sh_r, cy - 34)], fill=white, width=18)
    bdg.line([(cx + sh_r, cy - 60), (cx + sh_r, cy - 34)], fill=white, width=18)

    body_w, body_h = 140, 116
    body = [cx - body_w // 2, cy - 34, cx + body_w // 2, cy - 34 + body_h]
    bdg.rounded_rectangle(body, radius=20, fill=white)

    # Keyhole.
    kh = (4, 92, 54, 210)
    bdg.ellipse([cx - 11, cy + 12 - 11, cx + 11, cy + 12 + 11], fill=kh)
    bdg.rounded_rectangle([cx - 6, cy + 12, cx + 6, cy + 44], radius=4, fill=kh)

    badge = badge.filter(ImageFilter.GaussianBlur(0.6))
    img = Image.alpha_composite(img, badge)

    if size != 1024:
        img = img.resize((size, size), Image.Resampling.LANCZOS)
    return img


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    build_dir = root / "build"
    iconset = build_dir / "AppIcon.iconset"
    icns_out = root / "Resources" / "AppIcon.icns"

    build_dir.mkdir(parents=True, exist_ok=True)
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True, exist_ok=True)

    base = render_base(1024)
    base_path = build_dir / "AppIcon_1024.png"
    base.save(base_path, format="PNG")

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

    for filename, sz in sizes:
        img = base if sz == 1024 else base.resize((sz, sz), Image.Resampling.LANCZOS)
        img.save(iconset / filename, format="PNG")

    # Build .icns directly (avoid iconutil in restricted environments).
    # PNG-based element type codes (observed in system .icns files):
    # - 32x32   -> ic11
    # - 64x64   -> ic12
    # - 128x128 -> ic07
    # - 256x256 -> ic08 (also ic13)
    # - 512x512 -> ic09 (also ic14)
    # - 1024x1024 -> ic10
    def png_bytes(img: Image.Image) -> bytes:
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return buf.getvalue()

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
    for code, sz in variants:
        img = base if sz == 1024 else base.resize((sz, sz), Image.Resampling.LANCZOS)
        chunks.append((code, png_bytes(img)))

    total_len = 8 + sum(8 + len(data) for _, data in chunks)
    out = bytearray()
    out += b"icns"
    out += struct.pack(">I", total_len)
    for code, data in chunks:
        out += code.encode("latin1")
        out += struct.pack(">I", 8 + len(data))
        out += data
    icns_out.write_bytes(out)
    print(f"Wrote: {icns_out} (from {base_path})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
