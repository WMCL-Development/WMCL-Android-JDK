#!/usr/bin/env bash
# Build an Android aarch64 JRE from OpenJDK 17u (latest GA) with the
# Amethyst Android patch set as the starting point.
#
# OpenJDK runtime: GPLv2+CE. Our build tooling: Apache-2.0.
# Android patches are downloaded at build time from a pinned Amethyst commit.
set -eo pipefail
JDK_REPO="openjdk/jdk25u"
JDK_MAJOR="25"

JDK_VERSION="jdk-25.0.5.1-ga"
JDK_TAG="jdk-25.0.5.1-ga"
PATCH_REPO="AngelAuraMC/angelauramc-openjdk-build"
PATCH_COMMIT="196da32d80fe96d6967ca1c154f102cff0dfc389"
PATCH_DIR="patches/jre_17/android"

TARGET_ARCH="${TARGET_ARCH:-arm64}"
case "$TARGET_ARCH" in
  arm64)  TARGET="aarch64-linux-android"; TARGET_JDK="aarch64"; TARGET_SHORT="arm64" ;;
  x86_64) TARGET="x86_64-linux-android"; TARGET_JDK="x86_64"; TARGET_SHORT="x86_64" ;;
  *) echo "unsupported TARGET_ARCH: $TARGET_ARCH" >&2; exit 2 ;;
esac
NDK_VERSION="r27b"
API="21"
FREETYPE_VERSION="2.10.0"
CUPS_VERSION="2.2.4"
JVM_VARIANTS="server"
JDK_DEBUG_LEVEL="release"

ROOT="$PWD"
if [ -n "$GITHUB_WORKSPACE" ]; then ROOT="$GITHUB_WORKSPACE"; fi
WORK="$ROOT/.jdk-build"
OUT="$ROOT/out"
mkdir -p "$WORK" "$OUT"
cd "$WORK"

NDK="$WORK/android-ndk-$NDK_VERSION"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
PATCH_REPO_DIR="$WORK/amethyst-patches"

echo "==> Preparing Android NDK $NDK_VERSION"
if [ ! -d "$TOOLCHAIN" ]; then
  curl -fL --retry 3 -o ndk.zip "https://dl.google.com/android/repository/android-ndk-$NDK_VERSION-linux.zip"
  unzip -q ndk.zip
  rm -f ndk.zip
fi
cat > "$TOOLCHAIN/devkit.info" <<EOF
DEVKIT_NAME="Android $TARGET_JDK"
DEVKIT_TOOLCHAIN_PATH="$DEVKIT_ROOT/bin"
DEVKIT_SYSROOT="$DEVKIT_ROOT/sysroot"
EOF

echo "==> Preparing freetype and CUPS sources"
if [ ! -d "$WORK/freetype-$FREETYPE_VERSION" ]; then
  curl -fL --retry 3 -o freetype.tar.gz "https://downloads.sourceforge.net/project/freetype/freetype2/$FREETYPE_VERSION/freetype-$FREETYPE_VERSION.tar.gz"
  tar xf freetype.tar.gz
  rm -f freetype.tar.gz
fi
if [ ! -d "$WORK/cups-$CUPS_VERSION" ]; then
  curl -fL --retry 3 -o cups.tar.gz "https://github.com/apple/cups/releases/download/v$CUPS_VERSION/cups-$CUPS_VERSION-source.tar.gz"
  tar xf cups.tar.gz
  rm -f cups.tar.gz
fi

FREETYPE_DIR="$WORK/freetype-$FREETYPE_VERSION/build_android-$TARGET_SHORT"
if [ ! -d "$FREETYPE_DIR" ]; then
  echo "==> Building freetype for $TARGET"
  (
    cd "freetype-$FREETYPE_VERSION"
    export PATH="$TOOLCHAIN/bin:$PATH"
    export CC="$TOOLCHAIN/bin/$TARGET$API-clang"
    export CXX="$TOOLCHAIN/bin/$TARGET$API-clang++"
    ./configure --host="$TARGET" --prefix="$FREETYPE_DIR" --without-zlib --with-png=no --with-harfbuzz=no \
      CFLAGS="--sysroot=$TOOLCHAIN/sysroot" LDFLAGS="--sysroot=$TOOLCHAIN/sysroot"
    CFLAGS="-fno-rtti --sysroot=$TOOLCHAIN/sysroot" CXXFLAGS="-fno-rtti --sysroot=$TOOLCHAIN/sysroot" make -j"$(nproc)"
    make install
  )
fi

echo "==> Cloning OpenJDK $JDK_TAG"
if [ ! -d "$WORK/openjdk/.git" ]; then
  git clone --depth 1 --branch "$JDK_TAG" https://github.com/$JDK_REPO "$WORK/openjdk"
