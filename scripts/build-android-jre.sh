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

# clang -O3 exploits a shift-by-64 undefined behaviour in the runtime-built
# logical-immediate lookup tables: every andr with an immediate then fails and
# the VM aborts in StubRoutines::initialize1. Guard the shift in replicate().
python3 - <<'PY'
p = 'hotspot/src/cpu/aarch64/vm/immediate_aarch64.cpp'
s = open(p).read()
if 'if (nbits < 64)' not in s:
    old = '    result <<= nbits;\n'
    new = '    // A shift by the width of the type is undefined C++; clang -O3\n    // folds the whole lookup table to garbage because of it.\n    if (nbits < 64) {\n      result <<= nbits;\n    }\n'
    assert s.count(old) == 1, s.count(old)
    s = s.replace(old, new)
    open(p, 'w').write(s)
PY
# Android's allocator tags C++ heap pointers in the top byte. jdk8u's
# MacroAssembler::adrp restores the low 48 bits with adrp+movk, so a tagged
# address (e.g. Universe::heap()->top_addr()) trips the movk guarantee. Use the
# untagged address (top-byte-ignore makes it equivalent) and keep the original
# two-instruction sequence.
python3 - <<'PY'
p = 'hotspot/src/cpu/aarch64/vm/macroAssembler_aarch64.cpp'
s = open(p).read()
if '0x0000ffffffffffffUL' not in s:
    old = '    unsigned long target = (unsigned long)dest.target();\n    unsigned long adrp_target'
    new = '    unsigned long target = (unsigned long)dest.target() & 0x0000ffffffffffffUL;\n    unsigned long adrp_target'
    assert s.count(old) == 1, s.count(old)
    s = s.replace(old, new)
    open(p, 'w').write(s)
PY
grep -q '0x0000ffffffffffffUL' hotspot/src/cpu/aarch64/vm/macroAssembler_aarch64.cpp || { echo 'adrp tag mask patch did not apply'; exit 1; }
# clang assumes markOopDesc* (which inherits oopDesc's 8-byte alignment) is
# really aligned, so it constant-folds the mark-word bit tests: has_locker()
# becomes true and has_monitor() false for a neutral mark word, and inflate()
# dereferences the mark word as a BasicLock pointer. Launder the fake pointer
# through an asm barrier in value() so the real bits reach the tests.
sed -i 's|^  uintptr_t value() const { return (uintptr_t) this; }$|  uintptr_t value() const {\n    uintptr_t v = (uintptr_t) this;\n    __asm__ __volatile__("" : "+r"(v));\n    return v;\n  }|' hotspot/src/share/vm/oops/markOop.hpp
grep -q 'uintptr_t v = (uintptr_t) this;' hotspot/src/share/vm/oops/markOop.hpp || { echo 'markOop value() barrier patch did not apply'; exit 1; }
# The relocation path also rebuilds the adrp target with a movk16, and the
# target may carry an Android pointer tag in bits 48-63; mask it there too.
python3 - <<'PY'
p = 'hotspot/src/cpu/aarch64/vm/macroAssembler_aarch64.cpp'
s = open(p).read()
old = 'Instruction_aarch64::patch(branch + 4, 20, 5, (uint64_t)target >> 32);'
new = 'Instruction_aarch64::patch(branch + 4, 20, 5, ((uint64_t)target >> 32) & 0xffff);'
if old in s:
    s = s.replace(old, new)
    open(p, 'w').write(s)
