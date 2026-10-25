#!/usr/bin/env python3
"""Pack AI 日志分析 Pro for roothide and rootless.

The dylib is loaded through an LC_LOAD_DYLIB command added to the bundle binary,
so this works independently of the jailbreak's tweak-injection loader.
"""
import hashlib
import io
import lzma
import os
import re
import shutil
import struct
import subprocess
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VENDOR = os.path.join(ROOT, "vendor", "com.mowang.crashanalyzer-1.1.6-roothide.deb")
BUILD = os.path.join(ROOT, "build")
DYLIB = os.path.join(BUILD, "CrashAnalyzerPro.dylib")
BUNDLE_REL = "Library/PreferenceBundles/CrashAnalyzerPrefs.bundle"
BUNDLE_BIN = "CrashAnalyzerPrefs"
EMBEDDED_DYLIB = "CrashAnalyzerPro.dylib"
LDID = os.environ.get("LDID", "/Users/dan/Desktop/iphone/.buildtools/ldid")

with open(os.path.join(ROOT, "packaging", "control"), encoding="utf-8") as fh:
    CONTROL_TEMPLATE = fh.read()
VER = re.search(r"^Version:\s*(\S+)", CONTROL_TEMPLATE, re.M).group(1)


def ar_members(path):
    data = open(path, "rb").read()
    assert data[:8] == b"!<arch>\n", "not an ar archive"
    off = 8
    while off < len(data):
        hdr = data[off:off + 60]
        off += 60
        name = hdr[:16].decode().strip()
        size = int(hdr[48:58].decode().strip())
        body = data[off:off + size]
        off += size + (size % 2)
        yield name, body


def extract_original(dest):
    for name, body in ar_members(VENDOR):
        if name.startswith("data.tar"):
            raw = lzma.decompress(body) if name.endswith(".xz") else body
            with tarfile.open(fileobj=io.BytesIO(raw)) as tf:
                tf.extractall(dest)
            return
    raise SystemExit("data.tar.* not found in vendor deb")


def inject_load_command(path, dylib_name):
    data = bytearray(open(path, "rb").read())
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from(
        "<IiiIIIII", data, 0
    )
    if magic != 0xFEEDFACF:
        raise SystemExit(f"not a thin 64-bit Mach-O: {magic:#x}")

    end = 0x20 + sizeofcmds
    first_section = None
    p = 0x20
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, p)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from("<I", data, p + 64)[0]
            sect = p + 72
            for _ in range(nsects):
                off = struct.unpack_from("<I", data, sect + 48)[0]
                if off > 0 and (first_section is None or off < first_section):
                    first_section = off
                sect += 80
        p += cmdsize

    name = dylib_name.encode("utf-8") + b"\0"
    cmdsize = (24 + len(name) + 7) & ~7
    if end + cmdsize > (first_section or len(data)):
        raise SystemExit(f"not enough header padding: end={end:#x} cmdsize={cmdsize:#x}")

    blob = struct.pack("<IIIIII", 0xC, cmdsize, 24, 0, 0x10000, 0x10000) + name
    blob += b"\0" * (cmdsize - len(blob))
    data[end:end + cmdsize] = blob
    struct.pack_into("<II", data, 0x10, ncmds + 1, sizeofcmds + cmdsize)
    open(path, "wb").write(data)
    print(f"  injected {dylib_name}: ncmds {ncmds}->{ncmds+1}, sizeofcmds {sizeofcmds:#x}->{sizeofcmds+cmdsize:#x}")


def sign(path):
    if not os.path.exists(LDID):
        raise SystemExit(f"ldid not found at {LDID}; set LDID=/path/to/ldid")
    # Sign outside the .bundle so ldid emits "Sealed Resources=none" like the
    # original binary instead of a stale bundle resource seal.
    tmpdir = os.path.join(BUILD, "sign_tmp")
    os.makedirs(tmpdir, exist_ok=True)
    tmp = os.path.join(tmpdir, os.path.basename(path))
    shutil.copy2(path, tmp)
    subprocess.check_call([LDID, "-S", tmp], stdout=subprocess.DEVNULL)
    shutil.copy2(tmp, path)
    os.unlink(tmp)


def tar_bytes(src_dir):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        for name in sorted(os.listdir(src_dir)):
            p = os.path.join(src_dir, name)
            tf.add(
                p,
                arcname=name,
                recursive=True,
                filter=lambda ti: (
                    setattr(ti, "uid", 0),
                    setattr(ti, "gid", 0),
                    setattr(ti, "uname", "root"),
                    setattr(ti, "gname", "wheel"),
                    ti,
                )[-1],
            )
    return buf.getvalue()


