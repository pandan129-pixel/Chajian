#!/usr/bin/env python3
"""Symbolized arm64 disassembler for a thin Mach-O (capstone + otool -Iv + chained fixups)."""
import sys, subprocess, re, struct
import lief
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import ARM64_OP_IMM

path = sys.argv[1]
start = int(sys.argv[2], 16) if len(sys.argv) > 2 else None
end = int(sys.argv[3], 16) if len(sys.argv) > 3 else None

b = lief.parse(path)
raw = open(path, 'rb').read()
text = b.get_section('__text')
base = text.virtual_address
code = bytes(text.content)

stubmap = {}
out = subprocess.run(['otool', '-Iv', path], capture_output=True, text=True).stdout
for line in out.splitlines():
    m = re.match(r'^0x([0-9a-f]+)\s+\d+\s+(\S+)$', line.strip())
    if m:
        stubmap[int(m.group(1), 16)] = m.group(2)

segs = [(s.virtual_address, s.virtual_size, s.file_offset) for s in b.segments]

def rd(va, n):
    for va0, vs, off in segs:
        if va0 <= va < va0 + vs:
            o = off + (va - va0)
            return raw[o:o+n]
    return b''

def cstr(va):
    d = rd(va, 256)
    z = d.find(b'\0')
    return d[:z].decode('utf-8', 'replace') if z >= 0 else ''

selsec = b.get_section('__objc_selrefs')
clsec = b.get_section('__objc_classrefs')
SEL_LO = selsec.virtual_address
SEL_HI = SEL_LO + selsec.size
CL_LO = clsec.virtual_address
CL_HI = CL_LO + clsec.size

# chained fixup imports: map 1-based ordinal -> symbol name
imports = []
def parse_chained_imports():
    # find LC_DYLD_CHAINED_FIXUPS dataoff
    dataoff = datasize = None
    off = 0
    ncmds = struct.unpack_from('<I', raw, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', raw, off)
        if cmd == 0x80000034:  # LC_DYLD_CHAINED_FIXUPS
            dataoff, datasize = struct.unpack_from('<II', raw, off + 8)
        off += cmdsize
    if dataoff is None:
        return []
    h = dataoff
    fixups_version, starts_offset, imports_offset, symbols_offset, imports_count, imports_format, symbols_format = \
        struct.unpack_from('<7I', raw, h)
    symbase = h + symbols_offset
    res = []
    for i in range(imports_count):
        if imports_format == 1:
            v = struct.unpack_from('<I', raw, h + imports_offset + i*4)[0]
            name_off = v >> 9
        elif imports_format == 2:
            v = struct.unpack_from('<Q', raw, h + imports_offset + i*8)[0]
            name_off = v >> 32
        else:
            v = struct.unpack_from('<Q', raw, h + imports_offset + i*8)[0]
            name_off = v >> 32
        s = raw[symbase + name_off:]
        z = s.find(b'\0')
        res.append(s[:z].decode('utf-8', 'replace'))
    return res

imports = parse_chained_imports()

def annotate_literal(addr):
    if SEL_LO <= addr < SEL_HI:
        v = struct.unpack('<Q', rd(addr, 8))[0] & 0xffffffff
        return f'  ; sel "{cstr(v)}"'
    if CL_LO <= addr < CL_HI:
        v = struct.unpack('<Q', rd(addr, 8))[0]
        ordinal = v & 0xffffff
        name = imports[ordinal] if 0 <= ordinal < len(imports) else f'ord{ordinal}'
        return f'  ; cls {name}'
    return ''

md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True

lo = start if start is not None else base
hi = end if end is not None else base + len(code)
chunk = code[lo - base: lo - base + (hi - lo)]

print(f"// {path}  __text {base:#x} size {len(code):#x}")
for ins in md.disasm(chunk, lo):
    extra = ''
    if ins.mnemonic in ('ldr', 'adr', 'adrp') and ins.op_str.startswith('x'):
        for op in ins.operands:
            if op.type == ARM64_OP_IMM:
                extra += annotate_literal(op.imm)
    for op in ins.operands:
        if op.type == ARM64_OP_IMM and ins.mnemonic.startswith('b'):
            s = stubmap.get(op.imm)
            if s:
                extra += f'   ; -> {s}'
    print(f'{ins.address:08x}: {ins.mnemonic:<8} {ins.op_str}{extra}')
