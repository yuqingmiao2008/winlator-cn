package com.winlator.core;

import android.content.Context;
import android.util.Log;

import com.winlator.xenvironment.RootFS;

import java.io.File;
import java.nio.charset.StandardCharsets;

/**
 * 修复上游预编译产物里写死的运行时绝对路径。
 *
 * <p>上游 Winlator 的包名是 {@code com.winlator}，它构建出来的 box64 与 rootfs 内部分工具在编译时就把
 * {@code PT_INTERP} / RUNPATH 指向了 {@code /data/data/com.winlator/files/rootfs/...}。本应用包名是
 * {@code com.winlator.cn}，路径对不上，而应用是<b>直接 exec</b> box64（没有显式指定加载器），
 * 于是内核按 {@code PT_INTERP} 找解释器时返回 ENOENT，表现为：
 * <pre>box64: cannot execute: required file not found</pre>
 * Wine 因此永远起不来，界面就一直停在"正在启动…"（{@code PreloaderDialog} 只在 Wine 真正 map 出
 * 窗口后才会关闭）。官方包名安装时路径恰好匹配，所以上游不会有这个问题。
 *
 * <p>这里在每次启动容器前做一次<b>幂等</b>的原地改写：把 {@code PT_INTERP} 换成本包名下的短路径
 * （{@code <files>/rootfs/lib/ld.so}，指向 rootfs 里的 {@code ld-linux-aarch64.so.1}）。
 * {@code .interp} 段的长度不变，只覆盖其中的字符串并补 NUL，因此不需要重新链接、也不会改动文件里其它偏移。
 * 之所以用别名而不是直接写 {@code .../rootfs/lib/ld-linux-aarch64.so.1}：完整路径比上游预留的 63 字节
 * 长出几个字节，放不进 {@code .interp} 段。
 *
 * <p>RUNPATH 同样是上游前缀，但应用已经设置了 {@code LD_LIBRARY_PATH=<rootfs>/usr/lib}，
 * 动态加载器会优先查 {@code LD_LIBRARY_PATH}，所以不影响加载，这里不动它。
 *
 * <p>另外 rootfs 里有几个文本配置也写死了上游前缀，一并按本包名的实际路径改写（幂等）：
 * {@code /etc/fonts/fonts.conf}（字体目录，不改会让内置 Noto CJK 扫不到）、
 * {@code /usr/share/alsa/alsa.conf}、{@code /etc/pulse/client.conf}。
 * {@code /etc/ld.so.cache} 是二进制缓存，不改写：{@code LD_LIBRARY_PATH} 的查找顺序在缓存之前。
 */
public abstract class NativeExecFixer {
    private static final String TAG = "WinlatorCN";
    /** 上游 Winlator 的运行时前缀，预编译产物里写死的绝对路径都以它开头 */
    public static final String UPSTREAM_PREFIX = "/data/data/com.winlator/";
    private static final String DATA_PREFIX = "/data/data/";
    private static final String LOADER_FILE_NAME = "ld-linux-aarch64.so.1";
    /** 上游 aarch64 可执行文件的 .interp 段大小；解析不出来时用它兜底 */
    private static final int FALLBACK_INTERP_CAPACITY = 63;

    /** rootfs 内会被<b>直接 exec</b> 的 aarch64 程序（相对 rootfs 根目录） */
    private static final String[] NATIVE_EXECUTABLES = {
        "/usr/local/bin/box64",
        "/usr/bin/locale",
        "/usr/bin/localedef",
        "/usr/lib/getconf/POSIX_V6_LP64_OFF64",
        "/usr/lib/getconf/POSIX_V7_LP64_OFF64",
        "/usr/lib/getconf/XBS5_LP64_OFF64"
    };

    /** rootfs 内写死了上游前缀、需要按本包名实际路径改写的文本配置（相对 rootfs 根目录） */
    private static final String[] TEXT_CONFIGS = {
        "/etc/fonts/fonts.conf",
        "/usr/share/alsa/alsa.conf",
        "/etc/pulse/client.conf"
    };

