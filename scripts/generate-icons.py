#!/usr/bin/env python3
"""Generate tillandsia (air plant) icons for Tillandsias tray app.

Produces a recognizable rosette silhouette: 8 elongated, slightly curved
leaves radiating from a central point, like a real tillandsia air plant.

Output files:
  src-tauri/icons/tray-icon.png  — 32x32  white silhouette on transparent
  src-tauri/icons/32x32.png      — 32x32  green (#4CAF50) on transparent
  src-tauri/icons/128x128.png    — 128x128 green on transparent
  src-tauri/icons/icon.png       — 256x256 green on transparent
"""

import math
import os
import sys

try:
    from PIL import Image, ImageDraw
    HAS_PIL = True
except ImportError:
    HAS_PIL = False
    import struct
    import zlib


# --- Geometry: tillandsia rosette ---

def tillandsia_leaf_points(cx, cy, angle_deg, length, width, curve_amount, steps=20):
    """Generate polygon points for a single curved leaf.

    The leaf tapers from base to tip, curving slightly to one side.
    Returns a list of (x, y) tuples forming the leaf outline.
    """
    angle = math.radians(angle_deg)
    perp = angle + math.pi / 2

    points_left = []
    points_right = []

    for i in range(steps + 1):
        t = i / steps
        # Taper: widest at ~20% from base, narrowing to tip
        taper = math.sin(t * math.pi) * (1.0 - 0.3 * t)
        half_w = width * 0.5 * taper

        # Curve offset (quadratic, peaks at midpoint)
        curve_offset = curve_amount * t * (1.0 - t) * 4.0

        # Position along leaf spine
        px = cx + math.cos(angle) * length * t + math.cos(perp) * curve_offset
        py = cy + math.sin(angle) * length * t + math.sin(perp) * curve_offset

        # Left and right edges perpendicular to spine direction
        # Tangent direction changes due to curve
        if i < steps:
            t2 = (i + 1) / steps
            curve_offset2 = curve_amount * t2 * (1.0 - t2) * 4.0
            nx = cx + math.cos(angle) * length * t2 + math.cos(perp) * curve_offset2
            ny = cy + math.sin(angle) * length * t2 + math.sin(perp) * curve_offset2
            dx, dy = nx - px, ny - py
        else:
            dx = math.cos(angle) * length / steps
            dy = math.sin(angle) * length / steps
        mag = math.sqrt(dx * dx + dy * dy) or 1.0
        norm_x, norm_y = -dy / mag, dx / mag

        points_left.append((px + norm_x * half_w, py + norm_y * half_w))
        points_right.append((px - norm_x * half_w, py - norm_y * half_w))

    # Close the polygon: left side forward, right side backward
    return points_left + list(reversed(points_right))


def generate_tillandsia_polygons(size):
    """Generate all leaf polygons for a tillandsia rosette at given pixel size.

    Returns a list of polygon point-lists.
    """
    cx, cy = size / 2, size * 0.55  # center slightly below middle
    base_length = size * 0.42
    base_width = size * 0.12
    curve = size * 0.06

    num_leaves = 8
    polygons = []

    for i in range(num_leaves):
        # Radiate upward and outward; slight asymmetry for natural feel
        base_angle = -90 + (i - (num_leaves - 1) / 2) * (180 / (num_leaves - 1))
        # Alternate curve direction for natural look
        c = curve if i % 2 == 0 else -curve
        # Vary leaf length slightly
        length_factor = 1.0 - 0.12 * abs(i - (num_leaves - 1) / 2) / ((num_leaves - 1) / 2)
        leaf_len = base_length * length_factor

        poly = tillandsia_leaf_points(cx, cy, base_angle, leaf_len, base_width, c)
        polygons.append(poly)

    # Add a small central rosette (ellipse approximation)
    center_r = size * 0.06
    center_poly = []
    for a in range(0, 360, 15):
        rad = math.radians(a)
        center_poly.append((cx + math.cos(rad) * center_r,
                            cy + math.sin(rad) * center_r * 0.8))
    polygons.append(center_poly)

    return polygons


# --- PIL-based rendering ---

