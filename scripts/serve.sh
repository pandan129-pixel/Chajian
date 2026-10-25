#!/bin/sh
# 本地起一个插件源，手机在同一 Wi-Fi 下即可添加。
# 用法: sh scripts/serve.sh [端口]
set -e
cd "$(dirname "$0")/.."
PORT=${1:-8080}
IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
echo "本机: http://127.0.0.1:$PORT/"
if [ -n "$IP" ]; then
    echo "手机: http://$IP:$PORT/   (Sileo 添加这个地址)"
fi
exec python3 -m http.server "$PORT" --directory docs
