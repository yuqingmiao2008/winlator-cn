#!/usr/bin/env bash
# ============================================================================
# healthcheck.sh - Winlator CN 构建健康检查 (任一项失败即非零退出)
#
# 用法:
#   healthcheck.sh wine   <根目录> [期望版本, 如 11.15]   根目录下应含 opt/wine (staging 或 rootfs 解包目录)
#   healthcheck.sh smoke  <根目录>                         用宿主 (x86_64) 无头启动 wine, 验证补丁功能
#   healthcheck.sh rootfs <rootfs 目录> [期望版本]         patch-rootfs.sh 打包前: 瘦身 / locale / 字体 / Wine
#   healthcheck.sh apk    <apk> [applicationId]            APK 完整性 / 包名 / 签名 / 资产
#
# 设计原则: 只检查"一定应该成立"的事实以避免误报; 已知但需要人工决策的风险用
#           ::warning:: 提示而不让构建失败。所有检查项均已对真实 v1.0.0 产物验证过。
# ============================================================================
set -uo pipefail

FAILS=0
WARNS=0
ok()      { echo "  ✓ $*"; }
fail()    { echo "  ✗ $*"; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error::健康检查失败: $*"; FAILS=$((FAILS + 1)); }
warn()    { echo "  ! $*"; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::$*"; WARNS=$((WARNS + 1)); }
section() { echo "==> $*"; }

# 把 python 输出的 FAIL:/INFO:/WARN: 行转成 fail/ok/warn
relay() {
    local line
    while IFS= read -r line; do
        case "$line" in
            FAIL:*) fail "${line#FAIL:}" ;;
            WARN:*) warn "${line#WARN:}" ;;
            INFO:*) ok "${line#INFO:}" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 1) Wine 产物静态检查
# ---------------------------------------------------------------------------
# 关键 DLL (两种架构共有 / 仅 x86_64)。清单取自真实 v1.0.0 产物:
# i386 侧没有 wineboot/services/rpcss/conhost (新 WoW64 下由 64 位版本承担)
CRIT_COMMON="ntdll.dll kernel32.dll kernelbase.dll user32.dll gdi32.dll win32u.dll advapi32.dll ole32.dll oleaut32.dll msvcrt.dll ucrtbase.dll shell32.dll shlwapi.dll comctl32.dll comdlg32.dll d3d9.dll d3d11.dll dxgi.dll ddraw.dll dinput8.dll winmm.dll ws2_32.dll rpcrt4.dll bcrypt.dll crypt32.dll wininet.dll imm32.dll mmdevapi.dll winex11.drv explorer.exe winedevice.exe svchost.exe cmd.exe start.exe regedit.exe"
CRIT_X64_ONLY="wineboot.exe services.exe rpcss.exe conhost.exe"

pe_check() { # <目录> <机器码十六进制> <最少文件数> <标签>
python3 - "$1" "$2" "$3" "$4" <<'PY'
import os, struct, sys
d, mach, minn, label = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3]), sys.argv[4]
n = 0; bad = []
for f in sorted(os.listdir(d)):
    p = os.path.join(d, f)
    if not os.path.isfile(p):
        continue
    with open(p, "rb") as fh:
        h = fh.read(0x1000)
    if h[:2] != b"MZ":
        continue                                  # 非 PE 文件忽略
    e = struct.unpack_from("<I", h, 0x3C)[0]
    if e + 24 > len(h) or h[e:e + 4] != b"PE\0\0":
        bad.append(f"{f}: PE 头损坏"); continue
    n += 1
    machine, nsec, _, _, _, optsz, _ = struct.unpack_from("<HHIIIHH", h, e + 4)
    if machine != mach:
        bad.append(f"{f}: 架构不符 (0x{machine:x})")
    if b"Wine builtin DLL" not in h[:0x100] and b"Wine placeholder DLL" not in h[:0x100]:
        bad.append(f"{f}: 缺少 Wine builtin 标记")
    so = e + 24 + optsz
    end = 0
    for i in range(nsec):
        o = so + 40 * i
        if o + 40 > len(h):
            end = 0; break
        raw_size, raw_ptr = struct.unpack_from("<II", h, o + 16)
        end = max(end, raw_ptr + raw_size)
    if end and os.path.getsize(p) < end:
        bad.append(f"{f}: 文件被截断")
if n < minn:
    print(f"FAIL:{label}: PE 文件仅 {n} 个 (< {minn})")
