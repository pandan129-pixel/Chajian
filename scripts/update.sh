#!/bin/sh
# 一键更新插件源：
#   拉远端 -> 扫描所有 dist/debs-in -> 每个包每个架构取最新 -> 同步 sources/
#   -> 重建 Packages/Release -> commit -> push（被拒会自动 rebase 重试）
#
# 用法:
#   sh scripts/update.sh            # 只收最新版
#   sh scripts/update.sh --keep-all # 保留历史版本
set -eu
cd "$(dirname "$0")/.."

# 这台机器默认的 GitHub key 不是 ~/.ssh/id_ed25519，显式指定一下。
if [ -z "${GIT_SSH_COMMAND:-}" ] && [ -f "$HOME/.ssh/id_ed25519_iphone" ]; then
    GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_ed25519_iphone -o IdentitiesOnly=yes"
    export GIT_SSH_COMMAND
fi

pull_rebase() {
    if ! git pull --rebase --autostash --quiet; then
        echo "[update] pull --rebase 失败，先手动处理冲突" >&2
        exit 1
    fi
}

build() {
    python3 scripts/repo.py "$@"
    # 源码快照：只在工作区里存在对应项目时执行
    if [ -x scripts/import-sources.sh ] && [ -d ../plugins ]; then
        sh scripts/import-sources.sh >/dev/null
    fi
}

pull_rebase
build "$@"

git add -A
staged=0
git diff --cached --quiet || staged=1
ahead=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)

if [ "$staged" = 0 ] && [ "$ahead" = 0 ]; then
    echo "[update] 没有变化"
    exit 0
fi

msg="update repo: $(date '+%Y-%m-%d %H:%M')"
if [ "$staged" = 1 ]; then
    git commit -q -m "$msg"
fi

for i in 1 2 3; do
    if git push --quiet; then
        echo "[update] pushed: $msg"
        exit 0
    fi
    echo "[update] push 被拒，rebase 后重试 ($i/3)"
    pull_rebase
    build "$@"
    git add -A
    git diff --cached --quiet || git commit -q -m "$msg"
done

echo "[update] push 失败，请手动检查" >&2
exit 1
