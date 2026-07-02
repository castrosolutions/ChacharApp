#!/usr/bin/env python3
"""Make a macOS-grid app-icon master (1024x1024) from the source artwork.

Follows the macOS "Big Sur" icon grid: the rounded tile occupies 824/1024 of the canvas with
transparent margin around it, so the rounded corners are clearly visible and the icon sits
correctly next to native apps. The source logo isn't square, so it's first padded to a square
using its own background colour (sampled from a corner).

Usage: process-icon.py <source.png> <out.png>   (requires Pillow)
"""
import sys
from PIL import Image, ImageDraw

src_path, out_path = sys.argv[1], sys.argv[2]

src = Image.open(src_path).convert("RGBA")
w, h = src.size
side = max(w, h)

# Pad to a square using the background colour sampled from a corner (no visible seam).
background = src.getpixel((1, 1))
square = Image.new("RGBA", (side, side), background)
square.paste(src, ((side - w) // 2, (side - h) // 2))

SIZE = 1024
TILE = 824                      # macOS icon grid: rounded tile within the 1024 canvas
MARGIN = (SIZE - TILE) // 2     # 100 px transparent margin on each side
RADIUS = round(TILE * 0.2237)   # rounded-rect corner radius (~184 px)

tile = square.resize((TILE, TILE), Image.LANCZOS)
mask = Image.new("L", (TILE, TILE), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, TILE - 1, TILE - 1], radius=RADIUS, fill=255)
tile.putalpha(mask)

canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
canvas.paste(tile, (MARGIN, MARGIN), tile)
canvas.save(out_path)
print("wrote", out_path, canvas.size)
