#!/usr/bin/env bash
# ============================================================================
# patch-rootfs.sh - 将新构建的 Wine 11 与中文支持注入 Winlator 的 rootfs/assets
#
# 在 ubuntu-24.04 (glibc 2.39) 上运行。locale 数据、X11 locale、字体均为
# 架构无关的数据文件, 可安全注入 aarch64 rootfs。
#
# 用法: patch-rootfs.sh <repo根目录> <wine-staging目录> <android-assets目录>
# 做事:
#  1. 解包 rootfs.tzst, 用新 Wine 11 替换 /opt/wine
#  2. 校验 wine 产物所有 NEEDED SONAME 均存在于 rootfs
#  3. 注入 Noto Sans CJK SC 字体 + fontconfig 中文别名
#  4. 生成 zh_CN.utf8 locale + X11 zh_CN locale
#  5. 给 container_pattern / rootfs_patches 的 Wine 前缀注入中文字体注册表
#  6. 重新打包 rootfs.tzst / container_pattern.tzst / rootfs_patches.tzst
# ============================================================================
set -euo pipefail

REPO="$(realpath "${1:?缺少 repo 根目录参数}")"
STAGING="$(realpath "${2:?缺少 wine staging 目录参数}")"
ASSETS="$(realpath "${3:?缺少 android assets 目录参数}")"

CHINESE="$REPO/chinese"
WORK="$(mktemp -d /tmp/rootfs-work.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> [1/8] 解包 rootfs.tzst"
tar -I zstd -xf "$ASSETS/rootfs.tzst" -C "$WORK"

echo "==> [2/8] 替换 /opt/wine 为 Wine 11"
rm -rf "$WORK/opt/wine"
cp -a "$STAGING/opt/wine" "$WORK/opt/wine"

# wineserver 静态化处理说明: wine 官方 make install 会产出 lib/libwine.so.1,
# 保留即可 (位于 /opt/wine 内部, 由 wine 二进制相对路径解析, 不依赖 rootfs)

echo "==> [3/8] 校验 NEEDED 库均存在于 rootfs"
python3 - "$WORK" <<'PYEOF'
import os, re, struct, sys

work = sys.argv[1]
rootfs_libs = set()
# 注意: opt/wine/lib/wine/x86_64-unix 是 Wine 内部 unix 库目录, 各 .so 之间的
# 互相依赖 (如 opencl.so -> ntdll.so, opengl32.so -> win32u.so) 由 wine
# preloader 在进程内按内部路径解析, 必须计入可用集合
for d in ("usr/lib", "usr/lib/x86_64-linux-gnu", "lib", "opt/wine/lib",
          "opt/wine/bin", "opt/wine/lib/wine/x86_64-unix",
          "opt/wine/lib/wine/i386-unix"):
    p = os.path.join(work, d)
    if not os.path.isdir(p):
        continue
    for f in os.listdir(p):
        rootfs_libs.add(f)

# 与上游 Winlator (Wine 10.10) rootfs 行为保持一致的白名单:
#  - libOpenCL.so.1: 上游 opencl.so 同样 NEEDED 它但 rootfs 并不携带,
#    OpenCL 在 Winlator 上本就不可用 (GPU 走 Turnip/VirGL), 保留 dll 仅供兜底
whitelist = {"libOpenCL.so.1"}

