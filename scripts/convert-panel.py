#!/usr/bin/env python3
"""
Arch R - Panel Binary Init Sequence to panel_description Converter

Converts Rockchip BSP binary panel-init-sequence format to
archr,generic-dsi panel_description string format (G/M/I lines).

Extracts ALL display-timings from vendor DTS/DTB and generates 12
optimized timing modes for emulation-friendly FPS targets, using the
same algorithm as ROCKNIX overlay_server.

Binary format (Rockchip BSP):
  [Type] [Delay] [Length] [Cmd] [Param1] [Param2] ...
  Type 0x05 = DCS short write (no params, length=1)
  Type 0x15 = DCS short write with params (length=2)
  Type 0x39 = DCS long write (variable length)

Output format (panel_description):
  G size=W,H delays=P,R,I,E,Y format=rgb888 lanes=4 flags=0xNNN
  M clock=KHZ horizontal=H,HFP,HSYNC,HBP vertical=V,VFP,VSYNC,VBP default=1
  M clock=KHZ horizontal=... vertical=...    (11 more modes)
  I seq=HEXDATA wait=DELAY

Usage:
  # Full panel conversion with auto-extracted timing modes
  python3 convert-panel.py --dts Panel0.dts \\
    --width 52 --height 70 \\
    --prepare 2 --reset 1 --init 25 --enable 120 --ready 50 \\
    --lanes 4 --flags 0xe03

  # From compiled DTB
  python3 convert-panel.py --dtb panel.dtb \\
    --width 153 --height 85 \\
    --prepare 20 --reset 20 --init 20 --enable 120 --ready 20 \\
    --lanes 4 --flags 0xe03
"""

import argparse
import math
import re
import subprocess
import sys


# ============================================================================
# Emulation-friendly FPS targets (same as ROCKNIX overlay_server)
# https://tasvideos.org/PlatformFramerates
# ============================================================================
COMMON_FPS = [
    50 / 1.001,   # NTSC-PAL with 1001 divisor
    50,            # PAL generic
    50.0070,       # PAL NES
    57.5,          # Kaneko snowbros
    59.7275,       # Game Boy
    60 / 1.001,    # NTSC with 1001 divisor
    60,            # Generic
    60.0988,       # NTSC NES
    75.47,         # WonderSwan
    90,            # High refresh
    120,           # Double refresh
]


def parse_init_hex(hex_str):
    """Parse space-separated hex bytes into panel_description I lines (seq format)."""
    bytes_list = hex_str.strip().split()
    lines = []
    i = 0

    while i < len(bytes_list):
        if i + 2 >= len(bytes_list):
            break

        delay = int(bytes_list[i + 1], 16)
        length = int(bytes_list[i + 2], 16)

        if i + 3 + length - 1 > len(bytes_list):
            break

        if length < 1:
            i += 3
            continue

        data = bytes_list[i + 3:i + 3 + length]
        data_hex = ''.join(data)
        maybe_wait = f' wait={delay}' if delay > 0 else ''
        lines.append(f'I seq={data_hex}{maybe_wait}')

        i += 3 + length

    return lines


def get_dts_content(path):
    """Get DTS text content — decompile if DTB."""
    if path.endswith('.dtb'):
        result = subprocess.run(
            ['dtc', '-I', 'dtb', '-O', 'dts', path],
            capture_output=True, text=True, timeout=10
        )
        return result.stdout
    else:
        with open(path, 'r', errors='replace') as f:
            return f.read()


def extract_init_hex(content):
    """Extract panel-init-sequence hex bytes from DTS content."""
    m = re.search(r'panel-init-sequence\s*=\s*\[([^\]]+)\]', content)
    if not m:
        return None
    return re.sub(r'\s+', ' ', m.group(1).strip())


