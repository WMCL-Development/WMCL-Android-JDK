# wmcl-android-jdk

为 WMCL 构建 Android arm64 的运行时 OpenJDK JDK（含 javac/ct.sym，不含 jmods/src.zip/demo/include/man；jlink 不可用）。

## 分支与版本

| 分支 | 版本 | 产物 |
|---|---|---|
| `openjdk-jdk8` | 8u514（1.8.0_514） | `jdk8-android-arm64.tar.xz` |
| `openjdk-jdk11` | 11.0.33.1 | `jdk11-android-arm64.tar.xz` |
| `openjdk-jdk17` | 17.0.21.1（默认分支） | `jdk17-android-arm64.tar.xz` |
| `openjdk-jdk21` | 21.0.13.1 | `jdk21-android-arm64.tar.xz` |
| `openjdk-jdk25` | 25.0.5.1 | `jdk25-android-arm64.tar.xz` |

产物是运行时 JDK：包含 `bin/javac`、`lib/ct.sym`、`lib/modules`、`lib/fontconfig*`、`lib/fonts/`、`lib/security`、`conf/`、`legal/`，保留 javac 编译能力；不包含 `jmods/`、`src.zip`、`demo/`、`include/`、`man/`（因此 `jlink` 不可用，这是预期取舍，用于压缩包体）。

## 构建

- GitHub Actions，ubuntu-22.04
- Android NDK r27b，aarch64，headless server JVM
- 打包前对 native 库执行 NDK `llvm-strip` 和 `termux-elf-cleaner`
- 从 Amethyst/FCL 的 `jre_override/lib` 复制 fontconfig 与 Lucida 字体（headless 构建不产出这些文件）
- `libc++_shared.so` 取自 NDK，`libfreetype.so` 由随附 freetype 源码构建

## Android 适配补丁

- `markOop::value()` 编译器屏障：阻止 clang 按指针对齐假设折叠锁状态位
- `compiledIC` 的 `CompiledICHolder` 指针 tag 恢复：修复 48 位 inline-cache cell 截断 Android tagged CHeap 指针
- jdk8 额外修复：`Arena::destruct_contents` 判空、`replicate()` shift UB、adrp/movk tagged pointer
- 补丁来源：Amethyst 的 `patches/jre_17`、`patches/jre_21`、`jdk25u_android.diff`；jdk11 参考 FCL 补丁并拆分为 Amethyst 风格

## 测试

`tests/` 下保留 Stress 回归用例（高频触发 `CompiledICHolder`）和运行说明。每个版本验收：

- `java -version`、`javac -version`
- FontTest / FontConfiguration
- Stress mixed、C1-only 各 50 次
- Hello mixed、C1-only 各 50 次
- SerialGC / G1 各 10 次

## Parity

与 Amethyst arm64 包逐文件对比，报告见各分支 `tests/parity-jdk<N>.txt`：

| 版本 | 运行时缺失 | 说明 |
|---|---|---|
| jdk8 | 0 | 27 个 `man/*` 为运行时包主动删除；其余为 JDK-only 工具/文档 |
| jdk11 | 0 | `conf/sdp`（JDK14+ 才有）、`libjli` 的 `lib/jli/` 布局、legal 文档，均为版本/布局差异 |
| jdk17 | 0 | 无 |
| jdk21 | 0 | 无 |
| jdk25 | 0 | 仅 2 个允许项：`lib/libawt_xawt.so`（Amethyst 的 6.8KB dummy；FCL/Amethyst 会在导入后从 APK nativeLibraryDir 注入，不是真 X11 后端）+ `legal/java.base/gcc.md` |

补充：

- jdk11/17/21 的 `lib/libsleef.so` 与 Amethyst 同版本一样不存在，不是缺失；jdk25 的两边都有。
- 允许差异仅限 JDK 版本、legal 文档、版本特有工具；任何 Android 会加载的 `lib/*.so` 或运行资源缺失都算失败。
- 目前所有版本 blocker = 0。
- FCL 的 `RuntimeUtils.patchJava` 和 Amethyst 的 `MultiRTUtils.postPrepare` 都会从 APK 的 nativeLibraryDir 复制 `libawt_xawt.so`（dummy）到运行时 `lib/`。Android 没有真实 X11 后端，这个 dummy 是给 Cacio/AWT 兜底。我们的包不带它；WMCL 启动器接入时要执行同样的注入，或把 dummy 放进包。

## 许可证

- 本仓库构建脚本：Apache-2.0
- 产物中的 OpenJDK：GPLv2+CE
- Lucida 字体与 fontconfig 来自 Oracle/OpenJDK 发行包（经 Amethyst 的 `jre_override` 引入），见 `THIRD_PARTY_README`

## 参考项目

- [AngelAuraMC/angelauramc-openjdk-build](https://github.com/AngelAuraMC/angelauramc-openjdk-build)
- [FCL-Team/Android-OpenJDK-Build](https://github.com/FCL-Team/Android-OpenJDK-Build)