PY
grep -q '((uint64_t)target >> 32) & 0xffff' hotspot/src/cpu/aarch64/vm/macroAssembler_aarch64.cpp || { echo 'adrp relocation mask patch did not apply'; exit 1; }
# An arena can be destructed after reset() has already cleared _first (e.g. a
# compiler thread tearing down twice during VM exit); guard the unconditional
# _first->chop() so shutdown does not dereference NULL.
python3 - <<'PY'
p = 'hotspot/src/share/vm/memory/allocation.cpp'
s = open(p).read()
old = '  set_size_in_bytes(0);\n  _first->chop();'
new = '  if (_first == NULL) {\n    return;\n  }\n  set_size_in_bytes(0);\n  _first->chop();'
assert s.count(old) == 1, s.count(old)
s = s.replace(old, new)
open(p, 'w').write(s)
PY
grep -q 'if (_first == NULL)' hotspot/src/share/vm/memory/allocation.cpp || { echo 'Arena destruct_contents guard did not apply'; exit 1; }
# JDK 8 has the same 48-bit inline-cache value cell; restore the Android heap
# pointer tag when a cached CompiledICHolder* is read or released.
python3 - <<'PY'
p = 'hotspot/src/share/vm/code/compiledIC.cpp'
s = open(p).read()
if 'restore_compiled_ic_pointer_tag' not in s:
    s = s.replace('#include "memory/metadataFactory.hpp"',
                  '#include "memory/allocation.hpp"\n#include "memory/metadataFactory.hpp"', 1)
    s = s.replace('#include "runtime/icache.hpp"',
                  '#include "runtime/icache.hpp"\n#include "runtime/os.hpp"', 1)
    helper = "\n// On Android the bionic allocator tags C-heap pointers in the top byte (scudo\n// heap tagging; with MTE disabled the tag is a process-wide constant, e.g.\n// 0xb4).  The inline-cache value cell for a virtual call is materialised with\n// movz+movk+movk, i.e. it can only hold 48 bits (see MacroAssembler::movptr()),\n// so a CompiledICHolder* read back from it has lost its tag.  bionic's free()\n// aborts when it sees a pointer whose tag was truncated, so restore the process\n// tag before such a holder is dereferenced or released.\n//\n// Scope: only the CompiledICHolder path is retagged.  Metadata values live\n// below the 48-bit boundary and must not be retagged, so callers must only use\n// this helper for value cells that are known to hold a CompiledICHolder*.\n// Rollback: if this ever misbehaves on a platform where heap pointers are not\n// tagged, android_heap_pointer_tag() returns 0 and the helper is a no-op.\nstatic uintptr_t android_heap_pointer_tag() {\n  static uintptr_t tag = (uintptr_t)-1;\n  if (tag == (uintptr_t)-1) {\n    // Probe once with a known C-heap allocation; 0 means tagging is disabled.\n    void* probe = os::malloc(8, mtInternal);\n    tag = (probe == NULL) ? 0 : ((uintptr_t)probe & 0xff00000000000000ULL);\n    if (probe != NULL) {\n      os::free(probe);\n    }\n  }\n  return tag;\n}\n\nstatic void* restore_compiled_ic_pointer_tag(void* value) {\n  uintptr_t v = (uintptr_t)value;\n  if (v != 0 && (v >> 48) == 0) {\n    v |= android_heap_pointer_tag();\n  }\n  return (void*)v;\n}\n"
    anchor = '// Every time a compiled IC is changed or its type is being accessed,'
    assert s.count(anchor) == 1
    s = s.replace(anchor, helper + '\n' + anchor, 1)
    old = '    void* data = (void*)_value->data();'
    new = '    void* data = (void*)_value->data();\n    if (is_icholder_call()) {\n      data = restore_compiled_ic_pointer_tag(data);\n    }'
    assert s.count(old) == 1, s.count(old)
    s = s.replace(old, new)
    old2 = '    InlineCacheBuffer::queue_for_release((CompiledICHolder*)_value->data());'
    new2 = '    InlineCacheBuffer::queue_for_release(\n        (CompiledICHolder*)restore_compiled_ic_pointer_tag((void*)_value->data()));'
    assert s.count(old2) == 1
    s = s.replace(old2, new2)
    open(p, 'w').write(s)
