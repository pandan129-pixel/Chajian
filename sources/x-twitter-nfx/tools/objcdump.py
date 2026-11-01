#!/usr/bin/env python3
"""Dump Objective-C class -> {selector: type} using `otool -oV` + chained selrefs.

otool resolves class and method-list addresses for chained-fixup binaries but
does not print selector strings for relative method lists.  The parenthesised
address of a `name` entry is an __objc_selrefs slot holding a chained pointer;
we decode it to get the selector string.
"""
import json
import re
import struct
import subprocess
import sys

import lief

CLASS_RE = re.compile(r'^\s*[0-9a-f]+\s+[0-9a-fx]+\s+_OBJC_CLASS_\$_(\S+)\s*$')
META_RE = re.compile(r'^Meta Class\s*$')
NAME_RE = re.compile(r'^\s+name\s+0x[0-9a-f]+\s+\(0x([0-9a-f]+)\)\s*$')
TYPES_RE = re.compile(r'^\s+types\s+0x[0-9a-f]+\s+\(0x([0-9a-f]+)\)\s*(.*?)\s*$')
TYPES_PLAIN_RE = re.compile(r'^\s+types\s+0x[0-9a-f]+\s+(\S+)\s*$')


class Reader:
    def __init__(self, path):
        self.path = path
        self.b = lief.parse(path)
        self.d = open(path, 'rb').read()
        self.segs = [(s.virtual_address, s.virtual_size, s.file_offset, s.file_size)
                     for s in self.b.segments]

    def off(self, va):
        for vaddr, vsize, foff, fsize in self.segs:
            if vaddr <= va < vaddr + vsize:
                o = foff + (va - vaddr)
                return o if 0 <= o < len(self.d) else None
        return None

    def u64(self, va):
        o = self.off(va)
        return struct.unpack_from('<Q', self.d, o)[0] if o is not None else 0

    def decode(self, v):
        if not v:
            return 0
        if v >> 63:  # auth pointer: target is low 32 bits + high8
            target = v & 0xFFFFFFFF
            return target | (((v >> 36) & 0xFF) << 56)
        target = v & 0xFFFFFFFFF
        high8 = (v >> 36) & 0xFF
        return target | (high8 << 56)

    def cstr(self, va):
        o = self.off(va)
        if o is None:
            return None
        e = self.d.find(b'\x00', o)
        return self.d[o:e].decode('utf-8', 'replace')


def parse(path):
    r = Reader(path)
    out = subprocess.run(['otool', '-oV', path], capture_output=True, text=True,
                         errors='replace').stdout
    db = {}
    cls = None
    meta = False
    pend = None
    for line in out.splitlines():
        m = CLASS_RE.match(line)
        if m:
            cls, meta, pend = m.group(1), False, None
            db.setdefault(cls, {})
            continue
        if META_RE.match(line):
            meta, pend = True, None
            continue
        if cls is None:
            continue
        m = NAME_RE.match(line)
        if m:
            va = int(m.group(1), 16)
            sel_va = r.decode(r.u64(va))
            pend = r.cstr(sel_va) if sel_va else None
            continue
        m = TYPES_RE.match(line)
        if m:
            typ = m.group(2).strip()
            if not typ:
                typ = r.cstr(int(m.group(1), 16)) or ''
            if pend:
                db[cls][('+' if meta else '-') + pend] = typ
            pend = None
            continue
        m = TYPES_PLAIN_RE.match(line)
        if m and pend:
            db[cls][('+' if meta else '-') + pend] = m.group(1)
            pend = None
    return {k: v for k, v in db.items() if v}


if __name__ == '__main__':
    print(json.dumps(parse(sys.argv[1]), ensure_ascii=False))
