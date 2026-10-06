#!/usr/bin/env python3
"""Print the CSS data URI of the header's tile pattern, for .hilal-band in static/app.css.

The pattern is the Persian star-and-cross: eight-pointed stars on a square grid,
with the crosses formed by the gaps between them. One 40 x 40 tile holds a star
at its centre and a quarter star at each corner; CSS repeats it.
"""

import math
import urllib.parse

SIZE = 40
OUTER = 14                  # star tip radius
INNER = OUTER * 0.7654      # notch radius: cos 45 / cos 22.5 gives the classic {8/2} star
GOLD = "#D4AF37"
OPACITY = "0.32"


def star(cx, cy):
    points = []
    for k in range(16):
        angle = -math.pi / 2 + k * math.pi / 8
        radius = INNER if k % 2 else OUTER
        points.append(f"{cx + radius * math.cos(angle):.2f},{cy + radius * math.sin(angle):.2f}")
    return " ".join(points)


centres = [(0, 0), (SIZE, 0), (0, SIZE), (SIZE, SIZE), (SIZE / 2, SIZE / 2)]
stars = "".join(f"<polygon points='{star(x, y)}'/>" for x, y in centres)
dots = "".join(f"<circle cx='{x:g}' cy='{y:g}' r='2.2'/>" for x, y in centres)
svg = (
    f"<svg xmlns='http://www.w3.org/2000/svg' width='{SIZE}' height='{SIZE}' viewBox='0 0 {SIZE} {SIZE}'>"
    f"<g fill='none' stroke='{GOLD}' stroke-opacity='{OPACITY}' stroke-width='1'>{stars}</g>"
    f"<g fill='{GOLD}' fill-opacity='{OPACITY}'>{dots}</g></svg>"
)
print("data:image/svg+xml," + urllib.parse.quote(svg, safe="/:=,' .-"))
