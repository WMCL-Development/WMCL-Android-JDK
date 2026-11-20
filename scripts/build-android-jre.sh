#!/usr/bin/env bash
# Build an Android aarch64 JRE from OpenJDK 17u (latest GA) with the
# Amethyst Android patch set as the starting point.
#
# OpenJDK runtime: GPLv2+CE. Our build tooling: Apache-2.0.
# Android patches are downloaded at build time from a pinned Amethyst commit.
set -eo pipefail
JDK_REPO="openjdk/jdk8u"
JDK_MAJOR="8"

JDK_VERSION="jdk8u514-ga"
JDK_TAG="jdk8u514-ga"
PATCH_REPO="AngelAuraMC/angelauramc-openjdk-build"
PATCH_COMMIT="196da32d80fe96d6967ca1c154f102cff0dfc389"
PATCH_DIR="patches/jre_17/android"

TARGET="aarch64-linux-android"
TARGET_JDK="aarch64"
TARGET_SHORT="arm64"
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

echo "==> Downloading Amethyst Android patches @ f03a5a05d76394bc3e91317e9ff4b8c21e5cb802"
rm -rf "$PATCH_REPO_DIR"
mkdir -p "$PATCH_REPO_DIR"
curl -fL --retry 3 -o "$PATCH_REPO_DIR/patches.tar.gz" "https://github.com/AngelAuraMC/angelauramc-openjdk-build/archive/f03a5a05d76394bc3e91317e9ff4b8c21e5cb802.tar.gz"
tar xf "$PATCH_REPO_DIR/patches.tar.gz" -C "$PATCH_REPO_DIR"
SRC_DIR="$(find "$PATCH_REPO_DIR" -maxdepth 1 -type d -name 'angelauramc-openjdk-build-*' | head -n 1)"

echo "==> Applying Android patches"
for NAME in jdk8u_android.diff jdk8u_android_main.diff; do
  patch="$SRC_DIR/patches/$NAME"
  if git apply --reject --whitespace=fix "$patch"; then continue; fi
  # 8u514 has drifted from the 8u482 baseline these patches target. The only
  # rejects are two small autoconf hunks; re-apply their intent by hand.
  bad="$(find . -name '*.rej' -print | grep -vE '(^\./common/autoconf/(flags\.m4|version-numbers)\.rej$)|(^\./common/autoconf/build-aux/config\.sub\.rej$)' || true)"
  if [ -n "$bad" ]; then echo "Unresolved rejects from $NAME:"; echo "$bad"; exit 1; fi
  if [ -f common/autoconf/flags.m4.rej ]; then
    # Build JDK 8 with C++11 (context around the hunk changed upstream).
    sed -i 's/-std=gnu++98/-std=gnu++11/' common/autoconf/flags.m4
  fi
  if [ -f common/autoconf/version-numbers.rej ]; then
    # Android runtime branding (JDK_UPDATE_VERSION context changed upstream).
    sed -i 's/^PRODUCT_SUFFIX="Runtime Environment"$/PRODUCT_SUFFIX="Android Runtime Environment"/' common/autoconf/version-numbers
  fi
  find . -name '*.rej' -delete
  find . -name '*.orig' -delete
  echo "note: re-applied drifted autoconf hunks from $NAME"
done

echo "==> Preparing toolchain headers"
ln -sfn /usr/include/X11 "$TOOLCHAIN/sysroot/usr/include/X11"
ln -sfn /usr/include/alsa "$TOOLCHAIN/sysroot/usr/include/alsa"
mkdir -p "$TOOLCHAIN/sysroot/usr/include/fontconfig"
cp -R /usr/include/fontconfig/. "$TOOLCHAIN/sysroot/usr/include/fontconfig/"
ln -sfn "$WORK/cups-$CUPS_VERSION/cups" "$TOOLCHAIN/sysroot/usr/include/cups"

cat > "$WORK/android-wrapped-clang" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then
  echo "$TARGET-gcc (GCC) 4.9 20140827 (prerelease)"
  echo "Copyright (C) 2014 Free Software Foundation, Inc."
  echo "This is free software; see the source for copying conditions.  There is NO"
  echo "warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE."
  exit 0
fi
exec "$TOOLCHAIN/bin/$TARGET$API-clang" -Wno-unknown-warning-option "\$@"
EOF
cat > "$WORK/android-wrapped-clang++" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then
  echo "$TARGET-g++ (GCC) 4.9 20140827 (prerelease)"
  echo "Copyright (C) 2014 Free Software Foundation, Inc."
  echo "This is free software; see the source for copying conditions.  There is NO"
  echo "warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE."
  exit 0
