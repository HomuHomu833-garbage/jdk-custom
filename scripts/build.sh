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
  i686|x86)
    # 25 dropped the 32-bit x86 JIT: basic.m4 errors out with "32-bit x86 builds
    # are not supported" unless the variant is zero. Older releases still have it.
    if [ "$JDK_VERSION" -ge 25 ] 2>/dev/null; then JVM_VARIANT=zero; else JVM_VARIANT=server; fi ;;
  aarch64|aarch64_be|arm|arm64|arm64e|armeb|armhf|armv7a|powerpc64|powerpc64le|ppc64|ppc64le|riscv64|s390x|thumb|thumbeb|x86_64|x86_64h)
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
# CC/CXX are exported; AR/NM/STRIP/OBJCOPY are passed as configure variables
# because configure ignores them from the environment during cross-compilation
# and looks for target-prefixed names instead. SYSROOT is left empty for the zig
# wrappers (zig cc carries its own
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
    EXTRA_CONF+=(AR="$TC/bin/ar" NM="$TC/bin/nm" STRIP="$TC/bin/strip" OBJCOPY="$TC/bin/objcopy" OBJDUMP="$TC/bin/objdump")
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
    EXTRA_CONF+=(AR="$TC/bin/ar" NM="$TC/bin/nm" STRIP="$TC/bin/strip" OBJCOPY="$TC/bin/objcopy" OBJDUMP="$TC/bin/objdump")
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
    EXTRA_CONF+=(AR="$TC/bin/${TARGET}-ar" NM="$TC/bin/${TARGET}-nm" STRIP="$TC/bin/${TARGET}-strip" OBJCOPY="$TC/bin/${TARGET}-objcopy" OBJDUMP="$TC/bin/${TARGET}-objdump")
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
    EXTRA_CONF+=(AR="$TC/bin/${HOST}-ar" NM="$TC/bin/${HOST}-nm" STRIP="$TC/bin/${HOST}-strip" OBJDUMP="$TC/bin/${HOST}-objdump")
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
    # API 28 (Android 9) is the floor: os_posix.cpp calls posix_spawn(), which
    # bionic only declares from 28 on (__INTRODUCED_IN(28) in <spawn.h>).
    # Overridable via ANDROID_PLATFORM; note getloadavg() needs 29, which the
    # sysinfo patch covers below that.
    API="${ANDROID_PLATFORM:-28}"; [ "$TARGET" = riscv64-linux-android ] && API=35
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
    EXTRA_CONF+=(--with-toolchain-type=clang AR="$TC/bin/llvm-ar" NM="$TC/bin/llvm-nm" STRIP="$TC/bin/llvm-strip" OBJCOPY="$TC/bin/llvm-objcopy" OBJDUMP="$TC/bin/llvm-objdump")
    TARGET_OS=linux
    ;;
  *) echo "Unknown/unsupported PLATFORM='$PLATFORM'" >&2; exit 1 ;;
esac

# --- tell configure what the build machine is -------------------------------
# config.guess probes the *build* system's libc by compiling with $CC, and $CC is
# a cross compiler here — so it reports the builder as whatever we are targeting:
# "x86_64-pc-linux-android" for the android targets, "...-androidx32" for the
# 32-bit arm one. That is wrong everywhere, and actively breaks any target whose
# CPU matches the builder: for x86_64-linux-android the bogus build triple equals
# the host triple, configure concludes "compilation type... native", and host
# build tools such as adlc get compiled with the NDK compiler — producing android
# binaries the build itself then tries to run ("adlc: cannot execute: required
# file not found"). Pass the real build triple so COMPILE_TYPE and every
# OPENJDK_BUILD_* value are derived correctly.
BUILD_TRIPLE="$(gcc -dumpmachine 2>/dev/null || clang -dumpmachine 2>/dev/null || true)"
[ -n "$BUILD_TRIPLE" ] || { echo "cannot determine the build triple (no gcc/clang?)" >&2; exit 1; }
EXTRA_CONF+=(--build="$BUILD_TRIPLE")

