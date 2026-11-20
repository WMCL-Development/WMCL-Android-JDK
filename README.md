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

## Third-party fonts and native libraries

The JDK images bundle `lib/fontconfig*.properties`, `lib/fonts/Lucida*.ttf` and
`lib/fonts/fonts.dir`. These files are copied at build time from the Amethyst
Android build repository (`AngelAuraMC/angelauramc-openjdk-build`, directory
`jre_override/lib`) because Android headless builds of OpenJDK omit the closed
fontconfig database and Lucida fonts. The Lucida fonts are part of the
Oracle/OpenJDK binary distribution; see `THIRD_PARTY_README` for the font
licenses. `libfreetype.so` is built from the bundled freetype sources, and
`libc++_shared.so` is taken from the Android NDK.

Before packaging, native libraries are stripped with the NDK `llvm-strip`
(`--strip-unneeded`, dynamic symbols preserved) and processed with
`termux-elf-cleaner` (same as FCL/Amethyst) so Android's linker accepts the
ELF metadata.
