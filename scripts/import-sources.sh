#!/bin/sh
# 把工作区里几个插件的源码快照导入 repo/sources/，并做脱敏：
#   - 删除 build/dist/.theos/第三方二进制与参考源码
#   - 内网 IP -> DEVICE_IP
#   - 设备安装脚本改成读 DEVICE_HOST / DEVICE_PASSWORD
#   - 不导入含设备密码的 S19 handoff
set -eu

WS=$(cd "$(dirname "$0")/../.." && pwd)
DST="$WS/repo/sources"

echo "[sources] $WS -> $DST"
rm -rf "$DST"
mkdir -p "$DST"

copy_dir() {
    mkdir -p "$DST/$2"
    cp -R "$WS/$1"/. "$DST/$2"/
}

# ---- jbb -------------------------------------------------------------
mkdir -p "$DST/jbb/docs"
cp "$WS/jbb/README.md" "$DST/jbb/"
for p in src prefs packaging scripts tests tools; do
    copy_dir "jbb/$p" "jbb/$p"
done
for f in "$WS/jbb/docs"/*.md; do
    case "$(basename "$f")" in
        S19-*) continue ;;   # 含设备 SSH 密码，不导入
    esac
    cp "$f" "$DST/jbb/docs/"
done
for d in ref rd-research; do
    [ -d "$WS/jbb/docs/$d" ] && copy_dir "jbb/docs/$d" "jbb/docs/$d"
done

# ---- xianyu-duo ------------------------------------------------------
mkdir -p "$DST/xianyu-duo"
cp "$WS/plugins/xianyu-duo/README.md" "$WS/plugins/xianyu-duo/HANDOFF.md" "$DST/xianyu-duo/"
for p in src packaging scripts tools docs; do
    [ -d "$WS/plugins/xianyu-duo/$p" ] && copy_dir "plugins/xianyu-duo/$p" "xianyu-duo/$p"
done

# ---- crash-analyzer-pro ---------------------------------------------
mkdir -p "$DST/crash-analyzer-pro"
cp "$WS/plugins/crash-analyzer-pro/README.md" "$WS/plugins/crash-analyzer-pro/HANDOFF.md" \
   "$DST/crash-analyzer-pro/"
for p in src packaging scripts docs; do
    [ -d "$WS/plugins/crash-analyzer-pro/$p" ] && copy_dir "plugins/crash-analyzer-pro/$p" "crash-analyzer-pro/$p"
done

# ---- amap-splash -----------------------------------------------------
mkdir -p "$DST/amap-splash/docs"
cp "$WS/plugins/amap-splash/README.md" "$DST/amap-splash/"
for p in src packaging scripts tools; do
    [ -d "$WS/plugins/amap-splash/$p" ] && copy_dir "plugins/amap-splash/$p" "amap-splash/$p"
done
cp "$WS/plugins/amap-splash/docs/"*.md "$DST/amap-splash/docs/"

# ---- clean + sanitize ------------------------------------------------
find "$DST" -name '.DS_Store' -delete
find "$DST" -type d -name '.theos' -exec rm -rf {} + 2>/dev/null || true

python3 - "$DST" <<'PY'
import os
import re
import sys

root = sys.argv[1]
text_ext = {'.m', '.h', '.c', '.mm', '.swift', '.py', '.sh', '.md', '.plist',
            '.json', '.js', '.txt', '.yml', '.yaml', '.conf', '.in'}
text_names = {'Makefile', 'control', 'prerm'}

ip = re.compile(r'\b192\.168\.\d{1,3}\.\d{1,3}\b')
changed = []

for dirpath, _, files in os.walk(root):
    for name in files:
        path = os.path.join(dirpath, name)
        ext = os.path.splitext(name)[1].lower()
        if ext not in text_ext and name not in text_names:
            continue
        try:
            with open(path, encoding='utf-8') as fh:
                src = fh.read()
        except UnicodeDecodeError:
            continue
        new = ip.sub('DEVICE_IP', src)
        if new != src:
            with open(path, 'w', encoding='utf-8') as fh:
                fh.write(new)
            changed.append(os.path.relpath(path, root))

# xianyu frida runner: host 走环境变量，bundle 用脚本相对路径
p = os.path.join(root, 'xianyu-duo/tools/xyd-frida-run.py')
if os.path.exists(p):
    with open(p, encoding='utf-8') as fh:
        s = fh.read()
    s = s.replace('import sys, time, json, frida',
                  'import os, sys, time, json, frida')
    s = re.sub(r'HOST = "[^"]*"',
               'HOST = os.environ.get("DEVICE_HOST", "127.0.0.1:27042")', s, count=1)
    s = re.sub(r'open\("[^"]*xyd-frida\.bundle\.js"\)',
               'open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '
               '"xyd-frida.bundle.js"))', s, count=1)
    with open(p, 'w', encoding='utf-8') as fh:
        fh.write(s)

# amap frida UI: host 走环境变量
p = os.path.join(root, 'amap-splash/tools/frida_ui.py')
if os.path.exists(p):
    with open(p, encoding='utf-8') as fh:
        s = fh.read()
    s = s.replace('import argparse\nimport json\nimport sys',
                  'import argparse\nimport json\nimport os\nimport sys')
    s = re.sub(r'ap\.add_argument\("--host", default="[^"]*"\)',
               'ap.add_argument("--host", default=os.environ.get('
               '"DEVICE_HOST", "127.0.0.1:27042"))', s, count=1)
    with open(p, 'w', encoding='utf-8') as fh:
        fh.write(s)

# handoff 里“密码在脚本里”的说法已经过时，改成环境变量
p = os.path.join(root, 'xianyu-duo/HANDOFF.md')
if os.path.exists(p):
    with open(p, encoding='utf-8') as fh:
        s = fh.read()
    s = re.sub(r'sh scripts/install\.sh DEVICE_IP[^\n]*',
               'DEVICE_HOST=<ip> DEVICE_PASSWORD=<密码> sh scripts/install.sh', s)
    with open(p, 'w', encoding='utf-8') as fh:
        fh.write(s)

if changed:
    print('[sanitize] DEVICE_IP:', ', '.join(sorted(changed)))
PY

# 安装脚本不把密码写进仓库
cat > "$DST/xianyu-duo/scripts/install.sh" <<'SH'
#!/bin/sh
# 设备在线时安装/升级：
#   DEVICE_HOST=192.168.1.10 DEVICE_PASSWORD='你的密码' sh scripts/install.sh
# 密码会拼进 expect 脚本，建议只用数字/字母，避免引号和反斜杠。
set -e
cd "$(dirname "$0")/.."

HOST=${1:-${DEVICE_HOST:-}}
PASS=${DEVICE_PASSWORD:-}
[ -n "$HOST" ] || { echo "用法: DEVICE_HOST=<ip> DEVICE_PASSWORD=<pw> sh scripts/install.sh"; exit 1; }
[ -n "$PASS" ] || { echo "缺少 DEVICE_PASSWORD"; exit 1; }

DEB=$(ls -t dist/*.deb 2>/dev/null | head -1)
[ -n "$DEB" ] || { echo "先运行 python3 scripts/pack-deb.py"; exit 1; }
BASE=$(basename "$DEB")

expect -c "
set timeout 300
spawn scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  \"$DEB\" mobile@$HOST:/var/mobile/
expect {
  -re \"(?i)password\" { send \"$PASS\r\"; exp_continue }
  eof
}
"

expect -c "
set timeout 300
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  mobile@$HOST \"dpkg -i /var/mobile/$BASE || true; killall -9 SpringBoard\"
expect {
  -re \"(?i)password\" { send \"$PASS\r\"; exp_continue }
  eof
}
"

echo "installed $DEB -> $HOST"
SH

chmod +x "$DST"/*/scripts/*.sh 2>/dev/null || true
cp "$WS/repo/scripts/SOURCES-README.md" "$DST/README.md"

echo "[sources] done:"
du -sh "$DST"
find "$DST" -type f \( -name '*.deb' -o -name '*.dylib' -o -name '*.ipa' -o -name '*.bin' \) -print
