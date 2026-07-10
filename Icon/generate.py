#!/usr/bin/env python3
"""Generate the Lucinate app icon.

Authoritative source is the SVG below (vector, so it stays crisp on both iOS
and Android and can be re-themed). This renders the three iOS 26 appearance
variants — light / dark / tinted — into the AppIcon asset catalog at 1024².

    pip install cairosvg && python3 Icon/generate.py

The glyph is a luminous Wi-Fi broadcast fan (three arcs + node) — a clean,
geometric mark that reads at any size and tints cleanly under Liquid Glass.
"""
import os
import cairosvg

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ICONSET = os.path.join(
    ROOT, "Lucinate", "Resources", "Assets.xcassets", "AppIcon.appiconset"
)

# Wi-Fi fan geometry, centered at (512, 680); arcs open upward.
GLYPH = """
  <g fill="none" stroke="{glyph}" stroke-width="72" stroke-linecap="round">
    <path d="M174.25 485 A390 390 0 0 1 849.75 485" opacity="{o3}"/>
    <path d="M278.17 545 A270 270 0 0 1 745.83 545" opacity="{o2}"/>
    <path d="M382.10 605 A150 150 0 0 1 641.90 605" opacity="{o1}"/>
  </g>
  <circle cx="512" cy="680" r="58" fill="{glyph}" opacity="{o1}"/>
"""


def svg(bg_stops, glyph="#FFFFFF", sheen=0.18, o1=1.0, o2=0.75, o3=0.5):
    stops = "".join(
        f'<stop offset="{off}" stop-color="{col}"/>' for off, col in bg_stops
    )
    glyph_markup = GLYPH.format(glyph=glyph, o1=o1, o2=o2, o3=o3)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1024" y2="1024" gradientUnits="userSpaceOnUse">
      {stops}
    </linearGradient>
    <radialGradient id="sheen" cx="512" cy="330" r="620" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="{sheen}"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#sheen)"/>
  {glyph_markup}
</svg>
"""


VARIANTS = {
    # Light / default: brand blue → violet, white glyph.
    "AppIcon": svg([("0", "#2E7DE9"), ("1", "#6E4DF6")]),
    # Dark: deep navy, white glyph, subtler sheen.
    "AppIcon-dark": svg([("0", "#0F1830"), ("1", "#1E2A4A")], sheen=0.10),
    # Tinted: near-black so iOS tints the light glyph; no colored sheen.
    "AppIcon-tinted": svg([("0", "#0B0E14"), ("1", "#0B0E14")], sheen=0.0),
}

PNG_NAMES = {
    "AppIcon": "AppIcon1024.png",
    "AppIcon-dark": "AppIcon1024-dark.png",
    "AppIcon-tinted": "AppIcon1024-tinted.png",
}

os.makedirs(ICONSET, exist_ok=True)
for name, markup in VARIANTS.items():
    svg_path = os.path.join(HERE, f"{name}.svg")
    with open(svg_path, "w") as f:
        f.write(markup)
    png_path = os.path.join(ICONSET, PNG_NAMES[name])
    cairosvg.svg2png(
        bytestring=markup.encode(), write_to=png_path,
        output_width=1024, output_height=1024,
    )
    print("wrote", os.path.relpath(svg_path, ROOT), "+", os.path.relpath(png_path, ROOT))
