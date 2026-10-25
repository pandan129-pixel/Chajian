#!/usr/bin/env python3
"""把本机构建好的 .deb 汇总成一个 Sileo / Cydia 可用的平铺插件源。

用法:
    python3 scripts/repo.py                 # 只收每个包每个架构的最新版
    python3 scripts/repo.py --keep-all      # 保留全部历史版本
    python3 scripts/repo.py --out /tmp/repo # 输出到别的目录

产物默认写到 ./docs/:
    docs/Packages, Packages.gz/.bz2/.xz
    docs/Release
    docs/debs/*.deb
    docs/CydiaIcon.png
    docs/index.html
"""

import argparse
import bz2
import glob
import gzip
import hashlib
import html
import io
import lzma
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import zlib
from datetime import datetime, timezone
from email.utils import format_datetime
from functools import cmp_to_key

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

SKIP_FIELDS = {"Filename", "Size", "MD5sum", "SHA1", "SHA256", "SHA512"}
FIELD_ORDER = [
    "Package", "Name", "Version", "Architecture", "Section", "Priority",
    "Maintainer", "Author", "Depends", "Pre-Depends", "Conflicts", "Replaces",
    "Provides", "Installed-Size", "Description", "Tag", "Homepage",
    "Depiction", "SileoDepiction", "Icon",
]


# ---------------------------------------------------------------- config

def load_conf(path):
    """key = value，缩进行会接到上一个 key 后面（用于多行 source_globs）。"""
    conf, key = {}, None
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if line[0] in " \t" and key:
                conf[key] = (conf[key] + " " + line.strip()).strip()
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            key = k.strip()
            conf[key] = v.strip()
    return conf


# ---------------------------------------------------------------- deb parsing

def read_ar(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("不是 ar/deb 文件")
    off = 8
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        off += 60
        name = hdr[:16].decode("utf-8", "replace").strip().rstrip("/")
        try:
            size = int(hdr[48:58].decode("ascii").strip())
        except ValueError:
            break
        body = data[off:off + size]
        off += size + (size & 1)
        yield name, body


def decompress(name, body):
    if name.endswith(".gz"):
        return gzip.decompress(body)
    if name.endswith(".xz"):
        return lzma.decompress(body)
    if name.endswith(".bz2"):
        return bz2.decompress(body)
    if name.endswith(".zst"):
        exe = shutil.which("zstd")
        if not exe:
            raise RuntimeError("control.tar.zst 需要 zstd 命令（brew install zstd）")
        return subprocess.run([exe, "-dc"], input=body,
                              stdout=subprocess.PIPE, check=True).stdout
    return body


def read_control(path):
    for name, body in read_ar(path):
        if name.startswith("control.tar"):
            raw = decompress(name, body)
            with tarfile.open(fileobj=io.BytesIO(raw)) as tf:
                for m in tf.getmembers():
                    if m.isfile() and os.path.basename(m.name) == "control":
                        fh = tf.extractfile(m)
                        return fh.read().decode("utf-8", "replace")
            break
    raise ValueError("deb 里找不到 control.tar.*")


def parse_control(text):
    fields = []
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        if line[0] in " \t":
            if fields:
                fields[-1] = (fields[-1][0], fields[-1][1] + "\n" + line)
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            fields.append((k.strip(), v.strip()))
    return fields


# ---------------------------------------------------------------- version compare (dpkg 规则)

def _order(ch):
    if ch == "~":
        return -1
    if ch.isdigit():
        return 0
    if ch.isalpha():
        return ord(ch)
    return ord(ch) + 256


def _verrevcmp(a, b):
    i = j = 0
    la, lb = len(a), len(b)
    while i < la or j < lb:
        first_diff = 0
        while ((i < la and not a[i].isdigit()) or
               (j < lb and not b[j].isdigit())):
            ac = _order(a[i]) if i < la else 0
            bc = _order(b[j]) if j < lb else 0
            if ac != bc:
                return ac - bc
            i += 1
            j += 1
        while i < la and a[i] == "0":
            i += 1
        while j < lb and b[j] == "0":
            j += 1
        while i < la and j < lb and a[i].isdigit() and b[j].isdigit():
            if first_diff == 0:
                first_diff = ord(a[i]) - ord(b[j])
            i += 1
            j += 1
        if i < la and a[i].isdigit():
            return 1
        if j < lb and b[j].isdigit():
            return -1
        if first_diff:
            return first_diff
    return 0


def split_version(v):
    epoch = 0
    if ":" in v:
        e, v = v.split(":", 1)
        if e.isdigit():
            epoch = int(e)
    if "-" in v:
        upstream, revision = v.rsplit("-", 1)
    else:
        upstream, revision = v, ""
    return epoch, upstream, revision


def cmp_version(a, b):
    ea, ua, ra = split_version(a)
    eb, ub, rb = split_version(b)
    if ea != eb:
        return (ea > eb) - (ea < eb)
    c = _verrevcmp(ua, ub)
    if c:
        return c
    return _verrevcmp(ra, rb)


# ---------------------------------------------------------------- hashing / compression

def file_hashes(path):
    md5, sha1, sha256 = hashlib.md5(), hashlib.sha1(), hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1 << 20)
            if not chunk:
                break
            md5.update(chunk)
            sha1.update(chunk)
            sha256.update(chunk)
    return md5.hexdigest(), sha1.hexdigest(), sha256.hexdigest()


