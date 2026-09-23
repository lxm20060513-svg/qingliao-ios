#!/usr/bin/env bash
# bump_version_check.sh：bump 后本地自查 project.yml 8 处版本字面量是否全对齐（CI 同款口径）
# 用法：./bump_version_check.sh [tag]
#   tag 省略时只查 8 处一致；给 tag（如 v3.9.61）时额外核对 tag 与 project.yml 短版本号相同。
set -euo pipefail
# 放仓库根目录用；若以后挪到 scripts/ 下，把下一行改成 cd "$(dirname "$0")/.." 的上一级
cd "$(dirname "$0")"
[ -f project.yml ] || cd "$(dirname "$0")/.."
shorts=$(grep -E 'CFBundleShortVersionString:|MARKETING_VERSION:' project.yml | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' | sort -u)
builds=$(grep -E '^ *CFBundleVersion:|CURRENT_PROJECT_VERSION:' project.yml | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' | sort -u)
n_shorts=$(printf '%s\n' "$shorts" | wc -l | tr -d '[:space:]')
n_builds=$(printf '%s\n' "$builds" | wc -l | tr -d '[:space:]')
fail=0
if [ "$n_shorts" != "1" ]; then echo "❌ 短版本号不一致（应有 4 处相同）：$(printf '%s ' $shorts)"; fail=1; fi
if [ "$n_builds" != "1" ]; then echo "❌ 构建号不一致（应有 4 处相同）：$(printf '%s ' $builds)"; fail=1; fi
ver=$shorts
if [ $# -ge 1 ]; then
    tag=${1#v}
    if [ "$tag" != "$ver" ]; then echo "❌ tag=$1 与 project.yml 版本 $ver 不符"; fail=1; fi
fi
if [ $fail -eq 0 ]; then echo "✅ 版本一致：$ver (build $builds) —— project.yml 4 组键 8 处全对齐"; fi
exit $fail