for b in bad[:10]:
    print(f"FAIL:{label}: {b}")
if len(bad) > 10:
    print(f"FAIL:{label}: ... 另有 {len(bad) - 10} 个问题")
if n >= minn and not bad:
    print(f"INFO:{label}: {n} 个 PE 文件结构完整 (架构/builtin 标记/未截断)")
PY
}

marker_check() { # <文件> <标记> [wide]
python3 - "$1" "$2" "${3:-}" <<'PY'
import sys
path, tok, wide = sys.argv[1], sys.argv[2], sys.argv[3] == "wide"
try:
    data = open(path, "rb").read()
except OSError:
    print(f"FAIL:补丁标记检查: 无法读取 {path}"); sys.exit()
needle = tok.encode("utf-16-le") if wide else tok.encode()
if needle in data:
    print(f"INFO:补丁标记 {tok} ∈ {path.split('/opt/wine/')[-1]}")
else:
    print(f"FAIL:补丁标记 {tok} 不在 {path.split('/opt/wine/')[-1]} 中 (Winlator 自定义补丁可能丢失)")
PY
}

check_wine() { # <根目录> [期望版本]
    local EXPECT="${2:-${WINE_VERSION:-}}" W rel before d n
    W="$(realpath "$1")/opt/wine"
    section "Wine 产物检查 ($W)"
    [ -d "$W" ] || { fail "缺少 $W"; return; }

    before=$FAILS
    for rel in bin/wine bin/wineserver lib/wine/x86_64-unix/wine lib/wine/x86_64-unix/ntdll.so \
               lib/wine/x86_64-unix/win32u.so lib/wine/x86_64-unix/winex11.so \
               lib/wine/x86_64-unix/winepulse.so lib/wine/x86_64-unix/winealsa.so \
               lib/wine/x86_64-unix/winebus.so lib/wine/x86_64-windows/ntdll.dll \
               lib/wine/i386-windows/ntdll.dll share/wine/wine.inf; do
        [ -s "$W/$rel" ] || fail "缺少关键文件 opt/wine/$rel"
    done
    for rel in share/wine/nls share/wine/fonts; do
        [ -n "$(ls -A "$W/$rel" 2>/dev/null)" ] || fail "目录不存在或为空: opt/wine/$rel"
    done
    [ "$FAILS" -eq "$before" ] && ok "关键文件齐全"

    if [ "$(uname -m)" = "x86_64" ]; then
        local got
        got="$(cd /tmp && "$W/bin/wine" --version 2>&1 | head -1)"
        if [ -z "$EXPECT" ]; then
            ok "wine --version = $got (未指定期望版本)"
        elif [ "$got" = "wine-$EXPECT" ]; then
            ok "wine --version = $got"
        else
            fail "wine --version 为 '$got', 期望 'wine-$EXPECT'"
        fi
    else
        warn "宿主非 x86_64, 跳过 wine --version"
    fi

    pe_check "$W/lib/wine/x86_64-windows" 8664 500 "x86_64-windows" | relay
    pe_check "$W/lib/wine/i386-windows"   14c  500 "i386-windows"   | relay

    before=$FAILS
    for d in x86_64-windows i386-windows; do
        local list="$CRIT_COMMON"
        [ "$d" = "x86_64-windows" ] && list="$list $CRIT_X64_ONLY"
        for n in $list; do
            [ -f "$W/lib/wine/$d/$n" ] || fail "缺少关键 DLL: $d/$n"
        done
    done
    [ "$FAILS" -eq "$before" ] && ok "关键 DLL 在 x86_64 / i386 两个架构均存在"

    # Winlator 自定义补丁在编译产物中的"绊线": 补丁被重新生成时若丢了钩子, 这里会立刻发现
    marker_check "$W/lib/wine/x86_64-unix/ntdll.so"        WINEARGS | relay
    marker_check "$W/lib/wine/x86_64-unix/ntdll.so"        WINEENV | relay
    marker_check "$W/lib/wine/x86_64-unix/ntdll.so"        WINEVMEMMAXSIZE | relay
    marker_check "$W/lib/wine/x86_64-unix/ntdll.so"        WINEOVERRIDEAFFINITYMASK | relay
    marker_check "$W/lib/wine/x86_64-unix/wine"            WINPREEXEC | relay
    marker_check "$W/lib/wine/x86_64-unix/winebus.so"      winlator | relay
    marker_check "$W/lib/wine/x86_64-windows/ntdll.dll"    WINVERSION wide | relay
    marker_check "$W/lib/wine/x86_64-windows/sechost.dll"  WINE_DO_NOT_OPEN_SC_MANAGER | relay
    marker_check "$W/lib/wine/x86_64-windows/mfplat.dll"   WINE_DO_NOT_CREATE_DXGI_DEVICE_MANAGER | relay
}

