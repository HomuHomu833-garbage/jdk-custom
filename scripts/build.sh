#!/usr/bin/env bash
# Cross-build a custom OpenJDK for one target. Driven by env vars so it runs
# identically in CI and in `docker run`. Run fetch-source.sh first; this script
# recomputes the same SRC / BOOT_JDK paths from $ROOTDIR (no state file).
#
#   PLATFORM        linux | bsd | windows | macos | android  (selects the toolchain)
#   TARGET          target triple (e.g. x86_64-linux-musl, aarch64-linux-gnu,
#                   aarch64-freebsd-none, aarch64-linux-android, arm64-apple-darwin,
#                   x86_64-w64-mingw32)
#   JDK_VERSION     feature version: 8 | 11 | 17 | 21 | 25
#   ROOTDIR         checkout root (default: cwd)
#   NDK_VERSION/NDK_REVISION  official NDK for the android clang (android only)
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${PLATFORM:?set PLATFORM}" "${TARGET:?set TARGET}" "${JDK_VERSION:?set JDK_VERSION}"
SRC="${SRC:-$ROOTDIR/jdk-src}"
BOOT_JDK="${BOOT_JDK:-$ROOTDIR/boot-jdk}"
ARCH="${TARGET%%-*}"
BUILD_DIR="$ROOTDIR/build"
INSTALL_DIR="$ROOTDIR/install"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

[ -x "$BOOT_JDK/bin/javac" ] || { echo "boot JDK not found at $BOOT_JDK (run fetch-source.sh)" >&2; exit 1; }
[ -d "$SRC" ] || { echo "source tree not found at $SRC (run fetch-source.sh)" >&2; exit 1; }

if [ -d "$INSTALL_DIR/$JDK_VERSION-$TARGET" ]; then
    log "JDK $JDK_VERSION already built for $TARGET"; exit 0
fi

# --- HotSpot variant by target CPU ------------------------------------------
# HotSpot ships an optimized JIT/template interpreter only for a fixed CPU set;
# everything else falls back to the portable Zero interpreter so the build still
# yields a runnable JDK. loongarch64 has an upstream HotSpot port from 21 on.
case "$ARCH" in
  aarch64|aarch64_be|arm|arm64|arm64e|armeb|armhf|armv7a|i686|powerpc64|powerpc64le|ppc64|ppc64le|riscv64|s390x|thumb|thumbeb|x86|x86_64|x86_64h)
    JVM_VARIANT=server ;;
  loongarch64)
    if [ "$JDK_VERSION" -ge 21 ] 2>/dev/null; then JVM_VARIANT=server; else JVM_VARIANT=zero; fi ;;
  mips|mipsel|mips64|mips64el)
    if [ "$JDK_VERSION" -le 15 ] 2>/dev/null; then JVM_VARIANT=server; else JVM_VARIANT=zero; fi ;;
  *)
    JVM_VARIANT=zero ;;
esac

