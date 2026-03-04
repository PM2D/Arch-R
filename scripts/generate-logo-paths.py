#!/usr/bin/env python3
"""
Arch R — Generate SVG path data from Quantico font for splash logo.

Reads Quantico-Regular.ttf and extracts glyph outlines for "ARCH" + "R",
outputting scripts/splash/archr-logo.h with C-embeddable SVG path strings.

This script runs OFFLINE (not part of the build pipeline).
The generated archr-logo.h is committed to the repo.

Usage:
    python3 scripts/generate-logo-paths.py
    # or with venv:
    /tmp/fonttools-venv/bin/python3 scripts/generate-logo-paths.py
"""

import os
import sys

try:
    from fontTools.ttLib import TTFont
    from fontTools.pens.svgPathPen import SVGPathPen
except ImportError:
    print("ERROR: fonttools not installed. Install with: pip install fonttools", file=sys.stderr)
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
FONT_PATH = os.path.join(PROJECT_DIR, "assets", "fonts", "Quantico-Regular.ttf")
OUTPUT_PATH = os.path.join(SCRIPT_DIR, "splash", "archr-logo.h")

# Logo layout: "ARCH" in blue + " R" in white
ARCH_GLYPHS = ["A", "R", "C", "H"]
R_GLYPH = "R"

# Colors
ARCH_COLOR = "rgb(23,147,209)"  # Arch Linux blue #1793D1
R_COLOR = "rgb(255,255,255)"    # White

# Spacing between ARCH and R (in font units)
WORD_SPACE_FACTOR = 0.25  # 25% of font UPM as space between words


def extract_glyph_path(font, glyph_name, x_offset=0, y_offset=0):
    """Extract SVG path string for a glyph with optional offset."""
    glyf = font['glyf']
    glyph = glyf[glyph_name]

    if glyph.numberOfContours == 0:
        return None, 0

    # Get advance width for positioning
    hmtx = font['hmtx']
    advance_width = hmtx[glyph_name][0]

    pen = SVGPathPen(font.getGlyphSet())

    # We need to draw with offset
    gs = font.getGlyphSet()
    gs[glyph_name].draw(pen)

    path_str = pen.getCommands()
    if not path_str:
        return None, advance_width

    # Apply offset by modifying the path commands
    if x_offset != 0 or y_offset != 0:
        path_str = offset_svg_path(path_str, x_offset, y_offset)

    return path_str, advance_width


def offset_svg_path(path_str, dx, dy):
    """Offset all coordinates in an SVG path string by (dx, dy)."""
    import re

    result = []
    i = 0
    s = path_str

    while i < len(s):
        if s[i] in 'MmLlHhVvCcSsQqTtAaZz':
            cmd = s[i]
            result.append(cmd)
            i += 1

            if cmd in 'Zz':
                continue

            # Parse numbers after command
            while i < len(s) and s[i] not in 'MmLlHhVvCcSsQqTtAaZz':
                # Skip whitespace and commas
                while i < len(s) and s[i] in ' ,\t\n':
                    result.append(s[i])
                    i += 1

                if i >= len(s) or s[i] in 'MmLlHhVvCcSsQqTtAaZz':
                    break

                # Parse a number
                num_start = i
                if s[i] == '-':
                    i += 1
                while i < len(s) and (s[i].isdigit() or s[i] == '.'):
                    i += 1
                # Handle scientific notation
                if i < len(s) and s[i] in 'eE':
                    i += 1
                    if i < len(s) and s[i] in '+-':
                        i += 1
                    while i < len(s) and s[i].isdigit():
                        i += 1

                num_str = s[num_start:i]
                if num_str:
                    result.append(num_str)
        else:
            result.append(s[i])
            i += 1

    return ''.join(result)