def extract_display_timings(content):
    """Extract all display-timings from DTS content.

    Returns (native_phandle, list of mode dicts).
    Each mode dict: {clock, hor: [hactive, hfp, hsync, hbp],
                     ver: [vactive, vfp, vsync, vbp], phandle}
    """
    # Find native-mode phandle
    native_match = re.search(r'native-mode\s*=\s*<(0x[0-9a-fA-F]+|\d+)>', content)
    native_phandle = None
    if native_match:
        val = native_match.group(1)
        native_phandle = int(val, 16) if val.startswith('0x') else int(val)

    # Find the display-timings block
    dt_match = re.search(r'display-timings\s*\{', content)
    if not dt_match:
        return native_phandle, []

    # Find all timing nodes within display-timings
    start = dt_match.end()
    # Find matching closing brace
    depth = 1
    pos = start
    while pos < len(content) and depth > 0:
        if content[pos] == '{':
            depth += 1
        elif content[pos] == '}':
            depth -= 1
        pos += 1
    dt_block = content[start:pos - 1]

    # Parse individual timing nodes
    modes = []
    # Match timing node: name { ... }
    node_pattern = re.compile(r'(\w[\w@-]*)\s*\{([^{}]+)\}')
    for match in node_pattern.finditer(dt_block):
        body = match.group(2)

        def get_prop(name):
            m = re.search(rf'{name}\s*=\s*<(0x[0-9a-fA-F]+|\d+)>', body)
            if not m:
                return None
            val = m.group(1)
            return int(val, 16) if val.startswith('0x') else int(val)

        clock_hz = get_prop('clock-frequency')
        if clock_hz is None:
            continue

        hactive = get_prop('hactive')
        vactive = get_prop('vactive')
        if hactive is None or vactive is None:
            continue

        mode = {
            'clock': round(clock_hz / 1000),  # Hz to kHz
            'hor': [
                hactive,
                get_prop('hfront-porch') or 0,
                get_prop('hsync-len') or 0,
                get_prop('hback-porch') or 0,
            ],
            'ver': [
                vactive,
                get_prop('vfront-porch') or 0,
                get_prop('vsync-len') or 0,
                get_prop('vback-porch') or 0,
            ],
            'phandle': get_prop('phandle'),
        }
        modes.append(mode)

    return native_phandle, modes


def generate_m_lines(vendor_modes, native_phandle):
    """Generate 12 optimized M lines from vendor display-timings.

    Uses the same algorithm as ROCKNIX overlay_server (rocknix_dtbo.py).
    """
    if not vendor_modes:
        return []

    # Build fps→mode map from vendor modes
    modes = {}
    orig_def_fps = None
    for mode in vendor_modes:
        htotal = sum(mode['hor'])
        vtotal = sum(mode['ver'])
        fps = mode['clock'] * 1000 / (htotal * vtotal)

        if fps not in modes:
            modes[fps] = mode

        if native_phandle is not None and mode['phandle'] == native_phandle:
            modes[fps]['default'] = True
            orig_def_fps = fps

    # If no native-mode matched, use highest fps mode as default
    if orig_def_fps is None:
        orig_def_fps = max(modes.keys())
        modes[orig_def_fps]['default'] = True

    def_fps = orig_def_fps

    # Build target fps list: native first, then common targets (excluding native)
    target_fpss = [fps for fps in COMMON_FPS if fps != orig_def_fps]
    all_targets = [orig_def_fps] + target_fpss

    result = []
    for targetfps in all_targets:
        if not targetfps:
            continue

        # Find nearest vendor mode with fps >= target to base on
        greater_fps = [fps for fps in modes.keys() if fps >= targetfps]
        if not greater_fps:
            basefps = max(modes.keys())
            basemode = modes[basefps]
            clock = None
        else:
            basefps = min(greater_fps)
            basemode = modes[basefps]
            clock = basemode['clock']

        hor = basemode['hor'].copy()
        ver = basemode['ver'].copy()
        htotal = sum(hor)
        vtotal = sum(ver)
        perfectclock = targetfps * htotal * vtotal / 1000

        if not clock:
            clock = math.ceil(perfectclock / 10) * 10
        elif clock > 1.25 * perfectclock:
            clock = math.ceil(perfectclock / 10) * 10

        maxvtotal = round(vtotal * 1.25)

        # Bruteforce search for best htotal/vtotal combination
        options = []
        for vt in range(vtotal, maxvtotal + 1):
            for c in range(clock, round(1.25 * perfectclock), 10):
                newht = c * 1000 / targetfps / vt
                if newht >= htotal and newht < htotal * 1.05:
                    frac = abs(newht - round(newht))
                    options.append((frac, c, vt))

        if not options:
            continue

        mindev, newclock, newvtotal = min(options)
        newhtotal = round(newclock * 1000 / targetfps / newvtotal)
        addhtotal = newhtotal - htotal
        addvtotal = newvtotal - vtotal

        new_hor = hor.copy()
        new_ver = ver.copy()
        new_hor[2] += addhtotal  # Add to hsync
        new_ver[2] += addvtotal  # Add to vsync

        hor_str = ','.join(map(str, new_hor))
        ver_str = ','.join(map(str, new_ver))
        maybe_default = ' default=1' if targetfps == def_fps else ''
        result.append(f'M clock={newclock} horizontal={hor_str} vertical={ver_str}{maybe_default}')

    return result