# --- drop ALSA --------------------------------------------------------------
# OpenJDK demands ALSA for every OPENJDK_TARGET_OS=linux build and links its sound
# native lib against -lasound, so configure dies with "Could not find alsa!" —
# none of the cross sysroots here carry ALSA, and bionic has no ALSA at all.
# Termux works around this by packaging alsa-lib for Android and pointing
# configure at it; with no equivalent sysroot for any target, sound is dropped
# from the linux/android builds instead. macOS and Windows keep their native
# sound (CoreAudio / DirectSound, never ALSA) and the BSDs never needed it, so
# only TARGET_OS=linux is touched. com.sun.media.sound.Platform loads the native
# lib in a try/catch(Throwable), so javax.sound reports no devices instead of
# breaking java.desktop; the pure-Java parts (software synth, file readers) are
# unaffected. Edits go into the fetched source tree and are keyed to text that is
# stable across the supported feature versions.
if [ "$TARGET_OS" = linux ]; then
  log "Dropping the ALSA dependency (no cross sysroot here ships ALSA)"
  if [ "$JDK_VERSION" = 8 ]; then
    # 8: ALSA lives in its own libjsoundalsa, pulled in only when the makefile
    # adds jsoundalsa to EXTRA_SOUND_JNI_LIBS — drop that and the core libjsound
    # still builds. 8 is also the one version shipping a checked-in
    # generated-configure.sh, so ALSA_NOT_NEEDED goes into it as well as the .m4.
    SND_GMK="$SRC/jdk/make/lib/SoundLibraries.gmk"
    grep -q 'EXTRA_SOUND_JNI_LIBS += jsoundalsa' "$SND_GMK" 2>/dev/null || {
      echo "unexpected $SND_GMK: no jsoundalsa to drop" >&2; exit 1; }
    for f in "$SRC/common/autoconf/libraries.m4" "$SRC/common/autoconf/generated-configure.sh"; do
      [ -f "$f" ] || continue
      # The linux block only disables pulse; disable alsa right alongside it. The
      # other OS blocks that set PULSE_NOT_NEEDED already disable alsa too, so
      # matching all of them is harmless.
      sed -i 's/^\([[:space:]]*\)PULSE_NOT_NEEDED=yes$/\1PULSE_NOT_NEEDED=yes\n\1ALSA_NOT_NEEDED=yes/' "$f"
    done
    sed -i '/EXTRA_SOUND_JNI_LIBS += jsoundalsa/d' "$SND_GMK"
  else
    # 11+: configure regenerates from the .m4 via autoconf (no checked-in
    # generated-configure.sh since 11), so clearing NEEDS_LIB_ALSA is enough.
    ALSA_M4="$SRC/make/autoconf/libraries.m4"
    grep -qE 'NEEDS_LIB_ALSA=(true|false)' "$ALSA_M4" || {
      echo "unexpected $ALSA_M4: no NEEDS_LIB_ALSA to disable" >&2; exit 1; }
    sed -i 's/NEEDS_LIB_ALSA=true/NEEDS_LIB_ALSA=false/' "$ALSA_M4"

    # Then skip libjsound itself, as AIX already does: its ALSA sources include
    # <alsa/asoundlib.h> and call snd_* outside the USE_* guards, so the library
    # cannot be built at all without ALSA headers. 11 keeps the rules in
    # make/lib/, 17+ in make/modules/; both open the block with the same
    # `ifeq ($(call isTargetOs, aix), false)` line, matched via the
    # LIBJSOUND_CFLAGS that follows it so no other ifeq is hit.
    JSOUND_GMK="$SRC/make/modules/java.desktop/Lib.gmk"
    [ -f "$JSOUND_GMK" ] || JSOUND_GMK="$SRC/make/lib/Lib-java.desktop.gmk"
    [ -f "$JSOUND_GMK" ] || { echo "libjsound makefile not found under $SRC/make" >&2; exit 1; }
    if ! grep -q 'drop-alsa' "$JSOUND_GMK"; then
      awk '
        { line[NR] = $0 }
        /^ifeq \(\$\(call isTargetOs, aix\), false\)$/ { guard = NR }
        /LIBJSOUND_CFLAGS/ && guard && !target { target = guard }
        END {
          if (!target) exit 1
          for (i = 1; i <= NR; i++) print (i == target ? "ifeq (drop-alsa, keep-alsa)" : line[i])
        }
      ' "$JSOUND_GMK" > "$JSOUND_GMK.tmp" || {
        echo "unexpected $JSOUND_GMK: libjsound guard not found" >&2; exit 1; }
      mv "$JSOUND_GMK.tmp" "$JSOUND_GMK"
    fi
  fi
