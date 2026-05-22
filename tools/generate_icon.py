"""Generate MotoRider app icons via SVG -> PNG (resvg-py)."""
from __future__ import annotations

from pathlib import Path

import resvg_py
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "assets" / "icon"
OUT_DIR.mkdir(parents=True, exist_ok=True)


def _bike_path() -> str:
    """SVG <g> contents for a stylized sport-naked motorcycle facing left.

    Coordinates assume a 1024x1024 viewBox. The bike sits with wheel
    centers at y=720, wheelbase ~ x=240 -> x=784.
    """
    return r"""
    <!-- Soft shadow under bike -->
    <ellipse cx="512" cy="830" rx="320" ry="22" fill="#000" opacity="0.35"/>

    <!-- Rear wheel -->
    <g>
      <circle cx="784" cy="720" r="120" fill="#F5F6FA"/>
      <circle cx="784" cy="720" r="78"  fill="#0B1220"/>
      <circle cx="784" cy="720" r="22"  fill="#F5F6FA"/>
      <!-- spokes -->
      <line x1="784" y1="650" x2="784" y2="790" stroke="#F5F6FA" stroke-width="6" stroke-linecap="round"/>
      <line x1="722" y1="685" x2="846" y2="755" stroke="#F5F6FA" stroke-width="6" stroke-linecap="round"/>
      <line x1="722" y1="755" x2="846" y2="685" stroke="#F5F6FA" stroke-width="6" stroke-linecap="round"/>
    </g>

    <!-- Front wheel -->
    <g>
      <circle cx="240" cy="720" r="120" fill="#F5F6FA"/>
      <circle cx="240" cy="720" r="78"  fill="#0B1220"/>
      <circle cx="240" cy="720" r="22"  fill="#F5F6FA"/>
      <line x1="240" y1="650" x2="240" y2="790" stroke="#F5F6FA" stroke-width="6" stroke-linecap="round"/>
      <line x1="178" y1="685" x2="302" y2="755" stroke="#F5F6FA" stroke-width="6" stroke-linecap="round"/>
      <line x1="178" y1="755" x2="302" y2="685" stroke="#F5F6FA" stroke-width="6" stroke-linecap="round"/>
    </g>

    <!-- Swingarm (rear) -->
    <path d="M 540,640 L 580,650 L 770,712 L 760,728 L 565,675 Z" fill="#F5F6FA"/>

    <!-- Exhaust (short undertail muffler) -->
    <path d="M 565,665 L 720,670 Q 740,672 740,690 Q 740,706 720,706 L 565,700 Z"
          fill="#F5F6FA"/>

    <!-- Rear shock spring -->
    <line x1="595" y1="540" x2="660" y2="640" stroke="#F5F6FA"
          stroke-width="16" stroke-linecap="round"/>

    <!-- Front fork legs -->
    <line x1="320" y1="520" x2="252" y2="710" stroke="#F5F6FA"
          stroke-width="22" stroke-linecap="round"/>
    <line x1="345" y1="535" x2="270" y2="715" stroke="#F5F6FA"
          stroke-width="14" stroke-linecap="round"/>

    <!-- Trellis frame strut (under tank, to swingarm pivot) -->
    <path d="M 345,505 L 540,510 L 580,610 L 555,640 L 380,580 Z"
          fill="#F5F6FA"/>

    <!-- Tank: bold central form, signature Hornet angularity -->
    <path d="M 320,505
             C 330,470 380,448 445,442
             C 510,438 555,452 580,478
             L 590,520
             L 560,540
             L 345,540
             Z"
          fill="#F5F6FA"/>

    <!-- Tank highlight cut (subtle facet line) -->
    <path d="M 345,500
             C 380,478 440,468 510,470
             C 555,471 580,480 588,495
             L 575,505
             C 555,495 510,488 460,490
             C 410,492 375,500 350,512 Z"
          fill="#0B1220" opacity="0.18"/>

    <!-- Seat & upswept tail (sharp) -->
    <path d="M 555,478
             L 600,468
             L 695,455
             L 770,448
             L 820,465
             L 830,485
             L 820,505
             L 770,500
             L 720,505
             L 660,512
             L 605,520
             L 575,530
             Z"
          fill="#F5F6FA"/>

    <!-- Tail light accent -->
    <rect x="800" y="470" width="22" height="10" rx="4" fill="#FF6B1A"/>

    <!-- Headstock + headlight nacelle (angular, Hornet-inspired) -->
    <path d="M 325,500
             L 260,485
             L 200,475
             L 155,490
             L 138,520
             L 150,548
             L 195,562
             L 270,572
             L 325,560
             Z"
          fill="#F5F6FA"/>

    <!-- LED headlight stripe (signature) -->
    <path d="M 148,506
             L 200,498
             L 232,506
             L 218,524
             L 200,520
             L 162,528 Z"
          fill="#FFB154"/>
    <path d="M 158,535
             L 215,532
             L 238,540
             L 222,553
             L 196,548
             L 168,552 Z"
          fill="#FF6B1A"/>

    <!-- Clip-on handlebars -->
    <path d="M 308,490 L 358,468 L 372,484 L 322,505 Z" fill="#F5F6FA"/>
    <circle cx="350" cy="448" r="16" fill="#F5F6FA"/>
    <line x1="350" y1="448" x2="358" y2="475" stroke="#F5F6FA" stroke-width="8"
          stroke-linecap="round"/>

    <!-- Mirror stalk highlight -->
    <circle cx="350" cy="448" r="6" fill="#FFB154"/>
    """


