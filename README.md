# wmcl-android-jdk

为 WMCL 构建 Android 可用的 OpenJDK 运行时。

- 基线：OpenJDK 17u 17.0.21.1（最新 GA，GPLv2+CE）
- Android 补丁：Amethyst 项目的 patches/jre_17/android（构建时从固定 commit 拉取，不存入本仓库）
- 构建：Android NDK r27b，aarch64，headless server JVM
- 产物：jre17-android-arm64.tar.xz

参考项目：

- AngelAuraMC/angelauramc-openjdk-build
- FCL-Team/Android-OpenJDK-Build

许可证：

- 本仓库构建脚本：Apache-2.0
- 产物中的 OpenJDK 运行时：GPLv2+CE，源码/补丁来源见上
