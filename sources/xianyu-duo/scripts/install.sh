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
