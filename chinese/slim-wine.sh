#!/usr/bin/env bash
# ============================================================================
# slim-wine.sh - 精简 Wine 安装树 (只删运行时用不到的文件), 幂等
#
# 用法: slim-wine.sh <含 opt/wine 的根目录>
#
# 删除仅在"编译/链接 Windows 或 Wine 程序"时才用的文件 (Winlator 只运行已编译好的程序,
# 运行时从不读取它们):
#   - include/            Wine/Windows 开发头文件 (~70MB)
#   - **/*.a              静态导入库 (lib/wine/*-windows、*-unix 下共 ~768 个, ~130MB)
#   - share/man、share/applications
#
# 说明: 实测 Wine 的 PE DLL 已是 "stripped to external PDB" (无 DWARF), 再用 mingw strip
#       只能省几十字节/文件, 所以这里不做 PE strip; unix 侧 ELF 由 build-wine.sh 负责 strip。
# ============================================================================
set -euo pipefail

ROOT="$(realpath "${1:?缺少根目录参数 (其下应含 opt/wine)}")"
W="$ROOT/opt/wine"
[ -d "$W/lib/wine" ] || { echo "!!! $W/lib/wine 不存在"; exit 1; }

size_mb() { du -sm "$1" | cut -f1; }
BEFORE="$(size_mb "$W")"

rm -rf "$W/include" "$W/share/man" "$W/share/applications"
find "$W" -type f -name '*.a' -delete

AFTER="$(size_mb "$W")"
echo "==> Wine 精简完成: ${BEFORE}MB -> ${AFTER}MB (减少 $((BEFORE - AFTER))MB)"