def needed(path):
    try:
        with open(path, "rb") as f:
            data = f.read()
        if data[:4] != b"\x7fELF":
            return []
        is64 = data[4] == 2
        (e_shoff,) = struct.unpack_from("<Q" if is64 else "<I", data, 0x28)
        (e_shentsize,) = struct.unpack_from("<H", data, 0x3A)
        (e_shnum,) = struct.unpack_from("<H", data, 0x3C)
        (e_shstrndx,) = struct.unpack_from("<H", data, 0x3E)
        strs = b""
        sections = []
        for i in range(e_shnum):
            off = e_shoff + i * e_shentsize
            (sh_name, sh_type) = struct.unpack_from("<II", data, off)
            (sh_offset, sh_size) = struct.unpack_from("<QQ" if is64 else "<II", data, off + (0x18 if is64 else 0x10))
            sections.append((sh_type, sh_offset, sh_size))
        # PT_DYNAMIC 更简单: 遍历 program headers
        (e_phoff,) = struct.unpack_from("<Q" if is64 else "<I", data, 0x20)
        (e_phentsize,) = struct.unpack_from("<H", data, 0x36)
        (e_phnum,) = struct.unpack_from("<H", data, 0x38)
        needed = []
        for i in range(e_phnum):
            off = e_phoff + i * e_phentsize
            (p_type,) = struct.unpack_from("<I", data, off)
            if p_type != 2:  # PT_DYNAMIC
                continue
            (p_offset, p_filesz) = struct.unpack_from("<QQ" if is64 else "<II", data, off + 8)
            entsz = 16 if is64 else 8
            strtab = None
            for j in range(p_filesz // entsz):
                doff = p_offset + j * entsz
                tag_size = "<q" if is64 else "<i"
                (d_tag,) = struct.unpack_from(tag_size, data, doff)
                d_val_off = doff + 8
                fmt = "<Q" if is64 else "<I"
                (d_val,) = struct.unpack_from(fmt, data, d_val_off)
                if d_tag == 0:
                    break
                if d_tag == 5:  # DT_STRTAB
                    strtab = d_val
            if strtab is None:
                continue
            # strtab 是 vaddr; 简化处理: 在文件里搜索 .dynstr 段
            for (sh_type, sh_offset, sh_size) in sections:
                if sh_type == 3:  # SHT_STRTAB (通常是 .dynstr)
                    strdata = data[sh_offset:sh_offset + sh_size]
                    for j in range(p_filesz // entsz):
                        doff = p_offset + j * entsz
                        (d_tag,) = struct.unpack_from(tag_size, data, doff)
                        if d_tag == 1:  # DT_NEEDED
                            (d_val,) = struct.unpack_from(fmt, data, doff + 8)
                            if d_val >= len(strdata):
                                continue
                            end = strdata.find(b"\x00", d_val)
                            if end < 0:
                                continue
                            name = strdata[d_val:end].decode(errors="replace")
                            if name:
                                needed.append(name)
                    break
        return needed
    except Exception:
        return []

missing = {}
for root, dirs, files in os.walk(os.path.join(work, "opt", "wine")):
    for f in files:
        p = os.path.join(root, f)
        for n in needed(p):
            if n in whitelist or n in rootfs_libs or n == "ld-linux-x86-64.so.2":
                continue
            missing.setdefault(n, set()).add(os.path.relpath(p, work))

if missing:
    print("!!! 以下 NEEDED 库在 rootfs 中不存在 (box64 无法解析):")
    for n, users in sorted(missing.items()):
        print(f"    {n}  <- {sorted(users)[:2]}")
    sys.exit(1)
print("    所有 NEEDED 均可解析 ✓")
PYEOF

echo "==> [4/8] 注入中文字体 (Noto Sans CJK SC)"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends locales libx11-common zstd xz-utils file >/dev/null 2>&1 || true
mkdir -p "$WORK/usr/share/fonts/opentype/noto"
cp "$CHINESE/fonts/NotoSansCJKsc-Regular.otf" "$WORK/usr/share/fonts/opentype/noto/"
cp "$CHINESE/fonts/NotoSansCJKsc-Bold.otf" "$WORK/usr/share/fonts/opentype/noto/"
cp "$CHINESE/69-noto-cjk.conf" "$WORK/etc/fonts/conf.d/69-noto-cjk.conf"

echo "==> [5/8] 生成 zh_CN.utf8 locale (glibc 2.39 数据文件, 架构无关)"
localedef --no-archive --prefix="$WORK/" -i zh_CN -f UTF-8 zh_CN.utf8 || {
    echo "!!! localedef 失败"; exit 1; }
ls "$WORK/usr/lib/locale/" | grep zh || true

echo "==> [6/8] X11 zh_CN locale"
if [ -d /usr/share/X11/locale/zh_CN.UTF-8 ]; then
    cp -a /usr/share/X11/locale/zh_CN.UTF-8 "$WORK/usr/share/X11/locale/"
    grep -q "^zh_CN.UTF-8" "$WORK/usr/share/X11/locale/locale.dir" || \
        printf "zh_CN.UTF-8\t\tzh_CN.UTF-8\nzh_CN\t\t\tzh_CN.UTF-8\n" >> "$WORK/usr/share/X11/locale/locale.dir"
else
    echo "    (警告) 宿主缺少 X11 zh_CN locale 数据, 跳过"
fi

echo "==> [7/8] Wine 前缀注册表中文补丁 + 字体注入"
# 7.1 container_pattern.tzst
CP="$WORK/cp"; mkdir -p "$CP"
tar -I zstd -xf "$ASSETS/container_pattern.tzst" -C "$CP"
if [ -f "$CP/.wine/system.reg" ]; then
    python3 "$CHINESE/reg-patch.py" "$CP/.wine/system.reg"
fi
mkdir -p "$CP/.wine/drive_c/windows/Fonts"
cp "$CHINESE/fonts/NotoSansCJKsc-Regular.otf" "$CHINESE/fonts/NotoSansCJKsc-Bold.otf" "$CP/.wine/drive_c/windows/Fonts/"
( cd "$CP" && tar -I zstd -cf "$ASSETS/container_pattern.tzst.new" . )
mv "$ASSETS/container_pattern.tzst.new" "$ASSETS/container_pattern.tzst"

# 7.2 rootfs_patches.tzst
RP="$WORK/rp"; mkdir -p "$RP"
tar -I zstd -xf "$ASSETS/rootfs_patches.tzst" -C "$RP"
if [ -f "$RP/home/xuser/.wine/system.reg" ]; then
    python3 "$CHINESE/reg-patch.py" "$RP/home/xuser/.wine/system.reg"
fi
mkdir -p "$RP/home/xuser/.wine/drive_c/windows/Fonts"
cp "$CHINESE/fonts/NotoSansCJKsc-Regular.otf" "$CHINESE/fonts/NotoSansCJKsc-Bold.otf" "$RP/home/xuser/.wine/drive_c/windows/Fonts/"
( cd "$RP" && tar -I zstd -cf "$ASSETS/rootfs_patches.tzst.new" . )
mv "$ASSETS/rootfs_patches.tzst.new" "$ASSETS/rootfs_patches.tzst"

echo "==> [8/8] 重新打包 rootfs.tzst"
( cd "$WORK" && tar --numeric-owner --owner=0 --group=0 --sort=name \
    -cf "$ASSETS/rootfs.tzst.new" --use-compress-program="zstd -q -19 -T0" . )
mv "$ASSETS/rootfs.tzst.new" "$ASSETS/rootfs.tzst"

echo "==> 完成! 产物:"
ls -lh "$ASSETS/rootfs.tzst" "$ASSETS/container_pattern.tzst" "$ASSETS/rootfs_patches.tzst"
echo "PATCH_ROOTFS_OK"
