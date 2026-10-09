#!/usr/bin/env bash
# ============================================================================
# build-wine.sh - 在 ubuntu-24.04 (与 Winlator rootfs 同源环境) 上构建
# Winlator 定制版 Wine 11 (新 WoW64 模式: unix 侧仅 x86_64, PE 侧 i386+x86_64)
#
# 重要说明:
#  - 运行环境必须是 ubuntu-24.04 (glibc 2.39 == rootfs glibc 版本)
#  - 产物为 x86_64 ELF, 在设备上由 box64 模拟执行, 并通过 box64 符号桥接
#    rootfs 内的 aarch64 原生库 (libX11/libpulse/gstreamer/freetype...)
#  - 因此: 所有 NEEDED 的 SONAME 必须存在于 rootfs; 不链接 rootfs 没有的库
#    (libudev / libusb / libgbm 等在 rootfs 中不存在, 必须禁用)
#
# 用法: ./build-wine.sh <wine源码目录> <输出目录(staging)>
#
# 可选环境变量:
#   USE_CCACHE=1   用 ccache 包装 gcc / mingw 交叉编译器 (由工作流持久化 CCACHE_DIR);
#                  缓存命中时增量重编可从约 1 小时降到几分钟。已实测: Wine 的 configure 接受
#                  CC / x86_64_CC / i386_CC 带 ccache 前缀, 重编命中率 100%
# ============================================================================
set -euo pipefail

SRC="$(realpath "${1:?缺少 wine 源码目录参数}")"
OUT="$(realpath "${2:?缺少输出目录参数}")"

echo "==> [1/5] 安装构建依赖"
sudo apt-get update -qq
# shellcheck disable=SC2024  # 日志写入 /tmp/apt.log 无需 root 权限
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bison flex gettext git python3 make gcc g++ \
    mingw-w64 ccache \
    libfreetype-dev libfontconfig-dev \
    libx11-dev libxext-dev libxfixes-dev libxi-dev libxrender-dev \
    libxrandr-dev libxcursor-dev libxcomposite-dev \
    libpulse-dev libasound2-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    libkrb5-dev libvulkan-dev ocl-icd-opencl-dev libdrm-dev \
    > /tmp/apt.log 2>&1 || { tail -30 /tmp/apt.log; exit 1; }

echo "==> [2/5] 生成 configure (若需要)"
cd "$SRC"
[ -x ./configure ] || ./tools/make_configure
[ -x ./configure ] || autoconf -f

echo "==> [3/5] configure (新 WoW64: i386+x86_64 PE)"
rm -rf build && mkdir -p build && cd build

if [ "${USE_CCACHE:-0}" = "1" ] && command -v ccache >/dev/null 2>&1; then
    export CC="ccache gcc" CXX="ccache g++"
    export x86_64_CC="ccache x86_64-w64-mingw32-gcc" i386_CC="ccache i686-w64-mingw32-gcc"
    export CCACHE_BASEDIR="$SRC" CCACHE_NOHASHDIR=1
    ccache -z >/dev/null 2>&1 || true
    echo "    ccache 已启用: $(ccache --version | head -1), 目录: ${CCACHE_DIR:-默认}"
fi

../configure \
    --prefix=/opt/wine \
    --enable-archs=i386,x86_64 \
    --with-x \
    --with-pulse \
    --with-gstreamer \
    --with-freetype \
    --with-fontconfig \
    --without-udev \
    --without-sane \
    --without-gphoto \
    --without-osmesa \
    --without-oss \
    --without-capi \
    --without-coreaudio \
    --without-netapi \
    --disable-win16

echo "==> [4/5] 编译 make -j$(nproc)"
make -j"$(nproc)"
if [ "${USE_CCACHE:-0}" = "1" ] && command -v ccache >/dev/null 2>&1; then
    echo "--- ccache 统计 ---"
    ccache -s 2>&1 | grep -E "Hits|Misses|Cache size" | head -6 || true
fi

echo "==> [5/5] 安装到 staging: $OUT"
rm -rf "$OUT"
make install DESTDIR="$OUT"

echo "==> [6/6] strip 调试符号 (未 strip 产物 ~1.8GB, strip 后大幅缩减)"
# make install 产物带完整调试符号: unix 侧为 ELF, PE 侧为 mingw 编译的
# PE32/PE32+ (i386+x86_64 双架构, 数量占大头)。两类分别用对应 binutils strip。
# --strip-unneeded 保留动态符号表, 不影响 box64 dynarec 与运行时加载。
FILEMAP="$(mktemp)"
find "$OUT/opt/wine" -type f -exec file {} + >"$FILEMAP" 2>/dev/null || true
grep -F 'ELF' "$FILEMAP" | cut -d: -f1 \
    | xargs -r -n 50 strip --strip-unneeded 2>/dev/null || true
grep -E 'PE32|MS Windows' "$FILEMAP" | cut -d: -f1 \
    | xargs -r -n 50 x86_64-w64-mingw32-strip --strip-unneeded 2>/dev/null || true
rm -f "$FILEMAP"
echo "--- strip 后体积 ---"
du -sh "$OUT/opt/wine"

echo "==> [7/7] 精简: 删除运行时用不到的开发文件 (include / *.a / man), 缓存与 rootfs 都更小"
bash "$(dirname "$(realpath "$0")")/../chinese/slim-wine.sh" "$OUT"

echo "==> 构建产物概览:"
ls "$OUT/opt/wine/bin/" | head -20
echo "--- lib/wine 架构目录 ---"
ls "$OUT/opt/wine/lib/wine/"
echo "--- 校验 bin/wine 为 x86_64 ELF ---"
file "$OUT/opt/wine/bin/wine"
echo "BUILD_WINE_OK"
