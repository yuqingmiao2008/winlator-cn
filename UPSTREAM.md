# 上游同步记录 (UPSTREAM)

`android/` 目录是 Winlator App 源码的**整体拷贝**(不是 git fork,也不是 submodule),中文化与 Wine 11 改动都叠加在它之上。
本文件记录当前所基于的上游精确版本、本仓库自有改动清单和同步方法,使以后的同步可重复、可审计。

## 当前基线

| 项目 | 内容 |
|---|---|
| 上游仓库 | https://github.com/brunodev85/winlator-app (App 源码)。原版 `brunodev85/winlator` 现在只是含子模块(app / gladio / vortek)的壳仓库 |
| 同步前基线 | `ca3d735a60d6` (2026-07-27, "gladio: Skip glFinish by default")。通过逐文件比对 blob 哈希确认(913 个文件中 905 个完全一致,其余 7 个为本仓库自有改动)。注意:此前 README 写的"基于 11.1"并不精确,实际是 11.1 之后、11.2 之前的 main 快照 |
| 同步后基线 | `a030f552f452` (2026-09-14, "app: Bump version code to 33"),即壳仓库 `brunodev85/winlator@b6b2259` 当前固定的 app 版本 |
| 变更规模 | 62 个上游提交;112 个文本文件(+3012/-752 行);10 个二进制资源;忽略 `.idea/` |
| 与 11.2.0 发布的关系 | 上游 `v11.2.0` 发布于 2026-08-19(versionCode 32);其后 main 上又有 27 个提交,本次一并同步 |
| 同步日期 | 2026-10-06 |
| 同步方式 | 三方合并(base = 同步前基线,theirs = 同步后基线,ours = 本仓库 `android/`)。不引入上游提交历史,避免仓库膨胀 |

## 本仓库在上游之上的自有改动(再次同步时必须保留)

| 文件 | 改动 |
|---|---|
| `app/build.gradle` | `applicationId 'com.winlator.cn'`;`versionCode` = 上游 + 1(当前 34);`versionName "1.0.0"`;`packaging.jniLibs.pickFirsts` 去重列表(midihandler 预编译库与 CMake 产物同名) |
| `app/src/main/AndroidManifest.xml` | FileProvider authorities 改为 `${applicationId}.FileProvider` |
| `core/FileUtils.java` | FileProvider authority 改为 `com.winlator.cn.FileProvider` |
| `core/WineInfo.java` | `MAIN_WINE_VERSION = "11.15"` |
| `core/LocaleHelper.java` | `supportedLocales` 增加 `zh_CN` |
| `res/values/strings.xml` | `app_name` = "Winlator CN" |
| `res/values/arrays.xml` | `language_entries` 增加"简体中文" |
| `res/values-zh-rCN/strings.xml` | 简体中文翻译(上游新增字符串需要同步翻译) |

## 本次同步的关键变更

**应用层**
- 新增前台服务 `ForegroundService` 与通知(后台保护、锁屏唤醒锁两项设置,通知文案已本地化;Manifest 新增 `POST_NOTIFICATIONS` / `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK` / `WAKE_LOCK`)。此部分来自社区贡献者。
- 新增"从 Steam 运行时节省内存"选项(`SaveMemoryTask`)。
- WinHandler 新增请求;手柄状态不再过量发送;uinput/指纹设备不再被识别为手柄;自定义按键处理修复。
- 快捷方式重命名修复,可选择快捷方式名称;PEParser 版本信息读取改进;内存泄漏修复;移除不安全的 `scheduleAtFixedRate`。
- 默认 Box64 预设由 `INTERMEDIATE` 改为 `PERFORMANCE`;默认关闭垂直同步;新增 Present Mode 选项(immediate / mailbox / fifo)。

**X Server 与渲染**
- 新增 XInput 扩展与 Generic Event 扩展(含 XIRaw* 事件),改进 Sync / XComposite / Present / DRI3 / MIT-SHM 扩展;渲染着色器现代化,改进图像呈现。
- Gladio 渲染器多项改进(纹理、帧缓冲、ARB program、着色器转换等);Vortek 改进纹理解码并按 driverID 暴露扩展。

**组件与启动参数**
- Box64 0.4.0 → 0.4.4;Turnip 26.1.0 → 26.2.0;Gladio 1.0 → 1.1;Vortek 2.1 重新构建;rootfs / rootfs_patches 更新(`RootFSInstaller.LATEST_VERSION` 21 → 23)。
- `default.box64rc` 更新(+65 行,新增 Steam 及若干游戏规则);启动环境新增 `BOX64_DYNACACHE=0`;vkd3d 配置更新。

