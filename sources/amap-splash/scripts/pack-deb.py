#!/usr/bin/env python3
"""Pack AmapSplash into a deb.

Usage:
  pack-deb.py [roothide|rootless] [arch]

roothide : dpkg root is the jbroot -> paths start at usr/...
rootless : paths start at var/jb/...
"""
import io
import os
import re
import struct
import sys
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")
DIST = os.path.join(ROOT, "dist")
DYLIB = os.path.join(BUILD, "AmapSplash.dylib")
PLIST = os.path.join(ROOT, "packaging", "AmapSplash.plist")
CONTROL = os.path.join(ROOT, "packaging", "control")

layout = sys.argv[1] if len(sys.argv) > 1 else "roothide"
arch = sys.argv[2] if len(sys.argv) > 2 else "iphoneos-arm64e"
panic = sys.argv[3] if len(sys.argv) > 3 else ""

with open(CONTROL, encoding="utf-8") as fh:
    control = fh.read().replace("@ARCH@", arch)
    ver = re.search(r"^Version:\s*(\S+)", control, re.M).group(1)
    pkg = re.search(r"^Package:\s*(\S+)", control, re.M).group(1)

prefix = "" if layout == "roothide" else "var/jb/"


def tar_bytes(files, dirs=()):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        for d in dirs:
            ti = tarfile.TarInfo((prefix + d) if d else ".")
            ti.type = tarfile.DIRTYPE
            ti.mode = 0o755
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = 0
            tf.addfile(ti)
        for name, payload, mode in files:
            ti = tarfile.TarInfo(name)
            ti.size = len(payload)
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = 0
            tf.addfile(ti, io.BytesIO(payload))
    return buf.getvalue()


def ar_archive(members):
    out = bytearray(b"!<arch>\n")
    for name, body in members:
        hdr = f"{name:<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(body):<10}`\n".encode()
        out += hdr + body + (b"\n" if len(body) % 2 else b"")
    return bytes(out)


files = [
    (prefix + "usr/lib/TweakInject/AmapSplash.dylib", open(DYLIB, "rb").read(), 0o755),
    (prefix + "usr/lib/TweakInject/AmapSplash.plist", open(PLIST, "rb").read(), 0o644),
]
if panic:
    files.append((prefix + "usr/lib/TweakInject/AmapSplash.plist.disabled", open(PLIST, "rb").read(), 0o644))

dirs = (("", "usr", "usr/lib", "usr/lib/TweakInject") if layout == "roothide"
        else ("", "var", "var/jb", "var/jb/usr", "var/jb/usr/lib", "var/jb/usr/lib/TweakInject"))
data = tar_bytes(files, dirs)
ctrl = tar_bytes([("./control", control.encode(), 0o644)])
deb = ar_archive([("debian-binary", b"2.0\n"),
                  ("control.tar.gz", ctrl),
                  ("data.tar.gz", data)])

os.makedirs(DIST, exist_ok=True)
out = os.path.join(DIST, f"{pkg}_{ver}_{arch}.deb")
with open(out, "wb") as fh:
    fh.write(deb)
print(out, len(deb), "bytes")
