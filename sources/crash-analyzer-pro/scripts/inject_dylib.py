#!/usr/bin/env python3
"""Add an LC_LOAD_DYLIB command to a thin arm64/arm64e Mach-O."""
import struct
import sys

LC_LOAD_DYLIB = 0xC
MH_MAGIC_64 = 0xFEEDFACF


def align8(n):
    return (n + 7) & ~7


def inject(path, dylib_path, out_path):
    data = bytearray(open(path, "rb").read())
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from(
        "<IiiIIIII", data, 0
    )
    if magic != MH_MAGIC_64:
        raise SystemExit(f"not a thin 64-bit Mach-O: magic={magic:#x}")

    cmd_off = 0x20
    end = cmd_off + sizeofcmds
    first_section = None
    p = cmd_off
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, p)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from("<I", data, p + 64)[0]
            sect = p + 72
            for _ in range(nsects):
                # section_64: sectname[16], segname[16], addr(8), size(8), offset(4)...
                off = struct.unpack_from("<I", data, sect + 48)[0]
                if off > 0 and (first_section is None or off < first_section):
                    first_section = off
                sect += 80
        p += cmdsize

    name = dylib_path.encode("utf-8") + b"\0"
    cmdsize = align8(24 + len(name))
    if end + cmdsize > (first_section or len(data)):
        raise SystemExit(
            f"not enough header padding: end={end:#x} cmdsize={cmdsize:#x} first_section={first_section:#x}"
        )

    cmd = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, 24, 0, 0x10000, 0x10000)
    blob = cmd + name
    blob += b"\0" * (cmdsize - len(blob))
    data[end:end + cmdsize] = blob

    struct.pack_into("<II", data, 0x10, ncmds + 1, sizeofcmds + cmdsize)
    open(out_path, "wb").write(data)
    print(f"injected {dylib_path!r}: ncmds {ncmds} -> {ncmds + 1}, sizeofcmds {sizeofcmds:#x} -> {sizeofcmds + cmdsize:#x}")
    print(f"header end {end:#x}, first section {first_section:#x}, wrote {out_path}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: inject_dylib.py <macho> <dylib-install-name> <out>")
    inject(sys.argv[1], sys.argv[2], sys.argv[3])