def extract_glyph_path_with_offset(font, char, x_offset, y_offset=0):
    """Extract glyph path and apply coordinate offset at path level."""
    cmap = font.getBestCmap()
    glyph_name = cmap.get(ord(char))
    if not glyph_name:
        print(f"WARNING: Glyph not found for '{char}'", file=sys.stderr)
        return None, 0

    glyf = font['glyf']
    hmtx = font['hmtx']
    advance_width = hmtx[glyph_name][0]

    # Use a recording pen to get the path with offset
    gs = font.getGlyphSet()
    pen = SVGPathPen(gs)
    gs[glyph_name].draw(pen)
    path_str = pen.getCommands()

    if not path_str:
        return None, advance_width

    # Parse and rebuild path with offsets applied to absolute coordinates
    path_str = apply_offset_to_path(path_str, x_offset, y_offset)

    return path_str, advance_width


def apply_offset_to_path(path_data, dx, dy):
    """Apply coordinate offset to SVG path data (absolute commands only)."""
    import re

    tokens = []
    i = 0
    while i < len(path_data):
        if path_data[i] in 'MmLlHhVvCcSsQqTtAaZz':
            tokens.append(path_data[i])
            i += 1
        elif path_data[i] in ' ,\t\n':
            i += 1
        elif path_data[i] == '-' or path_data[i].isdigit() or path_data[i] == '.':
            j = i
            if path_data[i] == '-':
                i += 1
            while i < len(path_data) and (path_data[i].isdigit() or path_data[i] == '.'):
                i += 1
            if i < len(path_data) and path_data[i] in 'eE':
                i += 1
                if i < len(path_data) and path_data[i] in '+-':
                    i += 1
                while i < len(path_data) and path_data[i].isdigit():
                    i += 1
            tokens.append(float(path_data[j:i]))
        else:
            i += 1

    # Process tokens: apply offset to absolute coordinate commands
    result_parts = []
    ti = 0
    while ti < len(tokens):
        tok = tokens[ti]
        if isinstance(tok, str):
            cmd = tok
            ti += 1

            if cmd == 'Z' or cmd == 'z':
                result_parts.append(cmd)
                continue

            # Determine how many coordinate pairs per command
            if cmd == 'M' or cmd == 'L':
                # Pairs of (x, y) — offset both
                while ti < len(tokens) and isinstance(tokens[ti], float):
                    x = tokens[ti] + dx
                    y = tokens[ti + 1] + dy
                    result_parts.append(f"{cmd} {x:.3f} {y:.3f}")
                    ti += 2
                    cmd = 'L' if cmd == 'M' else cmd  # After M, implicit L
            elif cmd == 'H':
                while ti < len(tokens) and isinstance(tokens[ti], float):
                    x = tokens[ti] + dx
                    result_parts.append(f"H {x:.3f}")
                    ti += 1
            elif cmd == 'V':
                while ti < len(tokens) and isinstance(tokens[ti], float):
                    y = tokens[ti] + dy
                    result_parts.append(f"V {y:.3f}")
                    ti += 1
            elif cmd == 'C':
                while ti + 5 < len(tokens) and isinstance(tokens[ti], float):
                    x1 = tokens[ti] + dx
                    y1 = tokens[ti + 1] + dy
                    x2 = tokens[ti + 2] + dx
                    y2 = tokens[ti + 3] + dy
                    x3 = tokens[ti + 4] + dx
                    y3 = tokens[ti + 5] + dy
                    result_parts.append(f"C {x1:.3f} {y1:.3f} {x2:.3f} {y2:.3f} {x3:.3f} {y3:.3f}")
                    ti += 6
            elif cmd == 'Q':
                while ti + 3 < len(tokens) and isinstance(tokens[ti], float):
                    x1 = tokens[ti] + dx
                    y1 = tokens[ti + 1] + dy
                    x2 = tokens[ti + 2] + dx
                    y2 = tokens[ti + 3] + dy
                    result_parts.append(f"Q {x1:.3f} {y1:.3f} {x2:.3f} {y2:.3f}")
                    ti += 4
            else:
                # Unknown command, pass through
                result_parts.append(cmd)
        else:
            ti += 1

    return ' '.join(result_parts)