PY
grep -q 'restore_compiled_ic_pointer_tag' hotspot/src/share/vm/code/compiledIC.cpp || { echo 'jdk8 compiledIC tag fix did not apply'; exit 1; }
# Hotspot defaults to clang PCH, which passes gcc-only -fpch-deps to clang.
sed -i 's/^      USE_PRECOMPILED_HEADER=1$/      USE_PRECOMPILED_HEADER=0/' hotspot/make/linux/makefiles/gcc.make
# USE_CLANG is empty with our gcc-disguised clang, so drop the GCC-only dep flag.
sed -i '/DEPFLAGS += -fpch-deps/d' hotspot/make/linux/makefiles/gcc.make
# The serviceability agent relies on glibc/thread_db and is not needed in a JRE.
sed -i 's|^include $(MAKEFILES_DIR)/saproc.make$|# saproc is not buildable against bionic; skip it for Android JRE|' hotspot/make/linux/makefiles/vm.make
sed -i 's|^build: $(LIBJVM) $(LAUNCHER) $(LIBJSIG) $(LIBJVM_DB) $(BUILDLIBSAPROC) dtraceCheck$|build: $(LIBJVM) $(LAUNCHER) $(LIBJSIG) $(LIBJVM_DB) dtraceCheck|' hotspot/make/linux/makefiles/vm.make
sed -i 's|^install: install_jvm install_jsig install_saproc$|install: install_jvm install_jsig|' hotspot/make/linux/makefiles/vm.make
sed -i '/^ADD_SA_BINARIES\/aarch64 = /,+1d' hotspot/make/linux/makefiles/defs.make
sed -i '/^[[:space:]]*ADD_SA_BINARIES\/aarch64 += /d' hotspot/make/linux/makefiles/defs.make
echo 'ADD_SA_BINARIES/aarch64 =' >> hotspot/make/linux/makefiles/defs.make

# bionic at API 21 has no mbrtoc32/c32rtomb and char16_t/char32_t are C++
# keywords, so patch the generated tinyiconv source for our toolchain.
python3 - <<'PY'
p = 'jdk/src/share/tinyiconv/iconv.cpp'
s = open(p).read()
if 'tiny_mbrtoc32' not in s:
    s = s.replace('typedef uint32_t char32_t;\ntypedef uint16_t char16_t;\n',
                  '#ifndef __cplusplus\ntypedef uint32_t char32_t;\ntypedef uint16_t char16_t;\n#endif\n')
    helpers = '''
// bionic does not expose the C11 char32 conversion helpers at API 21, so
// provide a minimal UTF-8 implementation for the iconv shim.
static size_t tiny_mbrtoc32(char32_t* pc32, const char* s, size_t n, mbstate_t* ps) {
  (void)ps;
  if (n == 0) {
    errno = EINVAL;
    return __MB_ERR_INCOMPLETE_SEQUENCE;
  }
  const unsigned char* p = (const unsigned char*)s;
  unsigned char b0 = p[0];
  if (b0 < 0x80) {
    if (pc32 != nullptr) *pc32 = b0;
    return 1;
  }
  size_t len;
  char32_t cp;
  if ((b0 & 0xe0) == 0xc0) { len = 2; cp = b0 & 0x1f; }
  else if ((b0 & 0xf0) == 0xe0) { len = 3; cp = b0 & 0x0f; }
  else if ((b0 & 0xf8) == 0xf0) { len = 4; cp = b0 & 0x07; }
  else { errno = EILSEQ; return __MB_ERR_ILLEGAL_SEQUENCE; }
  if (n < len) { errno = EINVAL; return __MB_ERR_INCOMPLETE_SEQUENCE; }
  for (size_t i = 1; i < len; i++) {
    unsigned char b = p[i];
    if ((b & 0xc0) != 0x80) { errno = EILSEQ; return __MB_ERR_ILLEGAL_SEQUENCE; }
    cp = (cp << 6) | (b & 0x3f);
  }
  if ((len == 2 && cp < 0x80) || (len == 3 && cp < 0x800) ||
      (len == 4 && cp < 0x10000) || cp > 0x10ffff ||
      (cp >= 0xd800 && cp <= 0xdfff)) {
    errno = EILSEQ;
    return __MB_ERR_ILLEGAL_SEQUENCE;
  }
  if (pc32 != nullptr) *pc32 = cp;
  return len;
}

static size_t tiny_c32rtomb(char* s, char32_t c32, mbstate_t* ps) {
  (void)ps;
  if (c32 > 0x10ffff || (c32 >= 0xd800 && c32 <= 0xdfff)) {
    errno = EILSEQ;
    return __MB_ERR_ILLEGAL_SEQUENCE;
  }
  if (c32 < 0x80) {
    s[0] = (char)c32;
    return 1;
  }
  if (c32 < 0x800) {
    s[0] = (char)(0xc0 | (c32 >> 6));
    s[1] = (char)(0x80 | (c32 & 0x3f));
    return 2;
  }
  if (c32 < 0x10000) {
    s[0] = (char)(0xe0 | (c32 >> 12));
    s[1] = (char)(0x80 | ((c32 >> 6) & 0x3f));
    s[2] = (char)(0x80 | (c32 & 0x3f));
    return 3;
  }
  s[0] = (char)(0xf0 | (c32 >> 18));
  s[1] = (char)(0x80 | ((c32 >> 12) & 0x3f));
  s[2] = (char)(0x80 | ((c32 >> 6) & 0x3f));
  s[3] = (char)(0x80 | (c32 & 0x3f));
  return 4;
}
'''
    s = s.replace('mbrtoc32(', 'tiny_mbrtoc32(').replace('c32rtomb(', 'tiny_c32rtomb(')
    anchor = '#include "bionic_mbstate.h"\n'
    s = s.replace(anchor, anchor + helpers, 1)
    open(p, 'w').write(s)