fi

# --- bionic link stubs ------------------------------------------------------
# configure puts -lpthread and -lrt on the link line (libraries.m4: LIBPTHREAD,
# and the librt entry in BASIC_JVM_LIBS), and jdk8's makefiles hardcode -lpthread
# in several more places. bionic ships neither library: pthreads and the POSIX
# timers are part of libc. Rather than patch every reference in every release,
# put empty archives with those names on the link path — the linker resolves the
# flags, they contribute nothing, and the symbols come from libc as intended.
if [ "$PLATFORM" = android ]; then
  STUB_DIR="$BUILD_DIR/bionic-stubs/$TARGET"
  if [ ! -f "$STUB_DIR/libpthread.a" ]; then
    log "Building empty libpthread/librt stubs for $TARGET"
    mkdir -p "$STUB_DIR"
    printf 'void jdk_custom_bionic_stub(void) {}\n' > "$STUB_DIR/stub.c"
    "$CC" -c "$STUB_DIR/stub.c" -o "$STUB_DIR/stub.o"
    for l in pthread rt; do "$TC/bin/llvm-ar" rcs "$STUB_DIR/lib$l.a" "$STUB_DIR/stub.o"; done
  fi
  EXTRA_CONF+=(--with-extra-ldflags="-L$STUB_DIR")
fi

# --- headers-only deps (cups, fontconfig) -----------------------------------
# configure requires both for every target except windows/macosx (NEEDS_LIB_CUPS
# / NEEDS_LIB_FONTCONFIG), and --enable-headless-only does not exempt them:
# libawt_headless compiles CUPSfuncs.c and fontpath.c. Neither is ever linked —
# configure exports only CUPS_CFLAGS / FONTCONFIG_CFLAGS (no *_LIBS exists), and
# both libraries are dlopened at run time (libcups.so.2 from CUPSfuncs.c,
# libfontconfig.so.1 from fontpath.c). So the headers are all the build needs, and
# being pure API they serve every target. Stage them in a private include dir
# instead of passing /usr/include, whose -I would be searched ahead of the
# target's own libc headers and shadow them.
if [ "$TARGET_OS" = linux ] || [ "$TARGET_OS" = bsd ]; then
  DEP_INC="$BUILD_DIR/dep-include"
  for dep in cups fontconfig; do
    [ -d "$DEP_INC/$dep" ] && continue
    [ -d "/usr/include/$dep" ] || {
      echo "$dep headers missing from the builder image (see docker/Dockerfile)" >&2; exit 1; }
    mkdir -p "$DEP_INC"
    cp -R "/usr/include/$dep" "$DEP_INC/"
  done
  EXTRA_CONF+=(--with-cups-include="$DEP_INC" --with-fontconfig-include="$DEP_INC")
fi

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
  --with-toolchain-type=clang
  BUILD_CC=clang
  BUILD_CXX=clang++
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
  # jdk8u: legacy build system — the option set is smaller and spelled
  # differently, but the intent matches common_conf above.
  # --disable-headful: 8's spelling of --enable-headless-only; it also sets
  # X11_NOT_NEEDED, so configure stops looking for X11 headers no cross sysroot
  # here has. --with-freetype=bundled: 8u does accept it on every target OS
  # (only the other bundled-lib toggles are missing), and without it configure
  # goes looking for a system freetype. --enable-unlimited-crypto: ship the
  # unlimited-strength JCE policy (default on 11+, opt-in on 8) so full-strength
  # ciphers work out of the box.
  bash ./configure \
    --openjdk-target="$TARGET" \
    --with-boot-jdk="$BOOT_JDK" \
    --with-jvm-variants="$JVM_VARIANT" \
    --with-debug-level=release \
    --disable-debug-symbols \
    --disable-warnings-as-errors \
    --disable-headful \
    --with-freetype=bundled \
    --enable-unlimited-crypto \
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