def main():
    if not os.path.exists(FONT_PATH):
        print(f"ERROR: Font not found: {FONT_PATH}", file=sys.stderr)
        sys.exit(1)

    font = TTFont(FONT_PATH)
    cmap = font.getBestCmap()
    hmtx = font['hmtx']
    os2 = font['OS/2']
    upm = font['head'].unitsPerEm

    # Font metrics for vertical positioning
    ascender = os2.sTypoAscender
    descender = os2.sTypoDescender
    total_height = ascender - descender

    # SVG coordinate system: Y increases downward
    # Font coordinate system: Y increases upward
    # We need to flip Y: svg_y = ascender - font_y

    print(f"Font: Quantico-Regular")
    print(f"UPM: {upm}, Ascender: {ascender}, Descender: {descender}")

    # Calculate total width for "ARCH R" layout
    paths = []
    colors = []
    x_cursor = 0

    # Extract "ARCH" glyphs
    for char in ARCH_GLYPHS:
        glyph_name = cmap.get(ord(char))
        if not glyph_name:
            print(f"ERROR: No glyph for '{char}'", file=sys.stderr)
            sys.exit(1)

        path_str, advance = extract_glyph_path_with_offset(font, char, x_cursor, 0)
        if path_str:
            paths.append(path_str)
            colors.append(ARCH_COLOR)
            print(f"  {char}: advance={advance}, offset={x_cursor}")
        x_cursor += advance

    # Add word space
    space_glyph = cmap.get(ord(' '))
    if space_glyph:
        space_advance = hmtx[space_glyph][0]
    else:
        space_advance = int(upm * WORD_SPACE_FACTOR)
    x_cursor += space_advance
    print(f"  Space: {space_advance}")

    # Extract "R" glyph (white)
    path_str, advance = extract_glyph_path_with_offset(font, R_GLYPH, x_cursor, 0)
    if path_str:
        paths.append(path_str)
        colors.append(R_COLOR)
        print(f"  R (white): advance={advance}, offset={x_cursor}")
    x_cursor += advance

    total_width = x_cursor

    # The Y coordinate in font is bottom-up, SVG is top-down
    # Flip all Y coordinates: new_y = ascender - old_y
    flipped_paths = []
    for p in paths:
        flipped = flip_y_coordinates(p, ascender)
        flipped_paths.append(flipped)

    # Bounding box
    svg_width = total_width
    svg_height = total_height

    print(f"\nBounding box: {svg_width} x {svg_height}")
    print(f"Paths: {len(flipped_paths)}")

    # Generate C header
    generate_header(flipped_paths, colors, svg_width, svg_height)

    font.close()
    print(f"\nGenerated: {OUTPUT_PATH}")


