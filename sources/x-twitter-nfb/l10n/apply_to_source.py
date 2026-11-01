#!/usr/bin/env python3
"""Apply the polished Chinese localization to the NeoFreeBird source layout.

Source tree master is `en.lproj` (318 keys in v7.3.0).  The packaging bundle
built from the 12.39 IPA has 341 keys; extra keys are ignored here, and any key
missing from the 341 set falls back to the existing source zh_CN.

Writes UTF-8 text .strings (the repo convention) to:
  layout/.../BHTwitter.bundle/zh-Hans.lproj/{Localizable,RenameWords}.strings
  layout/.../BHTwitter.bundle/zh_CN.lproj/{Localizable,RenameWords}.strings
"""
import os
import plistlib
import sys

ROOT = "~/Desktop/iphone/plugins/x-twitter-nfb"
SRC = os.path.join(ROOT, "src/NeoFreeBird-7.3.0")
BUNDLE = os.path.join(SRC, "layout/Library/Application Support/BHT/BHTwitter.bundle")
L10N = os.path.join(ROOT, "l10n")

RENAME = {
    "premium": "blue",
    "Premium": "Blue",
    "X": "Twitter",
    "已发帖": "已发推",
    "已转帖": "已转推",
    "发帖": "发推",
    "帖子": "推文",
    "贴文": "推文",
    "正在发送帖子": "正在发送推文",
    "正在转帖": "正在转推",
    "转帖": "转推",
}


def parse_text_strings(path):
    import re
    t = open(path, encoding="utf-8", errors="replace").read()
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    t = re.sub(r"^\s*//.*$", "", t, flags=re.M)
    return dict(re.findall(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', t))


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write_strings(path, d, header):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("/*\n  %s\n  NeoFreeBird\n*/\n\n" % header)
        for k in sorted(d):
            f.write('"%s" = "%s";\n' % (esc(k), esc(d[k])))


def main():
    en = parse_text_strings(os.path.join(BUNDLE, "en.lproj/Localizable.strings"))
    old_zh = parse_text_strings(os.path.join(BUNDLE, "zh_CN.lproj/Localizable.strings"))
    pack_zh = plistlib.load(open(os.path.join(L10N, "zh-Hans.lproj/Localizable.strings"), "rb"))

    zh = {}
    for k, v in en.items():
        if k in pack_zh and pack_zh[k].strip():
            zh[k] = pack_zh[k]
        elif k in old_zh and old_zh[k].strip():
            zh[k] = old_zh[k]
        else:
            zh[k] = v
            print("WARN untranslated:", k)

    for lproj in ("zh-Hans", "zh_CN"):
        base = os.path.join(BUNDLE, lproj + ".lproj")
        write_strings(os.path.join(base, "Localizable.strings"), zh, "Language: " + lproj)
        write_strings(os.path.join(base, "RenameWords.strings"), RENAME, "Language: " + lproj)
    print("wrote", len(zh), "keys to source layout zh-Hans + zh_CN")
    print("verify:", "python3 check_localization.py zh-Hans zh_CN")


if __name__ == "__main__":
    main()