fi
cd "$WORK/openjdk"
git reset --hard

echo "==> Downloading Amethyst Android patches @ 7a0266e745d9b4acf400afa189b58e672900f710"
rm -rf "$PATCH_REPO_DIR"
mkdir -p "$PATCH_REPO_DIR"
curl -fL --retry 3 -o "$PATCH_REPO_DIR/patches.tar.gz" "https://github.com/AngelAuraMC/angelauramc-openjdk-build/archive/7a0266e745d9b4acf400afa189b58e672900f710.tar.gz"
tar xf "$PATCH_REPO_DIR/patches.tar.gz" -C "$PATCH_REPO_DIR"
SRC_DIR="$(find "$PATCH_REPO_DIR" -maxdepth 1 -type d -name 'angelauramc-openjdk-build-*' | head -n 1)"

echo "==> Applying Android patches"
for NAME in jdk25u_android.diff; do
  patch="$SRC_DIR/patches/$NAME"
  if git apply --reject --whitespace=fix "$patch"; then continue; fi
  # Only these two hunks are known to drift against 25.0.5.1; both are handled
  # below. Anything else is fatal.
  bad="$(find . -name '*.rej' -print | grep -vE '(^\./make/autoconf/libraries\.m4\.rej$)|(^\./src/hotspot/os/linux/os_linux\.cpp\.rej$)|(^\./make/autoconf/build-aux/config\.sub\.rej$)' || true)"
  if [ -n "$bad" ]; then echo "Unresolved rejects from $NAME:"; echo "$bad"; exit 1; fi
  # libraries.m4: the X11 hunk is obsolete because the build is headless-only.
  # os_linux.cpp: provide the aarch64 SYS_gettid fallback from the patch.
  if ! grep -q 'define SYS_gettid 178' src/hotspot/os/linux/os_linux.cpp; then
    perl -0pi -e 's/\n  #else\n    #error "Define SYS_gettid for this architecture"/\n  #elif defined(__aarch64__)\n    #define SYS_gettid 178\n  #else\n    #error "Define SYS_gettid for this architecture"/' src/hotspot/os/linux/os_linux.cpp
  fi
  find . -name '*.rej' -delete
  find . -name '*.orig' -delete
  echo "note: re-applied drifted hunks from $NAME"
done

echo "==> Preparing toolchain headers"
ln -sfn /usr/include/X11 "$TOOLCHAIN/sysroot/usr/include/X11"
ln -sfn /usr/include/alsa "$TOOLCHAIN/sysroot/usr/include/alsa"
mkdir -p "$TOOLCHAIN/sysroot/usr/include/fontconfig"
cp -R /usr/include/fontconfig/. "$TOOLCHAIN/sysroot/usr/include/fontconfig/"
ln -sfn "$WORK/cups-$CUPS_VERSION/cups" "$TOOLCHAIN/sysroot/usr/include/cups"

cat > "$WORK/android-wrapped-clang" <<EOF
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  echo "$TARGET-gcc (GCC) 4.9 20140827 (prerelease)"
  exit 0
fi
exec "$TOOLCHAIN/bin/$TARGET$API-clang" -Wno-unknown-warning-option "$@"
EOF
cat > "$WORK/android-wrapped-clang++" <<EOF
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  echo "$TARGET-g++ (GCC) 4.9 20140827 (prerelease)"
  exit 0
fi
exec "$TOOLCHAIN/bin/$TARGET$API-clang++" -Wno-unknown-warning-option "$@"
EOF
chmod +x "$WORK/android-wrapped-clang" "$WORK/android-wrapped-clang++"

export PATH="$TOOLCHAIN/bin:$PATH"
mkdir -p "$WORK/dummy_libs"
for lib in pthread rt thread_db asound pulse; do
  rm -f "$WORK/dummy_libs/lib$lib.a"
  "$TOOLCHAIN/bin/llvm-ar" cru "$WORK/dummy_libs/lib$lib.a"
done

export CFLAGS="-DLE_STANDALONE -O3 -mllvm -polly -DANDROID -Wno-error=implicit-function-declaration -Wno-error=int-conversion -I$TOOLCHAIN/sysroot/usr/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$WORK/dummy_libs -Wl,--undefined-version"
export CC="$TOOLCHAIN/bin/$TARGET$API-clang"
export CXX="$TOOLCHAIN/bin/$TARGET$API-clang++"
export BUILD_CC=/usr/bin/gcc
export BUILD_CXX=/usr/bin/g++
export BUILD_LD=/usr/bin/ld
export AR="$TOOLCHAIN/bin/llvm-ar"
export AS="$TOOLCHAIN/bin/llvm-as"
export LD="$TOOLCHAIN/bin/ld"
export NM="$TOOLCHAIN/bin/llvm-nm"
export OBJCOPY="$TOOLCHAIN/bin/llvm-objcopy"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"

