#!/usr/bin/env python3
"""Patch WeifengAdClean.dylib for 7.1.2 / TweakInject use.

Changes
  1. Keep only the arm64 slice (the WeiFeng app binary is thin arm64).
  2. Remove the "学习声明" (learning notice) alert that fires on every launch:
       at 0x26830  `tbnz w20, #0, 0x26bb0`   (skip if already shown)
     ->             `b 0x26bb0`              (always skip)
  3. Retarget libsubstrate from @loader_path to @loader_path/.jbroot (RootHide).

Run:  python3 scripts/patch-dylib.py
"""
import os
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'src/WeifengAdClean.orig.dylib')
OUT = os.path.join(ROOT, 'build/WeifengAdClean.dylib')

NOTICE_VA = 0x26830
TBNZ = 0x37001c14          # tbnz w20, #0, 0x26bb0
B_SKIP = 0x140000e0        # b 0x26bb0


def text_off(path):
    """Return (file_offset, virtual_address) of __text for a thin Mach-O."""
    import lief
    b = lief.parse(path)
    sec = b.get_section('__text')
    return sec.offset, sec.virtual_address


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    subprocess.run(['lipo', SRC, '-thin', 'arm64', '-output', OUT], check=True)

    off, va = text_off(OUT)
    pos = off + (NOTICE_VA - va)
    with open(OUT, 'r+b') as f:
        f.seek(pos)
        cur = struct.unpack('<I', f.read(4))[0]
        if cur == TBNZ:
            f.seek(pos)
            f.write(struct.pack('<I', B_SKIP))
            print(f'patched notice check at {NOTICE_VA:#x} (file {pos:#x})')
        elif cur == B_SKIP:
            print('notice already patched')
        else:
            raise SystemExit(f'unexpected instruction at {NOTICE_VA:#x}: {cur:#010x}')

    subprocess.run(['install_name_tool', '-change',
                    '@loader_path/libsubstrate.dylib',
                    '@loader_path/.jbroot/usr/lib/libsubstrate.dylib', OUT],
                   check=False)
    subprocess.run(['codesign', '-f', '-s', '-', OUT], check=True)
    print('built', OUT)


if __name__ == '__main__':
    main()
