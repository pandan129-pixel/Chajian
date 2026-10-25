#!/usr/bin/env python3
"""Build a Debian package without dpkg (ar + tar.gz)."""
import os, sys, tarfile, io, hashlib, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
import re as _re
_ctl = open(os.path.join(ROOT, 'packaging', 'control')).read()
_ver = _re.search(r'^Version:\s*(\S+)', _ctl, _re.M).group(1)
_arch = _re.search(r'^Architecture:\s*(\S+)', _ctl, _re.M).group(1)
OUT = os.environ.get('OUT', os.path.join(ROOT, 'dist', f'com.pandan.xianyuduo_{_ver}_{_arch}.deb'))

def tar_bytes(src_dir, arc_prefix=''):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz', format=tarfile.GNU_FORMAT) as tf:
        for name in sorted(os.listdir(src_dir)):
            p = os.path.join(src_dir, name)
            tf.add(p, arcname=os.path.join(arc_prefix, name) if arc_prefix else name,
                   recursive=True, filter=lambda ti: (setattr(ti, 'uid', 0), setattr(ti, 'gid', 0),
                                                      setattr(ti, 'uname', 'root'), setattr(ti, 'gname', 'wheel'),
                                                      ti)[-1])
    return buf.getvalue()

def build():
    layout = os.path.join(ROOT, 'build', 'layout')
    ctrl = os.path.join(ROOT, 'build', 'control')
    import shutil
    for d in (layout, ctrl):
        shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(layout, 'usr', 'lib', 'TweakInject'), exist_ok=True)
    os.makedirs(ctrl, exist_ok=True)

    import shutil
    shutil.copy(os.path.join(ROOT, 'build', 'XianyuDuo.dylib'), os.path.join(layout, 'usr/lib/TweakInject/XianyuDuo.dylib'))
    shutil.copy(os.path.join(ROOT, 'packaging/XianyuDuo.plist'), os.path.join(layout, 'usr/lib/TweakInject/XianyuDuo.plist'))
    shutil.copy(os.path.join(ROOT, 'packaging/control'), os.path.join(ctrl, 'control'))

    data = tar_bytes(layout)
    control = tar_bytes(ctrl)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'wb') as f:
        f.write(b'!<arch>\n')
        for name, payload in ((b'debian-binary', b'2.0\n'), (b'control.tar.gz', control), (b'data.tar.gz', data)):
            f.write(name.ljust(16))
            f.write(b'0'.ljust(12)); f.write(b'0'.ljust(6)); f.write(b'0'.ljust(6))
            f.write(b'100644'.ljust(8)); f.write(str(len(payload)).encode().ljust(10))
            f.write(b'`\n'); f.write(payload)
            if len(payload) % 2: f.write(b'\n')
    digest = hashlib.sha256(open(OUT,'rb').read()).hexdigest()
    with open(os.path.join(os.path.dirname(OUT), 'SHA256SUMS'), 'w') as fh:
        fh.write(f'{digest}  {os.path.basename(OUT)}\n')
    print(OUT, os.path.getsize(OUT), digest)

if __name__ == '__main__':
    build()