def build(layout, arch):
    prefix = "" if layout == "roothide" else "var/jb/"
    layout_dir = os.path.join(BUILD, "layout-" + layout)
    ctrl_dir = os.path.join(BUILD, "control-" + layout)
    out = os.path.join(ROOT, "dist", f"com.pandan.crashanalyzerpro_{VER}_{arch}.deb")

    for d in (layout_dir, ctrl_dir):
        shutil.rmtree(d, ignore_errors=True)
    os.makedirs(layout_dir, exist_ok=True)
    os.makedirs(ctrl_dir, exist_ok=True)

    tmp = os.path.join(BUILD, "extract-" + layout)
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp, exist_ok=True)
    extract_original(tmp)

    # Move the original root-path payload into var/jb for rootless.
    if prefix:
        for name in os.listdir(tmp):
            dst = os.path.join(layout_dir, prefix, name)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.move(os.path.join(tmp, name), dst)
    else:
        for name in os.listdir(tmp):
            shutil.move(os.path.join(tmp, name), os.path.join(layout_dir, name))
    shutil.rmtree(tmp, ignore_errors=True)

    bundle = os.path.join(layout_dir, prefix, BUNDLE_REL)
    binary = os.path.join(bundle, BUNDLE_BIN)
    if not os.path.exists(binary):
        raise SystemExit(f"bundle binary missing: {binary}")

    # Replace the original developer avatar with the AI-log icon.
    icons = os.path.join(ROOT, "packaging", "icons")
    for icon_name in ("icon.png", "icon@2x.png", "icon@3x.png"):
        src = os.path.join(icons, icon_name)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(bundle, icon_name))

    # Install the dylib where PreferenceLoader's own dylib lives. The bundle
    # loads it by absolute path; the TweakInject plist is a second, optional
    # injection path. Both use the same path, so dyld dedupes the image.
    tweak_dir = os.path.join(layout_dir, prefix, "usr", "lib", "TweakInject")
    os.makedirs(tweak_dir, exist_ok=True)
    tweak_dylib = os.path.join(tweak_dir, EMBEDDED_DYLIB)
    shutil.copy2(DYLIB, tweak_dylib)
    os.chmod(tweak_dylib, 0o755)
    sign(tweak_dylib)
    shutil.copy2(os.path.join(ROOT, "packaging", "CrashAnalyzerPro.plist"),
                 os.path.join(tweak_dir, "CrashAnalyzerPro.plist"))

    load_path = "/" + prefix + "usr/lib/TweakInject/" + EMBEDDED_DYLIB
    inject_load_command(binary, load_path)
    os.chmod(binary, 0o755)
    sign(binary)

    # The bundle's resource signature is stale after modifying the binary.
    shutil.rmtree(os.path.join(bundle, "_CodeSignature"), ignore_errors=True)

    control = CONTROL_TEMPLATE.replace("@ARCH@", arch)
    with open(os.path.join(ctrl_dir, "control"), "w", encoding="utf-8") as fh:
        fh.write(control)

    data = tar_bytes(layout_dir)
    control_tar = tar_bytes(ctrl_dir)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(b"!<arch>\n")
        for name, payload in (
            (b"debian-binary", b"2.0\n"),
            (b"control.tar.gz", control_tar),
            (b"data.tar.gz", data),
        ):
            f.write(name.ljust(16))
            f.write(b"0".ljust(12))
            f.write(b"0".ljust(6))
            f.write(b"0".ljust(6))
            f.write(b"100644".ljust(8))
            f.write(str(len(payload)).encode().ljust(10))
            f.write(b"`\n")
            f.write(payload)
            if len(payload) % 2:
                f.write(b"\n")

    digest = hashlib.sha256(open(out, "rb").read()).hexdigest()
    with open(os.path.join(ROOT, "dist", "SHA256SUMS"), "a") as fh:
        fh.write(f"{digest}  {os.path.basename(out)}\n")
    print(out, os.path.getsize(out), digest)
    return out


def main():
    if not os.path.exists(DYLIB):
        raise SystemExit("build/CrashAnalyzerPro.dylib missing; run scripts/build.sh")
    sums = os.path.join(ROOT, "dist", "SHA256SUMS")
    if os.path.exists(sums):
        os.unlink(sums)
    build("roothide", "iphoneos-arm64e")
    build("rootless", "iphoneos-arm64")


if __name__ == "__main__":
    main()