def _full_svg() -> str:
    """Full icon: background gradient + glow + bike."""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <radialGradient id="bg" cx="62%" cy="72%" r="80%">
      <stop offset="0%"  stop-color="#FF6B1A"/>
      <stop offset="35%" stop-color="#3A1F1C"/>
      <stop offset="70%" stop-color="#0F1A2E"/>
      <stop offset="100%" stop-color="#070C18"/>
    </radialGradient>
    <radialGradient id="glow" cx="50%" cy="55%" r="40%">
      <stop offset="0%"  stop-color="#FF6B1A" stop-opacity="0.55"/>
      <stop offset="100%" stop-color="#FF6B1A" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="road" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%"   stop-color="#FF6B1A" stop-opacity="0"/>
      <stop offset="50%"  stop-color="#FFB154" stop-opacity="1"/>
      <stop offset="100%" stop-color="#FF6B1A" stop-opacity="0"/>
    </linearGradient>
  </defs>

  <!-- Background -->
  <rect width="1024" height="1024" fill="url(#bg)"/>
  <!-- Diffused orange glow centered on bike -->
  <ellipse cx="512" cy="600" rx="500" ry="280" fill="url(#glow)"/>

  <!-- Glowing road accent -->
  <rect x="120" y="848" width="784" height="14" rx="7" fill="url(#road)" opacity="0.9"/>
  <rect x="200" y="870" width="624" height="6"  rx="3" fill="url(#road)" opacity="0.6"/>

  <!-- Bike -->
  <g>{_bike_path()}</g>
</svg>
"""


def _foreground_svg() -> str:
    """Adaptive icon foreground: bike only, transparent bg, safe-zoned (~62% scale)."""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <radialGradient id="glow" cx="50%" cy="55%" r="32%">
      <stop offset="0%"  stop-color="#FF6B1A" stop-opacity="0.7"/>
      <stop offset="100%" stop-color="#FF6B1A" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <ellipse cx="512" cy="560" rx="340" ry="180" fill="url(#glow)"/>
  <g transform="translate(195, 130) scale(0.62)">
    {_bike_path()}
  </g>
</svg>
"""


def _render(svg: str, out_path: Path, size: int = 1024) -> None:
    png_bytes = resvg_py.svg_to_bytes(svg_string=svg, width=size, height=size)
    out_path.write_bytes(bytes(png_bytes))


def main() -> None:
    full = OUT_DIR / "app_icon.png"
    fg = OUT_DIR / "app_icon_foreground.png"
    _render(_full_svg(), full)
    _render(_foreground_svg(), fg)
    # Sanity: re-open with PIL to confirm valid PNGs
    for p in (full, fg):
        with Image.open(p) as im:
            im.verify()
        print(f"Wrote {p}")


if __name__ == "__main__":
    main()