fi
exec "$TOOLCHAIN/bin/$TARGET$API-clang++" -Wno-unknown-warning-option "\$@"
EOF
chmod +x "$WORK/android-wrapped-clang" "$WORK/android-wrapped-clang++"

export PATH="$TOOLCHAIN/bin:$PATH"
mkdir -p "$WORK/dummy_libs"
for lib in pthread rt thread_db asound pulse; do
  rm -f "$WORK/dummy_libs/lib$lib.a"
  "$TOOLCHAIN/bin/llvm-ar" cru "$WORK/dummy_libs/lib$lib.a"
done

export CFLAGS="-DLE_STANDALONE -O3 -D__ANDROID__ -I$TOOLCHAIN/sysroot/usr/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$WORK/dummy_libs -Wl,--undefined-version"
# JDK 8 configure insists on a gcc toolchain, so route the Android clang
# through wrappers that report a GCC version string.
export CC="$WORK/android-wrapped-clang"
export CXX="$WORK/android-wrapped-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export AS="$TOOLCHAIN/bin/llvm-as"
export LD="$TOOLCHAIN/bin/ld"
export NM="$TOOLCHAIN/bin/llvm-nm"
export OBJCOPY="$TOOLCHAIN/bin/llvm-objcopy"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"

echo "==> Configuring OpenJDK $JDK_VERSION for $TARGET"
if ! bash ./configure \
  --openjdk-target="$TARGET" \
  --with-toolchain-type=gcc \
  --with-extra-cflags="$CFLAGS" \
  --with-extra-cxxflags="$CXXFLAGS" \
  --with-extra-ldflags="$LDFLAGS" \
  --enable-option-checking=fatal \
  --with-jdk-variant=normal \
  --with-jvm-variants="$JVM_VARIANTS" \
  --with-cups-include="$WORK/cups-$CUPS_VERSION" \
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
make -C "$BUILD_DIR" JOBS="$(nproc)" images

echo "==> Creating JRE image"
JDK_IMAGE="$(find "$BUILD_DIR/images" -maxdepth 2 -type d -name jdk | head -n 1)"
test -d "$JDK_IMAGE"
if [ "$JDK_MAJOR" = "8" ]; then
  JRE_IMAGE="$(find "$BUILD_DIR/images" -maxdepth 1 -type d -name 'j2re-image' | head -n 1)"
  test -d "$JRE_IMAGE"
else
  JRE_IMAGE="$WORK/jre-$JDK_MAJOR-image"
  rm -rf "$JRE_IMAGE"
  MODULE_PATH="$JDK_IMAGE/jmods"
  if [ ! -d "$MODULE_PATH" ]; then MODULE_PATH="$BUILD_DIR/jmods"; fi
  "$JAVA_HOME/bin/jlink"     --module-path "$MODULE_PATH"     --add-modules java.base,java.compiler,java.datatransfer,java.desktop,java.instrument,java.logging,java.management,java.management.rmi,java.naming,java.net.http,java.prefs,java.rmi,java.scripting,java.se,java.security.jgss,java.security.sasl,java.sql,java.sql.rowset,java.transaction.xa,java.xml,java.xml.crypto,jdk.accessibility,jdk.charsets,jdk.crypto.cryptoki,jdk.crypto.ec,jdk.dynalink,jdk.httpserver,jdk.jdwp.agent,jdk.jfr,jdk.jsobject,jdk.localedata,jdk.management,jdk.management.agent,jdk.management.jfr,jdk.naming.dns,jdk.naming.rmi,jdk.net,jdk.nio.mapmode,jdk.sctp,jdk.security.auth,jdk.security.jgss,jdk.unsupported,jdk.xml.dom,jdk.zipfs     --output "$JRE_IMAGE"     --no-man-pages     --no-header-files     --release-info="$JDK_IMAGE/release"     --compress=0
fi
if [ -f "$FREETYPE_DIR/lib/libfreetype.so" ]; then
  cp -f "$FREETYPE_DIR/lib/libfreetype.so" "$JRE_IMAGE/lib/"
fi

echo "==> Packing JRE"
tar cJf "$OUT/jre$JDK_MAJOR-android-$TARGET_SHORT.tar.xz" -C "$JRE_IMAGE" .
ls -lh "$OUT"
