# Winlator CN — Wine 11.15 + 完整中文支持

基于 [brunodev85/Winlator](https://github.com/brunodev85/winlator) 11.1 定制的 Android Windows 模拟器：

- **Wine 11.15**（上游最新稳定版，替换内置的 Wine 10.10，新 WoW64 模式：unix 侧 x86_64 + PE 侧 i386/x86_64 双架构，由 Box64 模拟执行）
- **完整中文支持**：
  - Android 界面简体中文翻译（`values-zh-rCN`，316 条字符串）
  - 内置 Noto Sans CJK SC 中文字体（常规 + 粗体）
  - rootfs 注入 `zh_CN.UTF-8` locale（glibc + X11）与 fontconfig 中文别名
  - Wine 前缀注册表补丁：SimSun / 微软雅黑 / SimHei / 楷体 / 仿宋等中文字体自动映射到 Noto Sans CJK SC，避免中文乱码（豆腐块）

## 下载安装

前往 [Releases](../../releases) 页面下载 APK，传到手机/平板直接安装即可（需 Android 8.0+ / arm64 设备）。

> 应用包名为 `com.winlator.cn`，可与官方 Winlator 共存。

## 构建

本仓库**不在本地编译**，全部通过 GitHub Actions 云端完成（`.github/workflows/build.yml`）：

1. 拉取 `wine-11.15` 上游源码，应用 Winlator 定制补丁 `wine/winlator-custom-wine11.patch`（源自 brunodev85 的 wine-10.10-custom，经三方合并适配到 11.15）
2. 在 ubuntu-24.04（与 rootfs 同源 glibc 2.39）上交叉构建 Wine：unix 侧 x86_64 ELF + mingw-w64 构建 i386/x86_64 PE
3. `chinese/patch-rootfs.sh` 将新 Wine 注入 rootfs、注入中文字体/locale/注册表并重新打包
4. Gradle 构建 APK 并用发布密钥签名

手动触发：Actions → Build Winlator → Run workflow；或推送 `v*` 标签自动发布 Release。

## 目录结构

```
android/    Winlator 11.1 App 源码（含中文翻译与 zh_CN locale 支持）
wine/       Wine 11 构建脚本 + Winlator 定制补丁
chinese/    rootfs 中文化脚本、fontconfig、注册表补丁、Noto CJK 字体
.github/    CI 工作流
```

## 致谢与许可

- [Winlator](https://github.com/brunodev85/winlator) by brunodev85 — GPLv3
- [Wine](https://gitlab.winehq.org/wine/wine) — LGPL-2.1
- [Noto Sans CJK](https://github.com/notofonts/noto-cjk) — OFL 1.1
- [Box64](https://github.com/ptitSeb/box64) by ptitSeb

本项目同样以 GPLv3 发布。