**构建系统**
- Android Gradle Plugin 7.2.2 → 8.4.2;Gradle 7.3.3 → 8.14.5;compileSdk 34 → 35;新增 `namespace 'com.winlator'`;新增依赖 `androidx.lifecycle:lifecycle-process:2.5.1`;`gradle.properties` 移除 `org.gradle.jvmargs`。

## 合并时的冲突处理

- `app/build.gradle`:版本字段两边都改了 → 保留 `versionName "1.0.0"`,`versionCode` 取上游 33 + 1 = 34(沿用此前"上游 + 1"的约定,且高于已发布的 29)。
- `arrays.c` / `arrays.h`:本仓库此前手工补的 `IntArray_indexOf` 已被上游收录 → 直接取上游版本,删除本地补丁(否则会重复定义)。
- AGP 8 适配:`packagingOptions { pickFirsts += [...] }` 改为 `packaging { jniLibs { pickFirsts.addAll([...]) } }`。
- `values-zh-rCN/strings.xml`:补齐 10 条新增字符串的翻译,删除上游已移除的 `sync_every_frame`。

## 二进制资源(全部来自上游官方提交 `a030f552f452`,合入前已做 zstd 完整性、tar 路径安全、ELF 架构(aarch64)检查)

| 路径(相对 `assets/` 或 `res/`) | 状态 | 大小(字节) | SHA-256 |
|---|---|---|---|
| `box64/box64-0.4.0.tzst` | 删除 | - | - |
| `assets/box64/box64-0.4.4.tzst` | 新增 | 4,540,371 | `e1a34fed50bb38ef7fbf51ad5e5b9a76ec4c8178f9cfb4b9f6def0497f2f446c` |
| `graphics_driver/gladio-1.0.tzst` | 删除 | - | - |
| `assets/graphics_driver/gladio-1.1.tzst` | 新增 | 107,293 | `925a492ca58d4670271aabe6c6aaeef0df1e22932955025afb3fe23f26442ac3` |
| `graphics_driver/turnip-26.1.0.tzst` | 删除 | - | - |
| `assets/graphics_driver/turnip-26.2.0.tzst` | 新增 | 2,659,862 | `1e5bd643d64b450960ea3208cc96599a4de577f178e9ba0843b1c37083ce50d2` |
| `assets/graphics_driver/vortek-2.1.tzst` | 更新 | 124,813 | `505e5089371d8698184a3722d8672628b8ef1aa0a201efa6bf1f8d6163cc08cf` |
| `assets/rootfs.tzst` | 更新 | 65,254,618 | `aeea2938cc63b0708cb2da999b5a0e3915229b6ab4eac13de061c87f34ffc1dc` |
| `assets/rootfs_patches.tzst` | 更新 | 4,174,031 | `49ab7a5158ef7ccff5ae96dfd539df48483454ed11c0d6788a4f95e0104c864a` |
| `res/drawable/icon_notification.png` | 新增 | 771 | `46e7d058675671c81ef6d158501501cfd98f02a6c28497fc52ba81ab8aeb8b29` |

> 说明:上述二进制由上游作者构建,本仓库未对其做逆向审计;仅保证来源可溯源(上游提交 + 哈希)并在 CI 中校验哈希清单(见 `ci/assets.sha256`)。

## 如何再次同步

1. `git clone --filter=blob:none --no-checkout https://github.com/brunodev85/winlator-app.git /tmp/up`
2. 以本文件"同步后基线"为 base,上游目标提交为 target(参考壳仓库 `brunodev85/winlator` 的 main 所固定的 app 提交)。
3. 对 `git diff-tree -r --no-renames base target` 的每个文件:本仓库未改过的直接取上游;改过的用 `git merge-file --diff3` 三方合并;二进制资源只在本仓库未改过时取上游。
4. 按上表核对自有改动仍在;补齐新增字符串的中文翻译;更新本文件与 `ci/assets.sha256`;最后用 CI 全量验证。

## 附录:同步范围内的 62 个上游提交(由旧到新)