# --- per-platform toolchain -------------------------------------------------
# Dispatch on PLATFORM (not the triple) so the toolchain is chosen explicitly.
# CC/CXX/AR/NM/STRIP/OBJCOPY are exported; OpenJDK's configure picks them up for
# the target. SYSROOT is left empty for the zig wrappers (zig cc carries its own
# libc/sysroot); the NDK / osxcross / llvm-mingw wrappers likewise self-resolve.
EXTRA_CONF=()
TARGET_OS=""
case "$PLATFORM" in
  linux)
    # Linux (musl/gnu) via zig-as-llvm. Overlay the musl libc source fixes.
    TC=/opt/zig-as-llvm
    [ -d "$ROOTDIR/patches/zig" ] && cp -R "$ROOTDIR/patches/zig/." /opt/zig/ || true
    export ZIG_TARGET="$TARGET"
    export CC="$TC/bin/cc" CXX="$TC/bin/c++"
    export AR="$TC/bin/ar" NM="$TC/bin/nm" STRIP="$TC/bin/strip" OBJCOPY="$TC/bin/objcopy"
    TARGET_OS=linux
    # musl links the JDK launchers fully static-libc; glibc keeps libc dynamic.
    case "$TARGET" in
      *musl*) EXTRA_CONF+=(--with-extra-ldflags=-static-libgcc) ;;
    esac
    ;;
  bsd)
    # BSD via the same zig-as-llvm wrappers; the triple's OS field drives the
    # *BSD code paths in HotSpot/libjava.
    TC=/opt/zig-as-llvm
    [ -d "$ROOTDIR/patches/zig" ] && cp -R "$ROOTDIR/patches/zig/." /opt/zig/ || true
    export ZIG_TARGET="$TARGET"
    export CC="$TC/bin/cc" CXX="$TC/bin/c++"
    export AR="$TC/bin/ar" NM="$TC/bin/nm" STRIP="$TC/bin/strip" OBJCOPY="$TC/bin/objcopy"
    case "$(echo "$TARGET" | cut -d- -f2)" in
      freebsd) TARGET_OS=bsd ;;
      netbsd)  TARGET_OS=bsd ;;
      openbsd) TARGET_OS=bsd ;;
      *)       TARGET_OS=bsd ;;
    esac
    ;;
  windows)
    # Windows via llvm-mingw. Note: upstream OpenJDK officially targets MSVC; the
    # mingw path is experimental and leans on the patches/global/jdk fixups.
    TC=/opt/llvm-mingw
    export CC="$TC/bin/${TARGET}-clang" CXX="$TC/bin/${TARGET}-clang++"
    export AR="$TC/bin/${TARGET}-ar" NM="$TC/bin/${TARGET}-nm"
    export STRIP="$TC/bin/${TARGET}-strip" OBJCOPY="$TC/bin/${TARGET}-objcopy"
    export RC="$TC/bin/${TARGET}-windres"
    TARGET_OS=windows
    ;;
  macos)
    # macOS via osxcross (cctools-port + clang wrappers carrying the SDK sysroot);
    # upstream officially targets Xcode/clang, this mirrors that with osxcross.
    TC=/opt/osxcross
    export PATH="$TC/bin:$PATH"
    case "$TARGET" in
      arm64e-*)          OSX_ARCH=arm64e ;;
      arm64-*|aarch64-*) OSX_ARCH=arm64 ;;
      x86_64h-*)         OSX_ARCH=x86_64h ;;
      x86_64-*)          OSX_ARCH=x86_64 ;;
      *) echo "Unsupported macOS arch in TARGET='$TARGET'" >&2; exit 1 ;;
    esac
    CCWRAP="$(ls "$TC/bin/${OSX_ARCH}-apple-darwin"*-clang 2>/dev/null | head -n1 || true)"
    [ -n "$CCWRAP" ] || { echo "osxcross clang wrapper for $OSX_ARCH not found" >&2; exit 1; }
    HOST="$(basename "${CCWRAP%-clang}")"
    export CC="$TC/bin/${HOST}-clang" CXX="$TC/bin/${HOST}-clang++"
    export AR="$TC/bin/${HOST}-ar" STRIP="$TC/bin/${HOST}-strip"
    export NM="$TC/bin/${HOST}-nm"
    TARGET_OS=macosx
    SDKROOT="$(ls -d "$TC/SDK/MacOSX"*.sdk 2>/dev/null | head -n1 || true)"
    [ -n "$SDKROOT" ] && EXTRA_CONF+=(--with-sysroot="$SDKROOT")
    EXTRA_CONF+=(--with-macosx-version-max=11.00.00)
    ;;
  android)
    # Android (bionic) via the official NDK clang, so the JDK runs on-device
    # (e.g. Termux). HotSpot has no bionic port, so every Android target is Zero.
    : "${NDK_VERSION:?set NDK_VERSION for the android build}"
    NDK_REVISION="${NDK_REVISION:-}"
    JVM_VARIANT=zero
    API="${ANDROID_PLATFORM:-26}"; [ "$TARGET" = riscv64-linux-android ] && API=35
    NDK_NAME="android-ndk-r${NDK_VERSION}${NDK_REVISION}"
    NDK_DIR="$ROOTDIR/$NDK_NAME"
    if [ ! -d "$NDK_DIR" ]; then
      log "Downloading official NDK ($NDK_NAME)"
      aria2c --console-log-level=error --check-certificate=false --max-tries=5 \
        --dir="$ROOTDIR" -o ndk.zip "https://dl.google.com/android/repository/${NDK_NAME}-linux.zip"
      unzip -qq "$ROOTDIR/ndk.zip" -d "$ROOTDIR"; rm -f "$ROOTDIR/ndk.zip"
    fi
    TC="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
    export CC="$TC/bin/${TARGET}${API}-clang" CXX="$TC/bin/${TARGET}${API}-clang++"
    export AR="$TC/bin/llvm-ar" NM="$TC/bin/llvm-nm"
    export STRIP="$TC/bin/llvm-strip" OBJCOPY="$TC/bin/llvm-objcopy"
    TARGET_OS=linux
    ;;
  *) echo "Unknown/unsupported PLATFORM='$PLATFORM'" >&2; exit 1 ;;