def flip_y_coordinates(path_data, ascender):
    """Flip Y coordinates for SVG (font Y-up → SVG Y-down)."""
    import re

    tokens = []
    i = 0
    while i < len(path_data):
        if path_data[i] in 'MmLlHhVvCcSsQqTtAaZz':
            tokens.append(path_data[i])
            i += 1
        elif path_data[i] in ' ,\t\n':
            i += 1
        elif path_data[i] == '-' or path_data[i].isdigit() or path_data[i] == '.':
            j = i
            if path_data[i] == '-':
                i += 1
            while i < len(path_data) and (path_data[i].isdigit() or path_data[i] == '.'):
                i += 1
            if i < len(path_data) and path_data[i] in 'eE':
                i += 1
                if i < len(path_data) and path_data[i] in '+-':
                    i += 1
                while i < len(path_data) and path_data[i].isdigit():
                    i += 1
            tokens.append(float(path_data[j:i]))
        else:
            i += 1

    result_parts = []
    ti = 0
    while ti < len(tokens):
        tok = tokens[ti]
        if isinstance(tok, str):
            cmd = tok
            ti += 1

            if cmd == 'Z' or cmd == 'z':
                result_parts.append(cmd)
                continue

            if cmd in ('M', 'L'):
                while ti + 1 < len(tokens) and isinstance(tokens[ti], float):
                    x = tokens[ti]
                    y = ascender - tokens[ti + 1]
                    result_parts.append(f"{cmd} {x:.3f} {y:.3f}")
                    ti += 2
                    if cmd == 'M':
                        cmd = 'L'
            elif cmd == 'H':
                while ti < len(tokens) and isinstance(tokens[ti], float):
                    result_parts.append(f"H {tokens[ti]:.3f}")
                    ti += 1
            elif cmd == 'V':
                while ti < len(tokens) and isinstance(tokens[ti], float):
                    y = ascender - tokens[ti]
                    result_parts.append(f"V {y:.3f}")
                    ti += 1
            elif cmd == 'C':
                while ti + 5 < len(tokens) and isinstance(tokens[ti], float):
                    x1 = tokens[ti]
                    y1 = ascender - tokens[ti + 1]
                    x2 = tokens[ti + 2]
                    y2 = ascender - tokens[ti + 3]
                    x3 = tokens[ti + 4]
                    y3 = ascender - tokens[ti + 5]
                    result_parts.append(f"C {x1:.3f} {y1:.3f} {x2:.3f} {y2:.3f} {x3:.3f} {y3:.3f}")
                    ti += 6
            elif cmd == 'Q':
                while ti + 3 < len(tokens) and isinstance(tokens[ti], float):
                    x1 = tokens[ti]
                    y1 = ascender - tokens[ti + 1]
                    x2 = tokens[ti + 2]
                    y2 = ascender - tokens[ti + 3]
                    result_parts.append(f"Q {x1:.3f} {y1:.3f} {x2:.3f} {y2:.3f}")
                    ti += 4
            else:
                result_parts.append(cmd)
        else:
            ti += 1

    return ' '.join(result_parts)


def generate_header(paths, colors, svg_width, svg_height):
    """Generate archr-logo.h C header file."""
    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)

    lines = []
    lines.append("/*")
    lines.append(" * Arch R — Logo SVG path data (auto-generated)")
    lines.append(" * Generated by: scripts/generate-logo-paths.py")
    lines.append(" * Font: Quantico-Regular.ttf")
    lines.append(" *")
    lines.append(" * DO NOT EDIT MANUALLY — regenerate with:")
    lines.append(" *   /tmp/fonttools-venv/bin/python3 scripts/generate-logo-paths.py")
    lines.append(" */")
    lines.append("")
    lines.append("#ifndef ARCHR_LOGO_H")
    lines.append("#define ARCHR_LOGO_H")
    lines.append("")
    lines.append(f"#define ARCHR_SVG_WIDTH  {svg_width:.1f}f")
    lines.append(f"#define ARCHR_SVG_HEIGHT {svg_height:.1f}f")
    lines.append(f"#define ARCHR_NUM_PATHS  {len(paths)}")
    lines.append("")

    # Path data
    lines.append("static const char *archr_svg_paths[] = {")
    for i, path in enumerate(paths):
        # Split long paths for readability
        comma = "," if i < len(paths) - 1 else ""
        # Escape any quotes in path data (shouldn't happen, but safety)
        escaped = path.replace('"', '\\"')
        lines.append(f'    "{escaped}"{comma}')
    lines.append("};")
    lines.append("")

    # Colors
    lines.append("static const char *archr_svg_colors[] = {")
    for i, color in enumerate(colors):
        comma = "," if i < len(colors) - 1 else ""
        lines.append(f'    "{color}"{comma}')
    lines.append("};")
    lines.append("")
    lines.append("#endif")
    lines.append("")

    with open(OUTPUT_PATH, 'w') as f:
        f.write('\n'.join(lines))


if __name__ == '__main__':
    main()
