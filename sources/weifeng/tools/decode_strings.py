#!/usr/bin/env python3
"""Decode the XOR-obfuscated string table of WeifengAdClean.dylib.

Pattern (per string, one small function):
    lsl  wA, wB, #5
    sub  wA, wA, wB
    add  wA, wA, #K        -> key = (i*31 + K) & 0xff
    eor  wC, wC, wA
    ...
    cmp  x8, #(LEN-1)
so decoded[i] = enc[i] ^ ((i*31 + K) & 0xff)
"""
import sys, re, struct
import lief
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import ARM64_OP_IMM, ARM64_OP_REG

path = sys.argv[1]
b = lief.parse(path)
raw = open(path, 'rb').read()
text = b.get_section('__text')
base = text.virtual_address
code = bytes(text.content)
segs = [(s.virtual_address, s.virtual_size, s.file_offset) for s in b.segments]

def rd(va, n):
    for va0, vs, off in segs:
        if off is None:
            continue
        if va0 <= va < va0 + vs:
            return raw[off + (va - va0): off + (va - va0) + n]
    return b''

md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True
insns = list(md.disasm(code, base))
addr2i = {ins.address: i for i, ins in enumerate(insns)}

# ---- 1. find decryptor functions: sequence lsl/sub/add#K/eor ----
decryptors = {}   # func_start -> (K, LEN)
for i in range(len(insns) - 4):
    a, bb, c, d = insns[i:i+4]
    if (a.mnemonic == 'lsl' and bb.mnemonic == 'sub' and
        c.mnemonic == 'add' and d.mnemonic == 'eor'):
        # add wX, wX, #K
        m = re.match(r'w\d+, w\d+, #(0x[0-9a-f]+|\d+)$', c.op_str)
        if not m:
            continue
        K = int(m.group(1), 0)
        # walk backwards to function start (sub sp, sp, #N)
        j = i
        while j > 0:
            if insns[j].mnemonic == 'sub' and insns[j].op_str.startswith('sp, sp, #'):
                break
            j -= 1
        fstart = insns[j].address
        # find LEN: the `mov w3, #N` passed to initWithBytes:length:encoding:
        LEN = None
        for k in range(i, min(i + 80, len(insns))):
            mm = re.match(r'w3, #(0x[0-9a-f]+|\d+)$', insns[k].op_str)
            if insns[k].mnemonic == 'mov' and mm:
                LEN = int(mm.group(1), 0)
                break
        decryptors[fstart] = (K, LEN)

print(f'// decryptors: {len(decryptors)}')

# ---- 2. find call sites: adr x0, #CONST ; ... ; bl FUNC ----
results = []
for i, ins in enumerate(insns):
    if ins.mnemonic != 'bl':
        continue
    tgt = None
    for op in ins.operands:
        if op.type == ARM64_OP_IMM:
            tgt = op.imm
    if tgt not in decryptors:
        continue
    # look back up to 8 insns for adr x0, #const
    const = None
    for k in range(i - 1, max(i - 9, -1), -1):
        p = insns[k]
        if p.mnemonic == 'adr' and p.op_str.startswith('x0,'):
            m = re.match(r'x0, #(0x[0-9a-f]+)$', p.op_str)
            if m:
                const = int(m.group(1), 16)
            break
        if p.mnemonic in ('bl', 'ret'):
            break
    K, LEN = decryptors[tgt]
    if const is None:
        results.append((ins.address, tgt, None, K, LEN, '<no const>'))
        continue
    if LEN is None:
        continue
    enc = rd(const, LEN)
    dec = bytes((enc[j] ^ ((j * 31 + K) & 0xff)) for j in range(min(LEN, len(enc))))
    s = dec.decode('utf-8', 'replace')
    results.append((ins.address, tgt, const, K, LEN, s))

for callsite, func, const, K, LEN, s in results:
    print(f'{callsite:08x}  const={const and hex(const)}  K={K:#04x}  len={LEN:<3}  {s!r}')