def gzip_bytes(data):
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(data)
    return buf.getvalue()


# ---------------------------------------------------------------- index rendering

def pkg_fields(entry):
    """按稳定顺序整理 control 字段，去掉 apt 自己会重算的字段。"""
    raw = entry["fields"]
    d = {}
    for k, v in raw:
        d[k] = v
    keys = [k for k in FIELD_ORDER if k in d]
    keys += [k for k, _ in raw if k not in FIELD_ORDER and k not in SKIP_FIELDS and k in d]
    seen, out = set(), []
    for k in keys:
        if k in seen:
            continue
        seen.add(k)
        out.append((k, d[k]))
    return out


def render_packages(entries, conf):
    base = conf.get("base_url", "").rstrip("/")
    chunks = []
    for e in entries:
        lines = []
        for k, v in pkg_fields(e):
            if k == "Icon" and not v:
                continue
            lines.append(f"{k}: {v}")
        if base and "Icon" not in dict(e["fields"]):
            icon = os.path.join(conf["_out"], "icons", e["Package"] + ".png")
            if os.path.exists(icon):
                lines.append(f"Icon: {base}/icons/{e['Package']}.png")
        lines.append(f"Filename: ./{e['filename']}")
        lines.append(f"Size: {e['size']}")
        lines.append(f"MD5sum: {e['md5']}")
        lines.append(f"SHA1: {e['sha1']}")
        lines.append(f"SHA256: {e['sha256']}")
        chunks.append("\n".join(lines) + "\n")
    return "\n".join(chunks)


def render_release(conf, files):
    """files: [(name, bytes)]，生成带校验和的 Release。"""
    stamp = datetime.now(timezone.utc).replace(microsecond=0)
    lines = [
        f"Origin: {conf.get('origin')}",
        f"Label: {conf.get('label')}",
        f"Suite: {conf.get('suite')}",
        f"Version: {conf.get('version')}",
        f"Codename: {conf.get('codename')}",
        f"Architectures: {conf.get('architectures')}",
        "Components: main",
        f"Description: {conf.get('description')}",
        f"Date: {format_datetime(stamp)}",
        "Icon: file://CydiaIcon.png",
    ]
    for alg, fn in (("MD5Sum", hashlib.md5), ("SHA1", hashlib.sha1),
                    ("SHA256", hashlib.sha256)):
        lines.append(f"{alg}:")
        for name, data in files:
            lines.append(f" {fn(data).hexdigest()} {len(data)} {name}")
    return "\n".join(lines) + "\n"


def ensure_repo_icon(path):
    if os.path.exists(path):
        return
    w = h = 256
    rows = []
    for y in range(h):
        row = bytearray(b"\x00")
        for x in range(w):
            t = (x + y) / (w + h - 2)
            row += bytes((int(24 + 70 * t), int(110 + 100 * t), int(190 + 50 * t), 255))
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag, data):
        body = tag + data
        return (struct.pack(">I", len(data)) + body +
                struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n" +
           chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) +
           chunk(b"IDAT", zlib.compress(raw, 9)) +
           chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(png)