    /** 文本配置里出现的上游 rootfs 绝对路径 */
    private static final String UPSTREAM_ROOTFS_PREFIX = UPSTREAM_PREFIX + "files/rootfs";

    /**
     * 修复 rootfs 里所有带上游前缀的原生可执行文件。rootfs 还没解包时直接返回，
     * 重复调用是安全的（已经是正确路径的文件会被跳过）。
     */
    public static void fix(Context context) {
        RootFS rootFS = RootFS.find(context);
        File rootDir = rootFS.getRootDir();
        fixTextConfigs(rootDir);

        File loaderFile = new File(rootDir, "/lib/" + LOADER_FILE_NAME);
        if (!loaderFile.isFile()) return;

        File box64File = new File(rootDir, NATIVE_EXECUTABLES[0]);
        int capacity = ElfHelper.getInterpreterCapacity(box64File.isFile() ? box64File : loaderFile);
        if (capacity <= 0) capacity = FALLBACK_INTERP_CAPACITY;

        String interpreter = createLoaderAlias(context, rootDir, loaderFile, capacity);
        if (interpreter == null) {
            Log.w(TAG, "无法为 " + LOADER_FILE_NAME + " 建立短路径别名，box64 可能仍然无法启动");
            return;
        }

        for (String relativePath : NATIVE_EXECUTABLES) {
            File binFile = new File(rootDir, relativePath);
            if (!binFile.isFile()) continue;

            String current = ElfHelper.getInterpreter(binFile);
            if (current == null || current.equals(interpreter)) continue;
            if (!current.startsWith(DATA_PREFIX)) continue;
            if ((new File(current)).isFile()) continue;

            if (ElfHelper.setInterpreter(binFile, interpreter)) {
                Log.i(TAG, "已修正 " + relativePath + " 的解释器: " + current + " -> " + interpreter);
            }
            else {
                Log.w(TAG, "修正 " + relativePath + " 失败: .interp 段只有 " + capacity + " 字节，放不下 " + interpreter);
            }
        }
    }

    /**
     * 在 rootfs 里建立指向加载器的短路径别名，返回能放进 {@code .interp} 段的那个路径。
     * 依次尝试 {@code <rootfs>/lib/ld.so}、{@code <files>/ld.so}，都不够短就放弃。
     */
    private static String createLoaderAlias(Context context, File rootDir, File loaderFile, int capacity) {
        File[] aliases = {new File(rootDir, "/lib/ld.so"), new File(context.getFilesDir(), "ld.so")};
        String[] targets = {LOADER_FILE_NAME, loaderFile.getPath()};

        for (int i = 0; i < aliases.length; i++) {
            String path = aliases[i].getPath();
            if (path.getBytes(StandardCharsets.UTF_8).length + 1 > capacity) continue;
            if (ensureAlias(aliases[i], targets[i], loaderFile)) return path;
        }
        return null;
    }

    private static boolean ensureAlias(File aliasFile, String linkTarget, File loaderFile) {
        if (aliasFile.isFile()) return true;

        FileUtils.symlink(linkTarget, aliasFile.getPath());
        if (aliasFile.isFile()) return true;

        if (!FileUtils.copy(loaderFile, aliasFile)) return false;
        FileUtils.chmod(aliasFile, 0755);
        return aliasFile.isFile();
    }

    /**
     * 把 rootfs 里几个写死上游前缀的文本配置改写成实际路径。已经是正确路径时不做任何事。
     */
    private static void fixTextConfigs(File rootDir) {
        String actualPath = rootDir.getPath();

        for (String relativePath : TEXT_CONFIGS) {
            File configFile = new File(rootDir, relativePath);
            if (!configFile.isFile()) continue;

            String content = FileUtils.readString(configFile);
            if (content == null || !content.contains(UPSTREAM_ROOTFS_PREFIX)) continue;

            if (FileUtils.writeString(configFile, content.replace(UPSTREAM_ROOTFS_PREFIX, actualPath))) {
                Log.i(TAG, "已改写 " + relativePath + " 里的上游路径前缀 -> " + actualPath);
            }
            else {
                Log.w(TAG, "改写 " + relativePath + " 失败");
            }
        }
    }
}
