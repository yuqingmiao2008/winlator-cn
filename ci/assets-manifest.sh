#!/usr/bin/env bash
# ============================================================================
# assets-manifest.sh - 二进制资源哈希清单 (依赖可溯源 / 防止未审计的二进制混入)
#
# 清单 ci/assets.sha256 记录仓库内全部"二进制资源"的 SHA-256:
#   android/app/src/main/assets/   上游 App 自带的 rootfs / box64 / 图形驱动 / 组件包等
#   android/app/src/main/jniLibs/  (若存在)
#   chinese/fonts/                 Noto Sans CJK SC 字体
# CI 一开始就校验: 清单与实际文件必须完全一致 (无新增 / 缺失 / 内容变化)。
# 因此任何二进制变更都必须同时更新清单, 一定会出现在 diff / PR 里被人看到;
# 来源 (上游提交 + 哈希) 记录在 UPSTREAM.md。
#
# 用法:
#   ci/assets-manifest.sh gen      重新生成清单 (仅在"有意"变更二进制时运行, 并在提交说明里写明来源)
#   ci/assets-manifest.sh verify   校验 (CI 使用)
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
MANIFEST="ci/assets.sha256"
DIRS=(android/app/src/main/assets android/app/src/main/jniLibs chinese/fonts)

list_files() {
    { find "${DIRS[@]}" -type f 2>/dev/null || true; } | LC_ALL=C sort
}

case "${1:-}" in
    gen)
        list_files | xargs -d '\n' sha256sum > "$MANIFEST"
        echo "已写入 $MANIFEST ($(wc -l < "$MANIFEST") 个文件)"
        ;;
    verify)
        [ -s "$MANIFEST" ] || { echo "!!! 缺少 $MANIFEST (运行 ci/assets-manifest.sh gen 生成)"; exit 1; }
        DIFF="$(mktemp)"
        if ! diff <(list_files) <(sed 's/^[0-9a-f]\{64\}  //' "$MANIFEST" | LC_ALL=C sort) >"$DIFF"; then
            echo "!!! 二进制资源文件集合与 $MANIFEST 不一致 (< 实际有而清单没有, > 清单有而实际没有):"
            cat "$DIFF"; rm -f "$DIFF"; exit 1
        fi
        rm -f "$DIFF"
        if ! sha256sum --quiet -c "$MANIFEST"; then
            echo "!!! 有二进制资源的内容与 $MANIFEST 记录的哈希不符 (未经审计的二进制变更?)"; exit 1
        fi
        echo "二进制资源校验通过: $(wc -l < "$MANIFEST") 个文件与清单一致"
        ;;
    *)
        sed -n '2,19p' "$0"; exit 2
        ;;
esac