def render_index(entries, conf):
    base = conf.get("base_url", "").rstrip("/")
    title = conf.get("label", "Repo")
    cards = []
    for e in entries:
        d = dict(e["fields"])
        name = d.get("Name") or e["Package"]
        desc = (d.get("Description", "").splitlines() or [""])[0]
        size = e["size"] / 1024.0
        icon = ""
        if os.path.exists(os.path.join(conf["_out"], "icons", e["Package"] + ".png")):
            icon = f'<img src="icons/{html.escape(e["Package"])}.png" alt="">'
        cards.append(f"""    <article>
      {icon}
      <div class="meta">
        <h2>{html.escape(name)}</h2>
        <p class="sub">{html.escape(e["Package"])} · {html.escape(e["version"])} · {html.escape(e["arch"])} · {size:.0f} KB</p>
        <p>{html.escape(desc)}</p>
        <a href="{html.escape(e['filename'])}">下载 .deb</a>
      </div>
    </article>""")
    source = base + "/" if base else "（发布后把 repo.conf 里的 base_url 填上）"
    return f"""<!doctype html>
<html lang="zh-CN">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font: 15px/1.55 -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
         max-width: 820px; margin: 0 auto; padding: 24px 16px 64px; }}
  h1 {{ font-size: 26px; margin: 8px 0 4px; }}
  .source {{ background: #8881; border-radius: 10px; padding: 12px 14px; margin: 18px 0 28px;
             font-family: ui-monospace, SFMono-Regular, Menlo, monospace; word-break: break-all; }}
  article {{ display: flex; gap: 12px; padding: 14px 0; border-top: 1px solid #8883; }}
  article img {{ width: 56px; height: 56px; border-radius: 12px; }}
  h2 {{ font-size: 16px; margin: 0 0 2px; }}
  .sub {{ margin: 0 0 6px; opacity: .65; font-size: 12px; font-family: ui-monospace, Menlo, monospace; }}
  p {{ margin: 0 0 6px; }}
  a {{ color: #2b7de9; }}
</style>
<h1>{html.escape(title)}</h1>
<p>在 Sileo / Cydia 中添加下面的源地址：</p>
<div class="source">{html.escape(source)}</div>
{chr(10).join(cards)}
</html>
"""


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--conf", default=os.path.join(ROOT, "repo.conf"))
    ap.add_argument("--out", default=os.path.join(ROOT, "docs"))
    ap.add_argument("--keep-all", action="store_true", help="保留全部历史版本")
    ap.add_argument("--no-prune", action="store_true", help="不删除 docs/debs 里多余的 deb")
    ap.add_argument("--source", action="append", default=None,
                    help="替代 repo.conf 的扫描路径（可多次），例如 --source docs/debs")
    args = ap.parse_args()

    conf = load_conf(args.conf)
    for key in ("origin", "label", "suite", "version", "codename",
                "architectures", "description"):
        conf.setdefault(key, "")
    out = os.path.abspath(args.out)
    conf["_out"] = out

    patterns = args.source or conf.get("source_globs", "").split()
    if not patterns:
        raise SystemExit("repo.conf 里没有 source_globs")

    deb_paths = []
    for pat in patterns:
        p = pat if os.path.isabs(pat) else os.path.join(ROOT, pat)
        matches = glob.glob(p, recursive=True)
        if not matches and os.path.isdir(p):
            matches = glob.glob(os.path.join(p, "*.deb"))
        for f in matches:
            if os.path.isdir(f):
                deb_paths += glob.glob(os.path.join(f, "*.deb"))
            elif f.lower().endswith(".deb"):
                deb_paths.append(f)
    deb_paths = sorted({os.path.abspath(f) for f in deb_paths})
    if not deb_paths:
        raise SystemExit("没有扫描到任何 .deb，请检查 repo.conf 的 source_globs")

    print(f"[scan] {len(deb_paths)} 个 deb")

    entries = []
    for path in deb_paths:
        try:
            fields = parse_control(read_control(path))
        except Exception as exc:
            print(f"[skip] {path}: {exc}")
            continue
        d = dict(fields)
        pkg, ver, arch = d.get("Package"), d.get("Version"), d.get("Architecture")
        if not pkg or not ver or not arch or "@" in arch:
            m = re.match(r"^(.+?)_([^_]+)_([^_]+)\.deb$", os.path.basename(path))
            if m:
                pkg = pkg if pkg and "@" not in pkg else m.group(1)
                ver = ver or m.group(2)
                arch = arch if arch and "@" not in arch else m.group(3)
        if not pkg or not ver or not arch:
            print(f"[skip] {path}: control 缺 Package/Version/Architecture")
            continue
        if ver != d.get("Version") or arch != d.get("Architecture"):
            print(f"[warn] {os.path.basename(path)}: 用文件名推断出 {ver}/{arch}")
        entries.append({
            "fields": fields, "Package": pkg, "version": ver,
            "arch": arch, "path": path,
        })

    excluded = set(conf.get("exclude_packages", "").split())
    if excluded:
        before = len(entries)
        entries = [e for e in entries if e["Package"] not in excluded]
        print(f"[filter] 排除 {before - len(entries)} 个包: {' '.join(sorted(excluded))}")

    archs = conf["architectures"].split()
    for e in entries:
        if archs and e["arch"] not in archs:
            print(f"[warn] {e['Package']} {e['version']}: 架构 {e['arch']} "
                  f"不在 Release 的 Architectures 里（{conf['architectures']}）")

    groups = {}
    for e in entries:
        groups.setdefault((e["Package"], e["arch"]), []).append(e)

    selected = []
    for key, items in groups.items():
        items.sort(key=cmp_to_key(lambda a, b: cmp_version(a["version"], b["version"])),
                   reverse=True)
        if args.keep_all:
            selected += items
        else:
            selected.append(items[0])
            if len(items) > 1:
                print(f"[pick] {key[0]} ({key[1]}): {items[0]['version']} "
                      f"(跳过 {len(items) - 1} 个旧版)")

    if args.keep_all:
        ordered = []
        for key in sorted(groups):
            items = [e for e in selected if (e["Package"], e["arch"]) == key]
            items.sort(key=cmp_to_key(lambda a, b: cmp_version(a["version"], b["version"])),
                       reverse=True)
            ordered += items
        selected = ordered
    else:
        selected.sort(key=lambda e: (e["Package"], e["arch"]))

    os.makedirs(out, exist_ok=True)
    debdir = os.path.join(out, "debs")
    os.makedirs(debdir, exist_ok=True)

    used, copied, reused = set(), 0, 0
    for e in selected:
        e["md5"], e["sha1"], e["sha256"] = file_hashes(e["path"])
        e["size"] = os.path.getsize(e["path"])
        name = os.path.basename(e["path"])
        dest = os.path.join(debdir, name)
        if os.path.exists(dest):
            if (os.path.getsize(dest) == e["size"] and
                    file_hashes(dest)[2] == e["sha256"]):
                reused += 1
            else:
                stem, ext = os.path.splitext(name)
                name = f"{stem}.{e['sha256'][:8]}{ext}"
                dest = os.path.join(debdir, name)
                shutil.copy2(e["path"], dest)
                copied += 1
        else:
            shutil.copy2(e["path"], dest)
            copied += 1
        e["filename"] = "debs/" + name
        used.add(name)

    if not args.no_prune:
        for name in sorted(os.listdir(debdir)):
            if name.endswith(".deb") and name not in used:
                os.remove(os.path.join(debdir, name))
                print(f"[prune] {name}")

    packages = render_packages(selected, conf).encode("utf-8")
    variants = {
        "Packages": packages,
        "Packages.gz": gzip_bytes(packages),
        "Packages.bz2": bz2.compress(packages, 9),
        "Packages.xz": lzma.compress(packages, preset=9),
    }
    for name, data in variants.items():
        with open(os.path.join(out, name), "wb") as fh:
            fh.write(data)
    release = render_release(conf, list(variants.items())).encode("utf-8")
    with open(os.path.join(out, "Release"), "wb") as fh:
        fh.write(release)

    ensure_repo_icon(os.path.join(out, "CydiaIcon.png"))
    with open(os.path.join(out, ".nojekyll"), "w") as fh:
        fh.write("")
    with open(os.path.join(out, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(render_index(selected, conf))

    total = sum(e["size"] for e in selected)
    print(f"\n[repo] {len(selected)} 个包 / {len(used)} 个 deb / "
          f"{total / 1048576:.1f} MB")
    print(f"[repo] 复制 {copied}，复用 {reused}，输出目录 {out}")
    print(f"[repo] 索引字段示例：")
    print("\n".join(render_packages(selected, conf).splitlines()[:12]))
    print("\n[repo] 本地测试:  sh scripts/serve.sh 8080")
    print("[repo] 发布:      repo.conf 填 base_url → 提交 docs/ → GitHub Pages 选 main /docs")


if __name__ == "__main__":
    main()
