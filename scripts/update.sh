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
    if git pull --rebase --autostash --quiet; then
        return 0
    fi
    if resolve_generated_conflicts; then
        echo "[update] 已自动解决生成文件的 rebase 冲突"
        return 0
    fi
    echo "[update] pull --rebase 失败，先手动处理冲突" >&2
    exit 1
}

# docs/Release、Packages*、index.html、debs 都是 repo.py 的生成物。
# rebase 时如果和隔壁会话/Actions 的提交撞了，直接取正在应用的那一版，
# 后面 build 会重新生成，不需要人工合并。
resolve_generated_conflicts() {
    n=0
    while [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; do
        n=$((n + 1))
        [ "$n" -le 5 ] || return 1
        files=$(git diff --name-only --diff-filter=U)
        [ -n "$files" ] || return 1
        for f in $files; do
            case "$f" in
                docs/Release|docs/Packages*|docs/index.html|docs/debs/*|docs/.nojekyll)
                    git checkout --theirs -- "$f" 2>/dev/null || true
                    git add -A -- "$f"
                    ;;
                *)
                    echo "[update] 无法自动解决的冲突: $f" >&2
                    return 1
                    ;;
            esac
        done
        GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || true
    done
    return 0
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
