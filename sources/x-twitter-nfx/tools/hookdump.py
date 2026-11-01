import lief, struct, sys
from capstone import *
from capstone.arm64 import *

p=sys.argv[1]
b=lief.parse(p); d=open(p,'rb').read()
secs={s.name:s for s in b.sections}
bind={}
for x in b.dyld_chained_fixups.bindings:
    try: bind[x.address]=x.symbol.name
    except Exception: pass

def va2off(va):
    for s in b.segments:
        if s.virtual_address<=va<s.virtual_address+s.virtual_size:
            o=s.file_offset+(va-s.virtual_address)
            return o if 0<=o<len(d) else None
def cstr(va):
    o=va2off(va)
    if o is None: return None
    e=d.find(b'\0',o)
    return d[o:e].decode('utf-8','replace')
def decptr(v):
    if not v: return 0
    if v>>63: return (v & 0xFFFFFFFF) | (((v>>36)&0xFF)<<56)
    return (v & 0xFFFFFFFFF) | (((v>>36)&0xFF)<<56)

# stub map
stubs={}
st=secs["__stubs"]; md=Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail=True
for i in range(0, st.size, 12):
    va=st.virtual_address+i; code=d[st.offset+i:st.offset+i+12]
    ins=list(md.disasm(code, va))
    if len(ins)<3: continue
    a,l,br=ins[0],ins[1],ins[2]
    if not (a.mnemonic=='adrp' and l.mnemonic=='ldr' and br.mnemonic=='br'): continue
    page=a.operands[1].imm
    off=l.operands[1].mem.disp
    slot=page+off
    stubs[va]=bind.get(slot, f'?{slot:x}')

inits=struct.unpack_from('<6i',d,secs['__init_offsets'].offset)
targets=[]
for off in inits:
    targets.append((off, f'init_{off:x}'))

md=Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail=True
pairs=[]; last_class=None
for off,name in targets:
    va=off
    # find function extent: until next init or 0x4000 bytes
    end=min([o for o,_ in targets if o>off]+[va+0x6000])
    code=d[va:end]
    regs={}
    for ins in md.disasm(code, va):
        m=ins.mnemonic
        if m=='adrp':
            regs[ins.operands[0].reg]=ins.operands[1].imm
        elif m=='add':
            a,bb,c=ins.operands
            if len(ins.operands)==2:
                pass
            else:
                if bb.type==ARM64_OP_REG and bb.reg in regs: regs[a.reg]=regs[bb.reg]+c.imm
                elif bb.type==ARM64_OP_IMM: regs[a.reg]=bb.imm+c.imm
        elif m=='ldr':
            a,mem=ins.operands
            base=mem.mem.base; disp=mem.mem.disp
            if base in regs:
                addr=regs[base]+disp
                o=va2off(addr)
                if o: regs[a.reg]=decptr(struct.unpack_from('<Q',d,o)[0])
        elif m=='mov' and len(ins.operands)==2 and ins.operands[1].type==ARM64_OP_REG:
            if ins.operands[1].reg in regs: regs[ins.operands[0].reg]=regs[ins.operands[1].reg]
        elif m=='bl':
            tgt=ins.operands[0].imm
            fn=stubs.get(tgt)
            if fn=='_objc_getClass':
                s=cstr(regs.get(ARM64_REG_X0,0))
                if s: last_class=s
            elif fn=='_MSHookMessageEx':
                selva=regs.get(ARM64_REG_X1,0)
                sel=cstr(selva)
                pairs.append((last_class, sel, name, hex(regs.get(ARM64_REG_X2,0))))
            regs={}
print(f'{len(pairs)} hook calls')
for c,s,g,imp in pairs:
    print(f'{c} :: {s} :: {imp}')