def build_g_line(args):
    """Build G (globals) line from arguments."""
    parts = ['G']

    w = getattr(args, 'width', None) or -1
    h = getattr(args, 'height', None) or -1
    parts.append(f'size={w},{h}')

    p = getattr(args, 'prepare', None) or 5
    r = getattr(args, 'reset', None) or 1
    ini = getattr(args, 'init', None) or 25
    e = getattr(args, 'enable', None) or 120
    y = getattr(args, 'ready', None) or 0
    parts.append(f'delays={p},{r},{ini},{e},{y}')

    fmt = getattr(args, 'pixel_format', None) or 'rgb888'
    parts.append(f'format={fmt}')

    lanes = getattr(args, 'lanes', None) or 4
    parts.append(f'lanes={lanes}')

    flags = getattr(args, 'flags', None) or '0xa03'
    if isinstance(flags, int):
        flags = f'0x{flags:x}'
    parts.append(f'flags={flags}')

    return ' '.join(parts)


def main():
    parser = argparse.ArgumentParser(
        description='Arch R - Convert panel binary init to panel_description format'
    )

    # Input source
    input_group = parser.add_mutually_exclusive_group(required=True)
    input_group.add_argument('--init-hex', help='Hex bytes string (space-separated)')
    input_group.add_argument('--dts', help='Path to decompiled DTS file')
    input_group.add_argument('--dtb', help='Path to compiled DTB file')

    # Panel global metadata
    parser.add_argument('--width', type=int, help='Panel width in mm')
    parser.add_argument('--height', type=int, help='Panel height in mm')
    parser.add_argument('--prepare', type=int, default=5, help='Prepare delay ms')
    parser.add_argument('--reset', type=int, default=1, help='Reset delay ms')
    parser.add_argument('--init', type=int, default=25, help='Init delay ms')
    parser.add_argument('--enable', type=int, default=120, help='Enable delay ms')
    parser.add_argument('--ready', type=int, default=50, help='Ready delay ms')
    parser.add_argument('--lanes', type=int, default=4, help='DSI lanes')
    parser.add_argument('--flags', default='0xa03', help='DSI mode flags (hex)')
    parser.add_argument('--pixel-format', default='rgb888',
                        choices=['rgb888', 'rgb666', 'rgb666_packed', 'rgb565'])

    # Output format
    parser.add_argument('--format', default='text',
                        choices=['text', 'dts-overlay', 'init-only'],
                        help='Output format')

    args = parser.parse_args()

    # Get DTS content and extract init sequence
    if args.init_hex:
        hex_str = args.init_hex
        dts_content = None
    elif args.dts:
        dts_content = get_dts_content(args.dts)
        hex_str = extract_init_hex(dts_content)
        if not hex_str:
            print(f'ERROR: Could not extract panel-init-sequence from {args.dts}',
                  file=sys.stderr)
            sys.exit(1)
    elif args.dtb:
        dts_content = get_dts_content(args.dtb)
        hex_str = extract_init_hex(dts_content)
        if not hex_str:
            print(f'ERROR: Could not extract panel-init-sequence from {args.dtb}',
                  file=sys.stderr)
            sys.exit(1)

    # Convert binary init to I lines (seq format)
    i_lines = parse_init_hex(hex_str)

    if args.format == 'init-only':
        for line in i_lines:
            print(line)
        return

    # Build G line
    g_line = build_g_line(args)

    # Extract display-timings and generate 12 M lines
    m_lines = []
    if dts_content:
        native_phandle, vendor_modes = extract_display_timings(dts_content)
        if vendor_modes:
            m_lines = generate_m_lines(vendor_modes, native_phandle)

    if not m_lines:
        print('ERROR: No display-timings found in source', file=sys.stderr)
        sys.exit(1)

    # Output
    all_lines = [g_line] + m_lines + i_lines

    if args.format == 'dts-overlay':
        panel_path = '/dsi@ff450000/panel@0'
        out = [
            '/dts-v1/;',
            '/plugin/;',
            '',
            '/* Arch R panel overlay - auto-generated by convert-panel.py */',
            '',
            '/ {',
            '\tfragment@0 {',
            f'\t\ttarget-path = "{panel_path}";',
            '\t\t__overlay__ {',
            '\t\t\tcompatible = "archr,generic-dsi";',
            '\t\t\tpanel_description =',
        ]
        for idx, line in enumerate(all_lines):
            comma = ',' if idx < len(all_lines) - 1 else ';'
            out.append(f'\t\t\t\t"{line}"{comma}')
        out.extend([
            '\t\t};',
            '\t};',
            '};',
        ])
        print('\n'.join(out))
    else:
        print('\n'.join(all_lines))


if __name__ == '__main__':
    main()