- `7b40618` 2026-07-29 app: Update utility functions
- `92bf217` 2026-07-29 app: Update rootfs
- `e3fce33` 2026-07-29 app: Bump version code to 31
- `2d8b44e` 2026-07-29 gladio: Add fallback formats
- `5299b4f` 2026-07-29 gladio: Improve arb programs
- `f173b7c` 2026-07-29 app: Fix frame rating visibility
- `aef08c8` 2026-07-29 app: Implement new requests in WinHandler
- `a4c4d1b` 2026-07-30 app: Implement foreground service for background session protection
- `a9f3bfb` 2026-07-30 Merge branch 'refs/heads/main' into fix-containerClosesOnBackground-0
- `45414e0` 2026-07-30 app: Use WeakReference for NotificationUtils singleton; Refine ForegroundService wake lock logic
- `0757a30` 2026-07-30 app: Remove the custom 6-hour timer, as it is unnecessary. - After investigating further, it turns out that the foreground service time limit does not apply to this project as long as `targetSdkVersion` is below 35.
- `c366be8` 2026-07-31 gladio: Rework bound textures
- `338aba2` 2026-07-31 gladio: Implement parameter getter for framebuffers
- `d23b8b4` 2026-08-01 Implement and update the translations for the foreground service notification message. - Now the notification displays the language corresponding to the app’s language setting.
- `5f43269` 2026-08-02 ForegroundService: Fix indentation in some getters.
- `116b3b2` 2026-08-02 SettingsFragment: Remove unsued tag.
- `c14b8bf` 2026-08-04 app: Update debug things
- `065db8d` 2026-08-04 app: Fix memory leak
- `1a7dc8b` 2026-08-04 gladio: Implement a better way to handle active textures
- `d17738a` 2026-08-04 app: Move the current graphics driver to the preferences
- `7ff0bc0` 2026-08-04 app: Update graphics driver gladio
- `f41b8b2` 2026-08-04 app: Update Box64
- `97c57e9` 2026-08-04 app: Update config entries
- `aeb4439` 2026-08-04 app: Fix shortcut rename
- `f5c4952` 2026-08-04 xserver: Bring to front child surface windows
- `4a822be` 2026-08-04 gladio: Do not use two display buffers
- `19dc687` 2026-08-09 ForegroundService fix: use a dedicated background thread for screen state broadcasts to prevent ANR and race conditions
- `a917fe5` 2026-08-17 gladio: Add a better way to handle active textures
- `0ad95c7` 2026-08-17 gladio: Update debug utility functions
- `fa9e997` 2026-08-17 gladio: Improve shader converter
- `1ef37fa` 2026-08-17 gladio: Check if alphaTest is enabled
- `eab6845` 2026-08-17 app: Update IDE files
- `3447cbd` 2026-08-17 app: Update .gitignore
- `fe15e3d` 2026-08-17 app: Add SparseArray64 to arrays utility
- `3daac24` 2026-08-17 app: Update graphics driver vortek
- `dcd82b4` 2026-08-17 app: Do not send gamepad state excessively
- `f7a5fc8` 2026-08-19 vortek: Improve texture decoder
- `36f1da4` 2026-08-19 vortek: Expose extensions based on driverID
- `62dee14` 2026-08-19 vortek: Set convertFormatScaled to true
- `d5f2d88` 2026-08-19 xserver: Improve XComposite extension
- `6e6c7cb` 2026-08-19 app: Fix function name
- `eaf5ae2` 2026-08-19 xserver: Modernize renderer shaders
- `c03f6ab` 2026-08-19 app: Bump version code to 32
- `4f55d11` 2026-08-19 Merge pull request #39 from Juan-Antonio-Doe/fix-containerClosesOnBackground-0
- `6950842` 2026-08-28 app: Add new string entries
- `037651d` 2026-08-28 app: Update vkd3d config
- `167230c` 2026-08-28 app: Remove unsafe scheduleAtFixedRate
- `d921ebd` 2026-08-28 app: Update Box64 RCFILE
- `45c5d41` 2026-09-10 xserver: Implement XInput extension
- `2582b65` 2026-09-10 xserver: Improve Sync extension
- `a71861a` 2026-09-10 xserver: Add event and error count
- `cd6f7d2` 2026-09-10 xserver: Implement Generic Event extension
- `4edfada` 2026-09-10 app: Update notification icon
- `f205cd7` 2026-09-10 app: Update rootfs
- `3af5288` 2026-09-10 app: Implement an option to save memory on run from Steam
- `33f9d0b` 2026-09-14 app: Update graphics driver turnip
- `86cc43f` 2026-09-14 app: Update vkd3d config
- `c292889` 2026-09-14 app: Change the default Box64 preset
- `8f224bb` 2026-09-14 app: Update Box64 RCFILE
- `68e375c` 2026-09-14 app: Improve the presentation of rendered images
- `4f539f0` 2026-09-14 app: Disable the vsync by default
- `a030f55` 2026-09-14 app: Bump version code to 33
