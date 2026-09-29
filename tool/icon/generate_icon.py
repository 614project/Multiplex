"""Writes the Multiplex app icon variants as SVG (plus HTML wrappers for rendering).

Render each variant to a 1024x1024 PNG with a headless Chromium, e.g.

    python3 tool/icon/generate_icon.py
    chromium --headless --hide-scrollbars --default-background-color=00000000 \
        --window-size=1024,1024 --screenshot=tile.png file://$PWD/tile.html

then downscale with ImageMagick into the platform icon folders:
  full        iOS AppIcon (flattened, no alpha)
  rounded     macOS AppIcon
  tile        Windows app_icon.ico, Android legacy ic_launcher, assets/icon/multiplex.png
  foreground  Android adaptive foreground (background is the gradient alone)
  monochrome  Android 13 themed icon
"""
import re

def glyph(cx, cy, size):
    """2x2 grid of prompt cells; the bottom-right one is 'generating' (sparkle)."""
    cell = size * 0.46
    gap = size * 0.08
    r = cell * 0.22
    x0 = cx - size / 2
    y0 = cy - size / 2
    parts = []
    fills = ['url(#cellA)', 'url(#cellB)', 'url(#cellB)', 'url(#accent)']
    for i in range(4):
        x = x0 + (i % 2) * (cell + gap)
        y = y0 + (i // 2) * (cell + gap)
        parts.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{cell:.1f}" height="{cell:.1f}" rx="{r:.1f}" fill="{fills[i]}"/>')
    sx = x0 + cell + gap + cell / 2
    sy = y0 + cell + gap + cell / 2
    s = cell * 0.36
    parts.append(
        f'<path d="M{sx:.1f},{sy - s:.1f} Q{sx:.1f},{sy:.1f} {sx + s:.1f},{sy:.1f} Q{sx:.1f},{sy:.1f} {sx:.1f},{sy + s:.1f} '
        f'Q{sx:.1f},{sy:.1f} {sx - s:.1f},{sy:.1f} Q{sx:.1f},{sy:.1f} {sx:.1f},{sy - s:.1f} Z" fill="#FFFFFF"/>')
    s2 = s * 0.38
    tx, ty = sx + s * 0.78, sy - s * 0.78
    parts.append(
        f'<path d="M{tx:.1f},{ty - s2:.1f} Q{tx:.1f},{ty:.1f} {tx + s2:.1f},{ty:.1f} Q{tx:.1f},{ty:.1f} {tx:.1f},{ty + s2:.1f} '
        f'Q{tx:.1f},{ty:.1f} {tx - s2:.1f},{ty:.1f} Q{tx:.1f},{ty:.1f} {tx:.1f},{ty - s2:.1f} Z" fill="#FFFFFF" opacity="0.9"/>')
    return '\n'.join(parts)

def monochrome(cx, cy, size):
    body = glyph(cx, cy, size)
    cells = [line for line in body.split('\n') if line.startswith('<rect')]
    sparkles = [line for line in body.split('\n') if line.startswith('<path')]
    cells = [re.sub(r'fill="[^"]+"', 'fill="#000"', c) for c in cells]
    sparkles = [re.sub(r'fill="[^"]+"', 'fill="#000"', s).replace(' opacity="0.9"', '') for s in sparkles]
    return ('<mask id="cut"><rect width="1024" height="1024" fill="#fff"/>' + ''.join(sparkles) + '</mask>'
            '<g mask="url(#cut)">' + ''.join(cells) + '</g>')

DEFS = '''<defs>
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#7C74F2"/><stop offset="1" stop-color="#4338C2"/>
</linearGradient>
<linearGradient id="cellA" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E8E6FF"/>
</linearGradient>
<linearGradient id="cellB" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.62"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0.46"/>
</linearGradient>
<linearGradient id="accent" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#FFC78F"/><stop offset="1" stop-color="#FF7F6B"/>
</linearGradient>
<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
  <feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#1B1464" flood-opacity="0.35"/>
</filter>
</defs>'''

def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{DEFS}{body}</svg>'

variants = {
    # Full-bleed square (iOS, which applies its own mask).
    'full': svg(f'<rect width="1024" height="1024" fill="url(#bg)"/>{glyph(512, 512, 600)}'),
    # macOS / desktop style: rounded square on a transparent canvas with a soft shadow.
    'rounded': svg(f'<rect x="100" y="92" width="824" height="824" rx="185" fill="url(#bg)" filter="url(#shadow)"/>{glyph(512, 504, 480)}'),
    # Nearly full-size rounded square (Windows, Linux, Android legacy).
    'tile': svg(f'<rect x="32" y="32" width="960" height="960" rx="216" fill="url(#bg)"/>{glyph(512, 512, 560)}'),
    # Android adaptive foreground: glyph inside the 66/108 safe zone on transparency.
    'foreground': svg(glyph(512, 512, 430)),
    # Android 13 themed icon: single colour silhouette.
    'monochrome': svg(monochrome(512, 512, 430)),
}
for name, content in variants.items():
    open(f'{name}.svg', 'w').write(content)
    open(f'{name}.html', 'w').write(
        f'<html><body style="margin:0;background:transparent">{content}</body></html>')
