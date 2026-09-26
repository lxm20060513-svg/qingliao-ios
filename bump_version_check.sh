#!/usr/bin/env bash
# bump_version_check.sh：bump 后本地自查 project.yml 版本字面量是否全对齐（CI 同款口径）
# 用法：./bump_version_check.sh [tag]
#   tag 省略时只查一致 + 数量；给 tag（如 v3.9.61）时额外核对 tag 与 project.yml 短版本号相同。
# v4.0.1：判据从「8 处」升级为「每个 target 4 组键各一处」（3 target = 12 处）——
#   只比唯一值看不出漏声明，见下面 n_targets 那段注释。
set -euo pipefail
# 放仓库根目录用；若以后挪到 scripts/ 下，把下一行改成 cd "$(dirname "$0")/.." 的上一级
cd "$(dirname "$0")"
[ -f project.yml ] || cd "$(dirname "$0")/.."
shorts=$(grep -E 'CFBundleShortVersionString:|MARKETING_VERSION:' project.yml | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' | sort -u)
builds=$(grep -E '^ *CFBundleVersion:|CURRENT_PROJECT_VERSION:' project.yml | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' | sort -u)
n_shorts=$(printf '%s\n' "$shorts" | wc -l | tr -d '[:space:]')
n_builds=$(printf '%s\n' "$builds" | wc -l | tr -d '[:space:]')
fail=0
if [ "$n_shorts" != "1" ]; then echo "❌ 短版本号不一致（每个 target 应相同）：$(printf '%s ' $shorts)"; fail=1; fi
if [ "$n_builds" != "1" ]; then echo "❌ 构建号不一致（每个 target 应相同）：$(printf '%s ' $builds)"; fail=1; fi
# 🚨 只比「唯一值」看不出**漏声明**：某 target 少写一组键时，唯一值仍然是 1（看着全对），
# 而 XcodeGen 会给它默认写 1.0/1 —— 装出来的包挂件/扩展自报版本错，正是上面注释警告的坑。
# 所以这里按「每个 target 各一组键」核数量（v4.0.1：3 个 target × 4 组键 = 12 处）。
n_targets=$(grep -cE '^ +type: (application|app-extension)' project.yml || true)
for key in MARKETING_VERSION CFBundleShortVersionString CFBundleVersion CURRENT_PROJECT_VERSION; do
    n=$(grep -cE "^ *$key:" project.yml || true)
    if [ "$n" != "$n_targets" ]; then
        echo "❌ $key 只在 $n 处声明（$n_targets 个 target 应各一处）—— 有 target 会落成默认 1.0/1"; fail=1
    fi
done
ver=$shorts
if [ $# -ge 1 ]; then
    tag=${1#v}
    if [ "$tag" != "$ver" ]; then echo "❌ tag=$1 与 project.yml 版本 $ver 不符"; fail=1; fi
fi
if [ $fail -eq 0 ]; then
    echo "✅ 版本一致：$ver (build $builds) —— project.yml $(( n_targets * 4 )) 处全对齐（$n_targets 个 target × 4 组键）"
fi
exit $fail