echo "==> Configuring OpenJDK $JDK_VERSION for $TARGET"
build_platform_arg=()
if [ "$TARGET_ARCH" = "x86_64" ]; then
  # Force cross-compilation mode so OpenJDK builds adlc with the host toolchain.
  build_platform_arg=(--build=aarch64-unknown-linux-gnu)
fi
if ! bash ./configure "${build_platform_arg[@]}" \
  --openjdk-target="$TARGET" \
  --with-build-jdk="$JAVA_HOME" \
  --with-toolchain-type=clang \
  --with-sysroot="$TOOLCHAIN/sysroot" \
  --with-extra-cflags="$CFLAGS" \
  --with-extra-cxxflags="$CXXFLAGS" \
  --with-extra-ldflags="$LDFLAGS" \
  --disable-precompiled-headers \
  --disable-warnings-as-errors \
  --enable-option-checking=fatal \
  --enable-headless-only=yes \
  --with-jvm-variants="$JVM_VARIANTS" \
  --with-jvm-features=-dtrace,-zero,-vm-structs,-epsilongc \
  --with-cups-include="$WORK/cups-$CUPS_VERSION" \
  --with-native-debug-symbols=none \
  --with-debug-level="$JDK_DEBUG_LEVEL" \
  --with-fontconfig-include="$TOOLCHAIN/sysroot/usr/include" \
  --with-alsa-include="$TOOLCHAIN/sysroot/usr/include" \
  --x-includes="$TOOLCHAIN/sysroot/usr/include/X11" \
  --x-libraries=/usr/lib \
  --with-freetype-include="$FREETYPE_DIR/include/freetype2" \
  --with-freetype-lib="$FREETYPE_DIR/lib"
then
  echo "configure failed; dumping config.log tail" >&2
  tail -n 300 config.log >&2
  exit 1
fi

echo "==> Building OpenJDK images"
BUILD_DIR="$(find build -maxdepth 1 -type d -name "linux-$TARGET_JDK-*" | head -n 1)"
test -d "$BUILD_DIR"
if [ "$TARGET_ARCH" = "x86_64" ]; then
  # OpenJDK sees build CPU == target CPU and treats this as a native build,
  # so adlc gets compiled with the Android target CC. Force host tools.
  sed -i 's|^BUILD_CC :=.*|BUILD_CC := /usr/bin/gcc|' "$BUILD_DIR/spec.gmk"
  sed -i 's|^BUILD_CXX :=.*|BUILD_CXX := /usr/bin/g++|' "$BUILD_DIR/spec.gmk"
  sed -i 's|^BUILD_LD :=.*|BUILD_LD := /usr/bin/gcc|' "$BUILD_DIR/spec.gmk"
  sed -i 's|^BUILD_LDCXX :=.*|BUILD_LDCXX := /usr/bin/g++|' "$BUILD_DIR/spec.gmk"
  sed -i 's|^BUILD_CFLAGS :=.*|BUILD_CFLAGS := -O2|' "$BUILD_DIR/spec.gmk"
  sed -i 's|^BUILD_CXXFLAGS :=.*|BUILD_CXXFLAGS := -O2|' "$BUILD_DIR/spec.gmk"
  sed -i 's|^BUILD_CPPFLAGS :=.*|BUILD_CPPFLAGS :=|' "$BUILD_DIR/spec.gmk"
  sed -i 's|^BUILD_LDFLAGS :=.*|BUILD_LDFLAGS :=|' "$BUILD_DIR/spec.gmk"
fi
make -C "$BUILD_DIR" JOBS="$(nproc)" images

echo "==> Picking the full JDK image"
JDK_IMAGE="$(find "$BUILD_DIR/images" -maxdepth 2 -type d -name jdk | head -n 1)"
if [ -z "$JDK_IMAGE" ] && [ "$JDK_MAJOR" = "8" ]; then
  JDK_IMAGE="$(find "$BUILD_DIR/images" -maxdepth 1 -type d -name 'j2sdk-image' | head -n 1)"
fi
test -d "$JDK_IMAGE"

# Native runtime libraries live under jre/lib/<arch> in the JDK 8 image and
# directly under lib/ for JDK 11+; JRE-facing resources (fonts, fontconfig
# database) sit in the same lib root.
LIB_ROOT="$JDK_IMAGE/lib"
NATIVE_DIR="$LIB_ROOT/$TARGET_JDK"
if [ "$JDK_MAJOR" = "8" ]; then
  LIB_ROOT="$JDK_IMAGE/jre/lib"
  NATIVE_DIR="$LIB_ROOT/$TARGET_JDK"