def render_pil(size, color):
    """Render tillandsia icon using Pillow. Returns an Image."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    polygons = generate_tillandsia_polygons(size)
    for poly in polygons:
        # Convert to flat tuple list for PIL
        flat = [(int(round(x)), int(round(y))) for x, y in poly]
        if len(flat) >= 3:
            draw.polygon(flat, fill=color)

    return img


# --- Pure-Python PNG rendering (no Pillow fallback) ---

def render_raw(size, color_rgba):
    """Render tillandsia icon to raw RGBA pixel buffer."""
    # Start with transparent
    pixels = bytearray([0, 0, 0, 0] * size * size)

    polygons = generate_tillandsia_polygons(size)

    for poly in polygons:
        fill_polygon_raw(pixels, size, poly, color_rgba)

    return bytes(pixels)


def fill_polygon_raw(pixels, size, polygon, color_rgba):
    """Scanline fill a polygon into an RGBA pixel buffer."""
    if len(polygon) < 3:
        return

    # Find bounding box
    ys = [p[1] for p in polygon]
    min_y = max(0, int(math.floor(min(ys))))
    max_y = min(size - 1, int(math.ceil(max(ys))))

    edges = []
    n = len(polygon)
    for i in range(n):
        x0, y0 = polygon[i]
        x1, y1 = polygon[(i + 1) % n]
        if y0 != y1:
            if y0 > y1:
                x0, y0, x1, y1 = x1, y1, x0, y0
            edges.append((y0, y1, x0, x1))

    for y in range(min_y, max_y + 1):
        scanline_y = y + 0.5
        intersections = []
        for ey0, ey1, ex0, ex1 in edges:
            if ey0 <= scanline_y < ey1:
                t = (scanline_y - ey0) / (ey1 - ey0)
                ix = ex0 + t * (ex1 - ex0)
                intersections.append(ix)

        intersections.sort()

        for i in range(0, len(intersections) - 1, 2):
            x_start = max(0, int(math.ceil(intersections[i])))
            x_end = min(size - 1, int(math.floor(intersections[i + 1])))
            for x in range(x_start, x_end + 1):
                offset = (y * size + x) * 4
                pixels[offset:offset + 4] = bytes(color_rgba)


def encode_png(pixels_rgba, width, height):
    """Encode raw RGBA pixels as a PNG file (minimal encoder)."""
    def chunk(chunk_type, data):
        c = chunk_type + data
        crc = struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
        return struct.pack(">I", len(data)) + c + crc

    # PNG signature
    sig = b"\x89PNG\r\n\x1a\n"

    # IHDR
    ihdr_data = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    ihdr = chunk(b"IHDR", ihdr_data)

    # IDAT — raw pixel data with filter byte (0 = None) per row
    raw_rows = bytearray()
    for y in range(height):
        raw_rows.append(0)  # filter: None
        offset = y * width * 4
        raw_rows.extend(pixels_rgba[offset:offset + width * 4])

    compressed = zlib.compress(bytes(raw_rows), 9)
    idat = chunk(b"IDAT", compressed)

    # IEND
    iend = chunk(b"IEND", b"")

    return sig + ihdr + idat + iend


# --- Main ---

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    icons_dir = os.path.join(project_root, "src-tauri", "icons")
    os.makedirs(icons_dir, exist_ok=True)

    green = (76, 175, 80, 255)   # #4CAF50
    white = (255, 255, 255, 255)

    specs = [
        ("tray-icon.png", 32, white),
        ("32x32.png", 32, green),
        ("128x128.png", 128, green),
        ("icon.png", 256, green),
    ]

    if HAS_PIL:
        print("Using Pillow for rendering")
        for filename, size, color in specs:
            img = render_pil(size, color)
            path = os.path.join(icons_dir, filename)
            img.save(path, "PNG")
            file_size = os.path.getsize(path)
            print(f"  {filename}: {size}x{size}, {file_size} bytes")
    else:
        print("Pillow not available, using raw PNG encoder")
        for filename, size, color in specs:
            pixels = render_raw(size, color)
            png_data = encode_png(pixels, size, size)
            path = os.path.join(icons_dir, filename)
            with open(path, "wb") as f:
                f.write(png_data)
            file_size = os.path.getsize(path)
            print(f"  {filename}: {size}x{size}, {file_size} bytes")

    print(f"\nAll icons written to {icons_dir}")


if __name__ == "__main__":
    main()