esac

# --- configure --------------------------------------------------------------
CONF="custom-$TARGET"
IMAGE_DIR="$SRC/build/$CONF/images/jdk"

# Flags common to every modern (11+) configure. Bundled libs keep the build
# self-contained per target; headless-only drops the X11/CUPS desktop deps.
common_conf=(
  --openjdk-target="$TARGET"
  --with-boot-jdk="$BOOT_JDK"
  --with-build-jdk="$BOOT_JDK"
  --with-jvm-variants="$JVM_VARIANT"
  --with-debug-level=release
  --with-native-debug-symbols=none
  --disable-warnings-as-errors
  --enable-headless-only
  --with-vendor-name=jdk-custom
  --with-vendor-url=https://github.com/HomuHomu833/jdk-custom
  --with-build-user=builder
  --with-freetype=bundled
  --with-libpng=bundled
  --with-giflib=bundled
  --with-libjpeg=bundled
  --with-lcms=bundled
  --with-zlib=bundled
  --with-conf-name="$CONF"
)

log "Configuring JDK $JDK_VERSION for $TARGET ($JVM_VARIANT, $TARGET_OS)"
cd "$SRC"
if [ "$JDK_VERSION" = 8 ]; then
  # jdk8u: legacy build system — no bundled-lib toggles, no headless-only flag,
  # variant is selected via --with-jvm-variants too but the option set is smaller.
  # --enable-unlimited-crypto: ship the unlimited-strength JCE policy (default on
  # 11+, but opt-in on 8) so full-strength ciphers work out of the box.
  bash ./configure \
    --openjdk-target="$TARGET" \
    --with-boot-jdk="$BOOT_JDK" \
    --with-jvm-variants="$JVM_VARIANT" \
    --with-debug-level=release \
    --disable-debug-symbols \
    --disable-warnings-as-errors \
    --enable-unlimited-crypto \
    --with-vendor-name=jdk-custom \
    --with-build-user=builder \
    "${EXTRA_CONF[@]}"
  CONF8="$(ls -d "$SRC"/build/*/ 2>/dev/null | head -n1)"
  IMAGE_DIR="${CONF8%/}/images/j2sdk-image"
else
  bash ./configure "${common_conf[@]}" "${EXTRA_CONF[@]}"
fi

# --- build ------------------------------------------------------------------
log "Building (make images)"
if [ "$JDK_VERSION" = 8 ]; then
  make images
else
  make CONF="$CONF" images
fi

[ -d "$IMAGE_DIR" ] || { echo "expected JDK image not found at $IMAGE_DIR" >&2; exit 1; }

log "Staging install tree"
mkdir -p "$INSTALL_DIR/$JDK_VERSION-$TARGET"
cp -R "$IMAGE_DIR"/. "$INSTALL_DIR/$JDK_VERSION-$TARGET"
log "Done -> $INSTALL_DIR/$JDK_VERSION-$TARGET"