# ---------------------------------------------------------------------------
# 2) 冒烟测试: 真的把 Wine 跑起来 (能抓到 "编译通过但一启动就断言失败" 这类问题)
# ---------------------------------------------------------------------------
smoke_run() { # <标签> <期望子串> <超时秒> <env 赋值...> -- <命令...>
    local label="$1" want="$2" tmo="$3"; shift 3
    local envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    # 输出写入文件而不是管道: wineserver 会作为守护进程继承并长期占用管道, 导致读取方永远等不到 EOF
    local log out; log="$(mktemp)"
    env "${envs[@]}" timeout -k 5 "$tmo" "$@" </dev/null >"$log" 2>&1
    env "${envs[@]}" timeout 30 "$SMOKE_WINESERVER" -k </dev/null >/dev/null 2>&1 || true
    out="$(tr -d '\r' <"$log")"; rm -f "$log"
    if printf '%s' "$out" | grep -q -- "$want"; then
        ok "$label"
    else
        fail "冒烟测试失败: $label (期望输出含 '$want'; 实际: $(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-240))"
        return 1
    fi
}

check_smoke() { # <根目录>
    local W
    W="$(realpath "$1")/opt/wine"
    section "Wine 冒烟测试 (无头启动)"
    if [ "$(uname -m)" != "x86_64" ]; then warn "宿主非 x86_64, 跳过冒烟测试"; return; fi
    local tmp; tmp="$(mktemp -d)"
    local base=(WINEPREFIX="$tmp/pfx" WINEDEBUG=-all TMPDIR="$tmp"
                "WINEDLLOVERRIDES=winex11.drv=d;winealsa.drv=d;winepulse.drv=d;winebus.sys=d;mscoree,mshtml=d")
    # 首次运行要创建前缀, 给足时间 (可用 SMOKE_TIMEOUT 统一覆盖, 单位秒)
    local t1="${SMOKE_TIMEOUT:-600}" t2="${SMOKE_TIMEOUT:-180}"
    SMOKE_WINESERVER="$W/bin/wineserver"
    smoke_run "wine 启动并创建前缀 (cmd /c echo)" SMOKE_BASE_OK "$t1" "${base[@]}" -- "$W/bin/wine" cmd /c "echo SMOKE_BASE_OK" \
        || { warn "基础启动失败, 跳过其余冒烟项"; rm -rf "$tmp"; return; }
    smoke_run "32 位 (WoW64) 程序可运行"          SMOKE_X86_OK  "$t2" "${base[@]}" -- "$W/bin/wine" 'C:\windows\syswow64\cmd.exe' /c "echo SMOKE_X86_OK"
    smoke_run "补丁钩子 WINEARGS"                  SMOKE_ARGS_OK "$t2" "${base[@]}" "WINEARGS=/c echo SMOKE_ARGS_OK" -- "$W/bin/wine" cmd
    smoke_run "补丁钩子 WINEENV"                   smoke_env_ok  "$t2" "${base[@]}" "WINEENV=WLCN_SMOKE=smoke_env_ok" -- "$W/bin/wine" cmd /c "echo %WLCN_SMOKE%"
    smoke_run "补丁钩子 WINVERSION=winxp"          "5\.1\."      "$t2" "${base[@]}" "WINVERSION=winxp" -- "$W/bin/wine" cmd /c ver
    rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# 3) rootfs 检查 (patch-rootfs.sh 打包前)
# ---------------------------------------------------------------------------
check_rootfs() { # <rootfs 目录> [期望版本]
    local R before n
    R="$(realpath "$1" 2>/dev/null || echo "$1")"
    section "rootfs 检查 ($R)"
    [ -d "$R" ] || { fail "rootfs 目录不存在: $R"; return; }

    before=$FAILS
    for n in cp rp; do
        [ ! -e "$R/$n" ] || fail "rootfs 中混入了工作目录 /$n (会被打进 rootfs.tzst 白白占空间)"
    done
    [ ! -d "$R/opt/wine/include" ] || fail "opt/wine/include 未清理 (仅开发期使用)"
    n="$(find "$R/opt/wine" -type f -name '*.a' 2>/dev/null | wc -l)"
    [ "$n" -eq 0 ] || fail "opt/wine 下仍有 $n 个 .a 静态库未清理"
    [ "$FAILS" -eq "$before" ] && ok "精简到位: 无 cp/rp 工作目录、无 include、无 .a 静态库"

    check_wine "$R" "${2:-${WINE_VERSION:-}}"

    section "locale / X11 / 字体 检查"
    before=$FAILS
    for n in en_US pt_BR ru_RU zh_CN; do
        local c; c="$(ls "$R/usr/lib/locale/$n.utf8" 2>/dev/null | wc -l)"
        [ "$c" -ge 12 ] || fail "locale $n.utf8 不完整 (仅 $c 个 LC_* 文件, 应为 12)"
    done
    [ -s "$R/usr/lib/locale/zh_CN.utf8/LC_CTYPE" ] || fail "zh_CN.utf8 的 LC_CTYPE 缺失或为空"
    [ "$FAILS" -eq "$before" ] && ok "glibc locale: en_US / pt_BR / ru_RU / zh_CN 数据齐全"

    before=$FAILS
    local xl="$R/usr/share/X11/locale"
    [ -s "$xl/zh_CN.UTF-8/XLC_LOCALE" ] || fail "缺少 X11 zh_CN.UTF-8/XLC_LOCALE"
    [ -s "$xl/zh_CN.UTF-8/Compose" ]    || fail "缺少 X11 zh_CN.UTF-8/Compose"
    grep -Eq '^zh_CN\.UTF-8/XLC_LOCALE:?[[:space:]]+zh_CN\.UTF-8[[:space:]]*$' "$xl/locale.dir" 2>/dev/null \
        || fail "X11 locale.dir 缺少 zh_CN.UTF-8 映射行"
    [ "$FAILS" -eq "$before" ] && ok "X11 zh_CN locale 数据与 locale.dir 映射正常"

    before=$FAILS
    local fd="$R/usr/share/fonts/opentype/noto" f
    for f in NotoSansCJKsc-Regular.otf NotoSansCJKsc-Bold.otf; do
        if [ "$(stat -c %s "$fd/$f" 2>/dev/null || echo 0)" -lt 10000000 ]; then
            fail "字体缺失或过小: $f"; continue
        fi
        if command -v fc-scan >/dev/null 2>&1; then
            fc-scan --format '%{family}\n' "$fd/$f" 2>/dev/null | grep -q "Noto Sans CJK SC" \
                || fail "字体 $f 的 family 不含 'Noto Sans CJK SC'"
            python3 - "$(fc-scan --format '%{charset}' "$fd/$f" 2>/dev/null)" "$f" <<'PY' | relay
import sys
spans = []
for tok in sys.argv[1].split():
    a, _, b = tok.partition("-")
    spans.append((int(a, 16), int(b or a, 16)))
miss = [hex(c) for c in (0x4E2D, 0x6587, 0x6C49, 0x5B57) if not any(lo <= c <= hi for lo, hi in spans)]
if miss:
    print(f"FAIL:字体 {sys.argv[2]} 缺少常用汉字字形 {miss}")
PY
        fi
    done
    python3 - "$R/etc/fonts/conf.d/69-noto-cjk.conf" <<'PY' | relay
import sys, xml.dom.minidom
try:
    xml.dom.minidom.parse(sys.argv[1])
except Exception as e:
    print(f"FAIL:fontconfig 配置 69-noto-cjk.conf 缺失或格式错误: {e}")
PY
    [ "$FAILS" -eq "$before" ] && ok "Noto Sans CJK SC 字体(常用汉字字形齐全)与 fontconfig 别名配置正常"
}

# ---------------------------------------------------------------------------
# 4) APK 检查
# ---------------------------------------------------------------------------
find_sdk_tool() { # <工具名>
    local t="$1" dir
    command -v "$t" 2>/dev/null && return
    for dir in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" /usr/local/lib/android/sdk; do
        [ -n "$dir" ] && [ -d "$dir/build-tools" ] || continue
        ls -d "$dir"/build-tools/*/"$t" 2>/dev/null | sort -V | tail -1
        return
    done
}

check_apk() { # <apk> [applicationId]
    local APK="$1" APPID="${2:-com.winlator.cn}" tmp
    section "APK 检查 ($APK)"
    [ -s "$APK" ] || { fail "APK 不存在或为空: $APK"; return; }

    if unzip -tq "$APK" >/dev/null 2>&1; then ok "zip 结构完整 ($(( $(stat -c %s "$APK") / 1048576 ))MB)"; else fail "APK zip 校验失败"; return; fi

    local entries; entries="$(unzip -Z1 "$APK")"
    local e before=$FAILS
    for e in AndroidManifest.xml classes.dex assets/rootfs.tzst assets/container_pattern.tzst assets/rootfs_patches.tzst; do
        printf '%s\n' "$entries" | grep -qx "$e" || fail "APK 缺少 $e"
    done
    printf '%s\n' "$entries" | grep -q '^lib/arm64-v8a/.*\.so$' || fail "APK 缺少 lib/arm64-v8a/*.so"
    [ "$FAILS" -eq "$before" ] && ok "关键条目齐全 (manifest / dex / rootfs / container_pattern / rootfs_patches / arm64 native)"

    local aapt2 apksigner
    aapt2="$(find_sdk_tool aapt2)"; apksigner="$(find_sdk_tool apksigner)"
    if [ -n "$aapt2" ]; then
        local badge pkg
        badge="$("$aapt2" dump badging "$APK" 2>/dev/null | head -1)"
        pkg="$(printf '%s' "$badge" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
        if [ "$pkg" = "$APPID" ]; then ok "包名 $pkg; $(printf '%s' "$badge" | grep -o "versionName='[^']*'")"; else fail "包名为 '$pkg', 期望 '$APPID'"; fi
    else
        warn "未找到 aapt2, 跳过包名检查"
    fi
    if [ -n "$apksigner" ]; then
        local sig; sig="$("$apksigner" verify --print-certs "$APK" 2>&1)"
        if printf '%s' "$sig" | grep -q "certificate DN"; then
            ok "APK 签名校验通过"
            printf '%s' "$sig" | grep -q "Android Debug" && \
                warn "APK 使用 debug 证书签名: 每台 CI runner 的 debug 密钥都不同, 不同构建之间无法覆盖安装 (需先卸载), 且不可上架。请配置固定的发布 keystore (secrets: KEYSTORE_B64 等)"
        else
            fail "apksigner 校验失败: $(printf '%s' "$sig" | head -2 | tr '\n' ' ')"
        fi
    else
        warn "未找到 apksigner, 跳过签名检查"
    fi

    # 已知风险 (需要真机验证, 因此只告警): 上游 box64 的 PT_INTERP 写死 com.winlator 包名下的路径
    local b64 tmpd; b64="$(printf '%s\n' "$entries" | grep '^assets/box64/box64-.*\.tzst$' | sort -V | tail -1)"
    if [ -n "$b64" ] && command -v readelf >/dev/null 2>&1 && command -v zstd >/dev/null 2>&1; then
        tmpd="$(mktemp -d)"
        unzip -p "$APK" "$b64" | zstd -dc | tar -xf - -C "$tmpd" 2>/dev/null
        local bin interp want
        bin="$(find "$tmpd" -type f -name box64 | head -1)"
        interp="$(readelf -l "$bin" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)\]/\1/p')"
        want="/data/data/$APPID/files/rootfs/lib/ld-linux-aarch64.so.1"
        if [ -n "$interp" ] && [ "$interp" != "$want" ]; then
            warn "$(basename "$b64") 的 ELF 解释器写死为 '$interp', 而本应用包名 $APPID 的 rootfs 在 '$want': 内核 exec box64 时会因找不到解释器而失败。需在真机验证; 修复思路见 UPSTREAM.md"
        else
            ok "box64 ELF 解释器路径与包名一致"
        fi
        rm -rf "$tmpd"
    fi
}

# ---------------------------------------------------------------------------
case "${1:-}" in
    wine)   check_wine "${2:?缺少根目录}" "${3:-}" ;;
    smoke)  check_smoke "${2:?缺少根目录}" ;;
    rootfs) check_rootfs "${2:?缺少 rootfs 目录}" "${3:-}" ;;
    apk)    check_apk "${2:?缺少 apk 路径}" "${3:-}" ;;
    *) sed -n '2,15p' "$0"; exit 2 ;;
esac

echo "==> 健康检查完成: 失败 $FAILS 项, 警告 $WARNS 项"
[ "$FAILS" -eq 0 ]