fi
[ -d "$NATIVE_DIR" ] || NATIVE_DIR="$LIB_ROOT"
LIBCXX_SHARED="$(find "$TOOLCHAIN/sysroot/usr/lib/$TARGET" -maxdepth 1 -name 'libc++_shared.so' 2>/dev/null | head -n 1)"
if [ -n "$LIBCXX_SHARED" ] && [ -d "$NATIVE_DIR" ]; then
  cp -f "$LIBCXX_SHARED" "$NATIVE_DIR/"
fi
# The external Android freetype build is linked by libfontmanager.
if [ -f "$FREETYPE_DIR/lib/libfreetype.so" ]; then
  if [ -d "$NATIVE_DIR" ]; then
    cp -f "$FREETYPE_DIR/lib/libfreetype.so" "$NATIVE_DIR/"
  fi
  # Older layouts keep a copy at the image root as well.
  if [ -d "$LIB_ROOT" ]; then
    cp -f "$FREETYPE_DIR/lib/libfreetype.so" "$LIB_ROOT/"
  fi
fi
# Android headless builds omit the closed fontconfig database and Lucida fonts;
# Amethyst ships them as jre_override/lib.  Carry the same files so
# java.desktop can initialise FontConfiguration (needed by Minecraft's
# Cacio agent during premain).
if [ -d "$SRC_DIR/jre_override/lib" ] && [ -d "$LIB_ROOT" ]; then
  cp -a "$SRC_DIR/jre_override/lib/." "$LIB_ROOT/"
fi

# Strip native libraries with the NDK toolchain (same as FCL/Amethyst) and run
# termux-elf-cleaner so Android's linker accepts the ELF metadata.  --strip-unneeded
# keeps the dynamic symbol table, so libjvm's exported JNI/JVM symbols stay intact.
# Runtime JDK package: keep the launcher-facing JDK (java/javac, ct.sym, modules,
# fonts, security, legal) but drop build-time only content.  jlink is therefore
# unavailable in this package by design.
rm -rf "$JDK_IMAGE/jmods" "$JDK_IMAGE/include" "$JDK_IMAGE/man" "$JDK_IMAGE/demo" "$JDK_IMAGE/sample"
rm -f "$JDK_IMAGE/src.zip" "$JDK_IMAGE/lib/src.zip"
if [ "$JDK_MAJOR" = "8" ]; then
  rm -rf "$JDK_IMAGE/jre/man" "$JDK_IMAGE/jre/demo" "$JDK_IMAGE/jre/sample"
fi

BEFORE_KB=$(du -sk "$JDK_IMAGE" | cut -f1)
if [ -x "$TOOLCHAIN/bin/llvm-strip" ]; then
  find "$JDK_IMAGE" -type f -name '*.so' -exec "$TOOLCHAIN/bin/llvm-strip" --strip-unneeded {} + 2>/dev/null || true
fi
TERMUX_ELF_CLEANER="$WORK/termux-elf-cleaner/build/termux-elf-cleaner"
if [ ! -x "$TERMUX_ELF_CLEANER" ]; then
  rm -rf "$WORK/termux-elf-cleaner"
  git clone --depth 1 https://github.com/termux/termux-elf-cleaner "$WORK/termux-elf-cleaner" >/dev/null 2>&1 || true
  if [ -d "$WORK/termux-elf-cleaner" ]; then
    ( cd "$WORK/termux-elf-cleaner" && mkdir -p build && cd build && cmake .. >/dev/null 2>&1 && make -j"$(nproc)" >/dev/null 2>&1 ) || true
  fi
fi
if [ -x "$TERMUX_ELF_CLEANER" ]; then
  find "$JDK_IMAGE" -type f -name '*.so' -exec "$TERMUX_ELF_CLEANER" --api-level 24 {} \; >/dev/null 2>&1 || true
  find "$JDK_IMAGE"/bin -type f -exec "$TERMUX_ELF_CLEANER" --api-level 24 {} \; >/dev/null 2>&1 || true
fi
AFTER_KB=$(du -sk "$JDK_IMAGE" | cut -f1)
echo "image size before/after strip: ${BEFORE_KB}KB / ${AFTER_KB}KB"

echo "==> Packing JDK image"
tar cJf "$OUT/jdk$JDK_MAJOR-android-$TARGET_SHORT.tar.xz" -C "$JDK_IMAGE" .
ls -lh "$OUT"
ls -lh "$OUT"