PY

# clang -O3 inlines and discards ArrayAllocator<bm_word_t, mtInternal>::free()
# from bitMap.o, but other translation units reference it out of line. Force an
# out-of-line definition so libjvm resolves it without a lazy C++ symbol.
cat >> hotspot/src/share/vm/utilities/bitMap.cpp <<'EOF'

// Android/clang: emit an out-of-line definition for TUs that only see the
// declaration of ArrayAllocator::free().
template void ArrayAllocator<BitMap::bm_word_t, mtInternal>::free();
EOF

echo "==> Preparing toolchain headers"
ln -sfn /usr/include/X11 "$TOOLCHAIN/sysroot/usr/include/X11"
ln -sfn /usr/include/alsa "$TOOLCHAIN/sysroot/usr/include/alsa"
mkdir -p "$TOOLCHAIN/sysroot/usr/include/fontconfig"
cp -R /usr/include/fontconfig/. "$TOOLCHAIN/sysroot/usr/include/fontconfig/"
ln -sfn "$WORK/cups-$CUPS_VERSION/cups" "$TOOLCHAIN/sysroot/usr/include/cups"

cat > "$WORK/android-wrapped-clang" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then
  echo "$TARGET-gcc (GCC) 5.4.0 20160609 (prerelease)"
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
  echo "$TARGET-g++ (GCC) 5.4.0 20160609 (prerelease)"
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
for lib in pthread rt thread_db asound pulse supc++; do
  rm -f "$WORK/dummy_libs/lib$lib.a"
  "$TOOLCHAIN/bin/llvm-ar" cru "$WORK/dummy_libs/lib$lib.a"
done

# The NDK clang driver adds its own sysroot; do not leak the target include
# path into the environment because it also affects host build tools.
# clang -O3 miscompiles hotspot (e.g. ObjectSynchronizer::inflate drops the
# mark-word bit tests and dereferences a neutral mark word as a pointer). The
# extra flags are appended after hotspot's own OPT_CFLAGS, so -O2 here wins.
export CFLAGS="-DLE_STANDALONE -O2 -D__ANDROID__"
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
  --disable-precompiled-headers \
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
# The serviceability agent is disabled, but the image rules still expect its
# jar; an empty placeholder keeps the JDK image step happy (it is not part of
# the JRE image).
mkdir -p "$BUILD_DIR/jdk/lib"
: > "$BUILD_DIR/jdk/lib/sa-jdi.jar"

# Keep the target compiler flags out of the host tool builds.
unset CFLAGS CXXFLAGS LDFLAGS
# Hotspot enables PCH by default unless USE_PRECOMPILED_HEADER=0 is passed to make.
make -C "$BUILD_DIR" JOBS="$(nproc)" USE_PRECOMPILED_HEADER=0 images

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
