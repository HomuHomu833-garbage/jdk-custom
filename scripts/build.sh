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
#   MINIAUDIO_VERSION  miniaudio release used for libjsound (linux targets)
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${PLATFORM:?set PLATFORM}" "${TARGET:?set TARGET}" "${JDK_VERSION:?set JDK_VERSION}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
SRC="${SRC:-$ROOTDIR/jdk-src}"
BOOT_JDK="${BOOT_JDK:-$ROOTDIR/boot-jdk}"
ARCH="${TARGET%%-*}"
BUILD_DIR="$ROOTDIR/build"
INSTALL_DIR="$ROOTDIR/install"
MINIAUDIO_VERSION="${MINIAUDIO_VERSION:-0.11.25}"
# The same file 21 and 25 ship, pinned to a tag; see the config.sub block below.
CONFIG_SUB_URL="${CONFIG_SUB_URL:-https://raw.githubusercontent.com/openjdk/jdk21u/jdk-21.0.12%2B8/make/autoconf/build-aux/autoconf-config.sub}"
MINIAUDIO_BACKEND="${MINIAUDIO_BACKEND:-$SCRIPT_DIR/../src/libjsound/PLATFORM_API_MiniAudio_PCM.c}"
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
  arm|armeb|armhf|armv7a|thumb|thumbeb)
    # 8 has no 32-bit ARM HotSpot to build: jdk8u mainline ships cpu ports for
    # aarch64, ppc, sparc, x86 and zero only — JDK 8's ARM32 JIT lived in
    # Oracle's separate arm-port forest and never landed here. Left on server it
    # picks up no arch at all and compiles the VM with the i486 flags
    # ("unsupported argument 'i586' to option '-march='"). 11+ carry
    # src/hotspot/cpu/arm, so they keep the JIT.
    if [ "$JDK_VERSION" = 8 ]; then JVM_VARIANT=zero; else JVM_VARIANT=server; fi ;;
  aarch64|aarch64_be|arm64|arm64e|powerpc64|powerpc64le|ppc64|ppc64le|riscv64|s390x|x86_64|x86_64h)
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
    # musl is static here and there is no way around it: zig supports musl only
    # as a static libc, so these targets link it in whether or not we ask.
    # -static-libgcc folds libgcc in to match. What that costs is dlopen — it
    # always fails in a statically linked musl binary — so anything the JDK
    # loads at run time rather than links (fontconfig, cups, the miniaudio
    # backends) is unavailable on musl. glibc keeps libc dynamic and keeps all
    # of it.
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
    # Windows via llvm-mingw. This does NOT work, and not for want of a patch or
    # two: OpenJDK has no linux-to-windows cross mode at all. Three separate
    # walls, verified against 8 through 25:
    #
    #   1. configure only recognises a windows *build host*. basic_windows.m4
    #      branches on OPENJDK_BUILD_OS_ENV being windows.cygwin / windows.msys2
    #      / windows.wsl1 / windows.wsl2, so from linux it goes looking for
    #      cygpath or wslpath and stops:
    #        configure: error: Incorrect linux installation. Neither cygpath nor
    #        wslpath was found
    #   2. every release declares VALID_TOOLCHAINS_windows="microsoft", so
    #      --with-toolchain-type=clang is refused even past that point.
    #   3. the windows halves of NativeCompilation.gmk and the flags m4s are
    #      written around MSVC conventions -- .obj, link.exe, LIB, MT, RC,
    #      manifests -- which mingw does not share.
    #
    # Getting windows JDKs out of this repository means building them on a
    # windows runner with MSVC, which is a separate path from everything here,
    # not a fixup on top of it. The toolchain wiring below is left in place so
    # that work has somewhere to start.
    TC=/opt/llvm-mingw
    export CC="$TC/bin/${TARGET}-clang" CXX="$TC/bin/${TARGET}-clang++"
    EXTRA_CONF+=(AR="$TC/bin/${TARGET}-ar" NM="$TC/bin/${TARGET}-nm" STRIP="$TC/bin/${TARGET}-strip" OBJCOPY="$TC/bin/${TARGET}-objcopy" OBJDUMP="$TC/bin/${TARGET}-objdump")
    export RC="$TC/bin/${TARGET}-windres"
    TARGET_OS=windows
    # Fold llvm-mingw's own runtime -- libunwind, libc++, libwinpthread -- into
    # each binary, so the JDK does not need those DLLs shipped beside it. This is
    # as static as Windows gets: the CRT itself (msvcrt/ucrtbase) is an OS
    # component, and there is no static archive of it to link. dlopen has no
    # equivalent problem here — LoadLibrary is a system call, not a libc feature,
    # so JNI and the rest keep working.
    EXTRA_CONF+=(--with-extra-ldflags=-static)
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
#
# The triple goes in as the autoconf --build/--host/--target set rather than via
# --openjdk-target, because 8, 11 and 17 refuse the two together outright
# ("Specifying --openjdk-target together with autoconf legacy cross-compilation
# flags is not supported") while 21 and 25 accept it. Every one of them takes the
# autoconf set on its own — with a warning, and --openjdk-target expands to
# exactly this internally — so it is the one spelling that works across all five.
# OPENJDK_BUILD_* value are derived correctly.
BUILD_TRIPLE="$(gcc -dumpmachine 2>/dev/null || clang -dumpmachine 2>/dev/null || true)"
[ -n "$BUILD_TRIPLE" ] || { echo "cannot determine the build triple (no gcc/clang?)" >&2; exit 1; }
EXTRA_CONF+=(--build="$BUILD_TRIPLE")

# --- sound: ALSA out, miniaudio in ------------------------------------------
# OpenJDK demands ALSA for every OPENJDK_TARGET_OS=linux build and links its sound
# native lib against -lasound, so configure dies with "Could not find alsa!" —
# none of the cross sysroots here carry ALSA, and bionic has no ALSA at all.
# Termux works around this by packaging alsa-lib for Android and pointing
# configure at it; with no equivalent sysroot for any target, libjsound is built
# against miniaudio instead (src/libjsound/PLATFORM_API_MiniAudio_PCM.c).
# miniaudio declares the backend symbols itself and dlopen()s whatever the
# machine actually has — PulseAudio, ALSA, JACK, sndio, OSS, and AAudio/OpenSL ES
# on android — so nothing has to be found at build time and one binary covers
# every target. It replaces the PCM (DirectAudio) provider only: ports (mixer
# controls) and MIDI have no miniaudio equivalent and are compiled out, so
# javax.sound.sampled gets playback and capture while javax.sound.midi keeps
# only its pure-Java software synth. macOS and Windows keep their native sound
# (CoreAudio / DirectSound, never ALSA) and the BSDs never needed it, so only
# TARGET_OS=linux is touched. Edits go into the fetched source tree and are keyed
# to text that is stable across the supported feature versions.
#
# Fetch the pinned miniaudio header once and put it, and the backend, into the
# platform sound source directory the build compiles from -- 8 and 11+ disagree
# on where that is, so the caller passes it in.
install_miniaudio() {
  local dest="$1" header="$BUILD_DIR/miniaudio-$MINIAUDIO_VERSION/miniaudio.h"

  [ -d "$dest" ] || { echo "libjsound sources not found at $dest" >&2; exit 1; }
  [ -f "$MINIAUDIO_BACKEND" ] || {
    echo "miniaudio backend not found at $MINIAUDIO_BACKEND" >&2; exit 1; }
  if [ ! -f "$header" ]; then
    log "Downloading miniaudio $MINIAUDIO_VERSION (libjsound PCM backend)"
    mkdir -p "$(dirname "$header")"
    aria2c --console-log-level=error --check-certificate=false --max-tries=5 \
      --dir="$(dirname "$header")" -o miniaudio.h \
      "https://raw.githubusercontent.com/mackron/miniaudio/$MINIAUDIO_VERSION/miniaudio.h"
  fi
  cp "$header" "$dest/miniaudio.h"
  cp "$MINIAUDIO_BACKEND" "$dest/"
}

if [ "$TARGET_OS" = linux ]; then
  if [ "$JDK_VERSION" = 8 ]; then
    log "Building libjsound against miniaudio instead of libjsoundalsa"
    # 8: ALSA lives in its own libjsoundalsa, pulled in only when the makefile
    # adds jsoundalsa to EXTRA_SOUND_JNI_LIBS. Rather than keep a second library
    # alive, fold the miniaudio provider straight into libjsound the way macosx
    # and solaris already fold in their own platform PCM files — libjsound's
    # mapfile already exports the DirectAudioDevice natives for exactly that
    # reason, so no symbol plumbing has to move. 8 is also the one version
    # shipping a checked-in generated-configure.sh, so ALSA_NOT_NEEDED goes into
    # it as well as the .m4.
    SND_GMK="$SRC/jdk/make/lib/SoundLibraries.gmk"
    grep -q 'EXTRA_SOUND_JNI_LIBS += jsoundalsa' "$SND_GMK" 2>/dev/null || {
      echo "unexpected $SND_GMK: no jsoundalsa to replace" >&2; exit 1; }
    for f in "$SRC/common/autoconf/libraries.m4" "$SRC/common/autoconf/generated-configure.sh"; do
      [ -f "$f" ] || continue
      # The linux block only disables pulse; disable alsa right alongside it. The
      # other OS blocks that set PULSE_NOT_NEEDED already disable alsa too, so
      # matching all of them is harmless.
      sed -i 's/^\([[:space:]]*\)PULSE_NOT_NEEDED=yes$/\1PULSE_NOT_NEEDED=yes\n\1ALSA_NOT_NEEDED=yes/' "$f"
    done

    # 8 keeps every unix platform source under src/solaris, ALSA included.
    install_miniaudio "$SRC/jdk/src/solaris/native/com/sun/media/sound"

    # Then rewrite the linux block: no jsoundalsa (its whole makefile stanza is
    # guarded on EXTRA_SOUND_JNI_LIBS, so dropping the entry leaves the ALSA
    # sources uncompiled), and the DirectAudio provider compiled into libjsound
    # with the providers miniaudio cannot serve switched off. LIBJSOUND_SRC_FILES
    # is an explicit list here, so nothing has to be excluded.
    sed -i '/EXTRA_SOUND_JNI_LIBS += jsoundalsa/d' "$SND_GMK"
    awk '
      $0 == "  LIBJSOUND_CFLAGS += -DX_PLATFORM=X_LINUX" {
        print "  LIBJSOUND_CFLAGS += -DX_PLATFORM=X_LINUX \\"
        print "      -DUSE_DAUDIO=TRUE \\"
        print "      -DUSE_PORTS=FALSE \\"
        print "      -DUSE_PLATFORM_MIDI_OUT=FALSE \\"
        print "      -DUSE_PLATFORM_MIDI_IN=FALSE"
        print "  LIBJSOUND_SRC_FILES += PLATFORM_API_MiniAudio_PCM.c $(LIBJSOUND_DAUDIOFILES)"
        done = 1
        next
      }
      { print }
      END { if (!done) exit 1 }
    ' "$SND_GMK" > "$SND_GMK.tmp" || {
      echo "unexpected $SND_GMK: no linux X_PLATFORM line to extend" >&2; exit 1; }
    mv "$SND_GMK.tmp" "$SND_GMK"

    # miniaudio resolves its backends through the dynamic loader at run time.
    awk '
      !done && index($0, "LDFLAGS_SUFFIX_posix := -ljava -ljvm,") {
        match($0, /^[[:space:]]*/)
        print substr($0, 1, RLENGTH) "LDFLAGS_SUFFIX_linux := $(LIBDL) -lm -lpthread, \\"
        done = 1
      }
      { print }
      END { if (!done) exit 1 }
    ' "$SND_GMK" > "$SND_GMK.tmp" || {
      echo "unexpected $SND_GMK: no libjsound LDFLAGS_SUFFIX to extend" >&2; exit 1; }
    mv "$SND_GMK.tmp" "$SND_GMK"
  else
    log "Building libjsound against miniaudio instead of ALSA"
    # 11+: configure regenerates from the .m4 via autoconf (no checked-in
    # generated-configure.sh since 11), so clearing NEEDS_LIB_ALSA is all it
    # takes to stop it hunting for headers no sysroot here has.
    ALSA_M4="$SRC/make/autoconf/libraries.m4"
    grep -qE 'NEEDS_LIB_ALSA=(true|false)' "$ALSA_M4" || {
      echo "unexpected $ALSA_M4: no NEEDS_LIB_ALSA to disable" >&2; exit 1; }
    sed -i 's/NEEDS_LIB_ALSA=true/NEEDS_LIB_ALSA=false/' "$ALSA_M4"

    # 11+ keeps the linux platform sources next to the ALSA ones they replace.
    JSOUND_SRC="$SRC/src/java.desktop/linux/native/libjsound"
    install_miniaudio "$JSOUND_SRC"

    # Then point the makefile at it. The ALSA sources include <alsa/asoundlib.h>
    # and call snd_* outside the USE_* guards, so they have to leave the build
    # entirely; the providers miniaudio cannot serve are compiled out through the
    # USE_* flags the sources already honour; and -lasound gives way to the
    # dynamic loader miniaudio needs ($(ALSA_LIBS) is empty by now anyway).
    # 11 keeps the rules in make/lib/, 17+ in make/modules/.
    JSOUND_GMK="$SRC/make/modules/java.desktop/Lib.gmk"
    [ -f "$JSOUND_GMK" ] || JSOUND_GMK="$SRC/make/lib/Lib-java.desktop.gmk"
    [ -f "$JSOUND_GMK" ] || { echo "libjsound makefile not found under $SRC/make" >&2; exit 1; }
    if ! grep -q 'EXCLUDE_FILES := PLATFORM_API_LinuxOS_ALSA' "$JSOUND_GMK"; then
      grep -q 'LIBS_linux := $(ALSA_LIBS)' "$JSOUND_GMK" || {
        echo "unexpected $JSOUND_GMK: no ALSA_LIBS to replace" >&2; exit 1; }
      sed -i \
        -e 's/-DUSE_PORTS=TRUE/-DUSE_PORTS=FALSE/' \
        -e 's/-DUSE_PLATFORM_MIDI_OUT=TRUE/-DUSE_PLATFORM_MIDI_OUT=FALSE/' \
        -e 's/-DUSE_PLATFORM_MIDI_IN=TRUE/-DUSE_PLATFORM_MIDI_IN=FALSE/' \
        -e 's|LIBS_linux := [$](ALSA_LIBS),|LIBS_linux := $(LIBDL) -lm -lpthread,|' \
        "$JSOUND_GMK"
      # EXCLUDE_FILES matches on basename, so the list needs no paths.
      ALSA_SRC="$(cd "$JSOUND_SRC" && echo PLATFORM_API_LinuxOS_ALSA_*.c)"
      case "$ALSA_SRC" in
        *'*'*) echo "unexpected $JSOUND_SRC: no ALSA sources to exclude" >&2; exit 1 ;;
      esac
      awk -v excl="$ALSA_SRC" '
        { print }
        !done && index($0, "NAME := jsound, \\") {
          match($0, /^[[:space:]]*/)
          print substr($0, 1, RLENGTH) "EXCLUDE_FILES := " excl ", \\"
          done = 1
        }
        END { if (!done) exit 1 }
      ' "$JSOUND_GMK" > "$JSOUND_GMK.tmp" || {
        echo "unexpected $JSOUND_GMK: no libjsound NAME to anchor to" >&2; exit 1; }
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
  # --undefined-version: hotspot's version script marks _init/_fini local, but
  # bionic's crt provides neither, and lld has treated a version-script entry for
  # a missing symbol as an error since LLVM 17:
  #   ld.lld: error: version script assignment of 'local' to symbol '_fini'
  #   failed: symbol not defined
  # The flag restores the older lenient behaviour for symbols that aren't there,
  # leaving the script's meaning intact for every symbol that is — cheaper than
  # patching version-script-clang.txt in each release.
  EXTRA_CONF+=(--with-extra-ldflags="-L$STUB_DIR -Wl,--undefined-version")

  # bionic's linker honours DT_RUNPATH and ignores DT_RPATH outright, so a JDK
  # that asks for the old tag cannot find its own libraries and no launcher
  # starts:
  #   WARNING: linker: ... unused DT entry: DT_RPATH (type 0xf arg 0xcf) (ignoring)
  #   CANNOT LINK EXECUTABLE "./java": library "libjli.so" not found
  # OpenJDK asks for it deliberately -- RPATH outranks LD_LIBRARY_PATH, so the
  # JDK's internal dependencies cannot be hijacked (JDK-8326891) -- but on
  # android the choice is between RUNPATH and nothing. Drop the flag for these
  # builds only; the linux ones keep RPATH and that protection. 8 never passes
  # it, and lld defaults to the new tags, so it has no file to edit here.
  DTAGS_M4="$SRC/make/autoconf/flags-cflags.m4"
  if [ -f "$DTAGS_M4" ]; then
    grep -q -- '-Wl,--disable-new-dtags' "$DTAGS_M4" || {
      echo "unexpected $DTAGS_M4: no --disable-new-dtags to remove" >&2; exit 1; }
    log "Letting the linker emit DT_RUNPATH (bionic ignores DT_RPATH)"
    sed -i 's/ -Wl,--disable-new-dtags//g' "$DTAGS_M4"
  fi

  # aarch64: 11 keeps the TLSDESC thread-pointer helper in a lowercase .s, which
  # the compiler never preprocesses, so unlike 17+ it cannot be guarded with
  # #ifndef __ANDROID__ from inside. Excluding it through the makefiles did not
  # take either -- the libjvm object count was unchanged with JVM_EXCLUDE_FILES
  # set -- so remove the file, which is unambiguous. Patch 0015 supplies the
  # aarch64_get_thread_helper() the assembly would have defined. Nothing else
  # references it, and only aarch64 targets ever compile it.
  TLSDESC_S="$SRC/src/hotspot/os_cpu/linux_aarch64/threadLS_linux_aarch64.s"
  if [ -f "$TLSDESC_S" ]; then
    log "Removing $(basename "$TLSDESC_S") (bionic has no TLSDESC support)"
    rm -f "$TLSDESC_S"
  fi

  # 8: drop the Serviceability Agent's native half. libsaproc talks to
  # libthread_db through <thread_db.h>, which bionic has no equivalent of:
  #   proc_service.h:29:10: fatal error: 'thread_db.h' file not found
  # 11+ get this from patch 0011, which can gate on OPENJDK_TARGET_LIBC; 8's
  # hotspot makefiles are handed no libc information at all, so do it here where
  # the platform is known. Two edits: stop saproc.make building the library, and
  # take it out of the export list, which demands it whether or not anything
  # built it. Only the libsaproc entry goes -- ADD_SA_BINARIES also names
  # sa-jdi.jar, which is pure Java, builds from sa.make regardless, and is what
  # the images stage goes looking for:
  #   No rule to make target '.../jdk/lib/sa-jdi.jar', needed by
  #   '.../images/lib/sa-jdi.jar'
  # Editing the entry rather than the EXPORT_LIST line also keeps the per-arch
  # gating, so the Zero targets that never had SA stay untouched.
  if [ "$JDK_VERSION" = 8 ]; then
    SA_MAKE="$SRC/hotspot/make/linux/makefiles/saproc.make"
    HS_DEFS="$SRC/hotspot/make/linux/makefiles/defs.make"
    for f in "$SA_MAKE" "$HS_DEFS"; do
      [ -f "$f" ] || { echo "expected $f in the jdk8 hotspot tree" >&2; exit 1; }
    done
    grep -q 'ifneq ($(wildcard $(AGENT_DIR)),)' "$SA_MAKE" || {
      echo "unexpected $SA_MAKE: no AGENT_DIR guard to disable" >&2; exit 1; }
    grep -q 'libsaproc\.$(LIBRARY_SUFFIX)' "$HS_DEFS" || {
      echo "unexpected $HS_DEFS: no libsaproc export to drop" >&2; exit 1; }
    sed -i 's|^ifneq (\$(wildcard \$(AGENT_DIR)),)$|ifeq (skip-saproc, build-saproc)|' "$SA_MAKE"
    perl -pi -e 's/ \$\(EXPORT_JRE_LIB_ARCH_DIR\)\/libsaproc\.\$\(LIBRARY_SUFFIX\)//g' "$HS_DEFS"
  fi
fi

# --- libffi (Zero only) -----------------------------------------------------
# Zero calls native code through libffi, and configure requires it whenever the
# variant is zero (libraries.m4: NEEDS_LIB_FFI). Unlike cups/fontconfig this one
# is genuinely linked — lib-ffi.m4 sets LIBFFI_LIBS=-lffi — and no cross sysroot
# here ships it, so build it from source for the target.
#   --with-pic + static: libffi ends up inside libjvm.so, so its objects must be
#   position independent; linking it statically also means the finished JDK has
#   no run-time libffi.so to find on a device that has none.
#   --build is passed for the same config.guess reason as above: $CC is a cross
#   compiler, so libffi would otherwise misdetect the builder and, worse, not
#   realise it is cross-compiling and try to run its test programs.
if [ "$JVM_VARIANT" = zero ]; then
  LIBFFI_VERSION="${LIBFFI_VERSION:-3.7.1}"
  FFI_PREFIX="$BUILD_DIR/libffi/$TARGET"
  if [ ! -f "$FFI_PREFIX/lib/libffi.a" ]; then
    log "Cross-building libffi $LIBFFI_VERSION for $TARGET (needed by Zero)"
    FFI_SRC="$BUILD_DIR/libffi/src-$LIBFFI_VERSION"
    if [ ! -d "$FFI_SRC" ]; then
      mkdir -p "$FFI_SRC"
      aria2c --console-log-level=error --check-certificate=false --max-tries=5 \
        --dir="$BUILD_DIR/libffi" -o libffi.tar.gz \
        "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz"
      tar -xzf "$BUILD_DIR/libffi/libffi.tar.gz" -C "$FFI_SRC" --strip-components=1
      rm -f "$BUILD_DIR/libffi/libffi.tar.gz"
    fi
    FFI_BUILD="$BUILD_DIR/libffi/build-$TARGET"
    rm -rf "$FFI_BUILD"; mkdir -p "$FFI_BUILD"
    ffi_conf=(--host="$TARGET" --build="$BUILD_TRIPLE" --prefix="$FFI_PREFIX"
              --enable-static --disable-shared --with-pic --disable-multi-os-directory)
    # Prefer the toolchain's own archiver; the wrapper sets vary per platform, so
    # fall back to whatever libffi's configure finds when it isn't there.
    [ -x "$TC/bin/llvm-ar" ] && ffi_conf+=(AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib")
    ( cd "$FFI_BUILD" && "$FFI_SRC/configure" "${ffi_conf[@]}" \
        && make -j"$(nproc 2>/dev/null || echo 2)" && make install )
    [ -f "$FFI_PREFIX/lib/libffi.a" ] || {
      echo "libffi build did not produce $FFI_PREFIX/lib/libffi.a" >&2; exit 1; }
  fi
  # 8 has no --with-libffi-include/--with-libffi-lib; its configure only does
  # PKG_CHECK_MODULES([LIBFFI], [libffi]) and would reject them outright
  # ("configure: error: unrecognized options"). Point pkg-config at the libffi
  # just built instead — the .pc file installed alongside it carries the same
  # include and lib paths those options would have named.
  if [ "$JDK_VERSION" = 8 ]; then
    [ -f "$FFI_PREFIX/lib/pkgconfig/libffi.pc" ] || {
      echo "libffi built without a pkg-config file at $FFI_PREFIX/lib/pkgconfig" >&2; exit 1; }
    export PKG_CONFIG_PATH="$FFI_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  else
    EXTRA_CONF+=(--with-libffi-include="$FFI_PREFIX/include" --with-libffi-lib="$FFI_PREFIX/lib")
  fi
fi

# --- headers-only deps (cups, fontconfig, X11) ------------------------------
# configure requires both for every target except windows/macosx (NEEDS_LIB_CUPS
# / NEEDS_LIB_FONTCONFIG), and --enable-headless-only does not exempt them:
# libawt_headless compiles CUPSfuncs.c and fontpath.c. Neither is ever linked —
# configure exports only CUPS_CFLAGS / FONTCONFIG_CFLAGS (no *_LIBS exists), and
# both libraries are dlopened at run time (libcups.so.2 from CUPSfuncs.c,
# libfontconfig.so.1 from fontpath.c). So the headers are all the build needs, and
# being pure API they serve every target. Stage them in a private include dir
# instead of passing /usr/include, whose -I would be searched ahead of the
# target's own libc headers and shadow them.
#
# X11 rides along for the same reason. 11, 17 and 21 all compile libawt against
# it whatever --enable-headless-only says — rect.h pulls in <X11/Xlib.h>, so the
# build stops with "fatal error: 'X11/Xlib.h' file not found" — while only the
# headful libawt_xawt, which a headless build never produces, links against the
# libraries. 25 dropped the include and needs none of this; the extra -I is
# harmless there. Passing -I directly rather than through --x-includes is what
# makes this work across all of them: 17 and 25 answer "X11 not needed" and
# clear X_CFLAGS, so anything routed through configure's X11 support is dropped
# before it reaches the compiler.
if [ "$TARGET_OS" = linux ] || [ "$TARGET_OS" = bsd ]; then
  DEP_INC="$BUILD_DIR/dep-include"
  for dep in cups fontconfig X11; do
    [ -d "$DEP_INC/$dep" ] && continue
    [ -d "/usr/include/$dep" ] || {
      echo "$dep headers missing from the builder image (see docker/Dockerfile)" >&2; exit 1; }
    mkdir -p "$DEP_INC"
    cp -R "/usr/include/$dep" "$DEP_INC/"
  done
  # 8 has no --disable-warnings-as-errors. Patch 0003 empties hotspot's own
  # -Werror, but the JDK-side native libraries carry their own, and bionic
  # differs from glibc in ways that trip it — socklen_t is signed there, so
  # SctpNet.c fails on -Wpointer-sign. Turn errors back into warnings, matching
  # what every other release here is configured with.
  EXTRA_CFLAGS="-I$DEP_INC"
  [ "$JDK_VERSION" = 8 ] && EXTRA_CFLAGS="$EXTRA_CFLAGS -Wno-error"
  EXTRA_CONF+=(--with-cups-include="$DEP_INC" --with-fontconfig-include="$DEP_INC"
               --with-extra-cflags="$EXTRA_CFLAGS")
fi

# --- a config.sub that knows android ----------------------------------------
# 8, 11 and 17 ship an autoconf-config.sub from 2008, which predates android and
# rejects every triple built here — configure stops at "checking host system
# type" with "Invalid configuration `x86_64-linux-android': system `android' not
# recognized". 21 and 25 carry a 2022 copy that resolves all of them. Swap the
# stale file for that same known-good one, and only when the tree's own copy
# cannot parse this target, so a release that refreshes it is left alone.
CONFIG_SUB_DIR="$SRC/make/autoconf/build-aux"
[ -d "$CONFIG_SUB_DIR" ] || CONFIG_SUB_DIR="$SRC/common/autoconf/build-aux"
if [ -f "$CONFIG_SUB_DIR/config.sub" ] \
   && ! bash "$CONFIG_SUB_DIR/config.sub" "$TARGET" >/dev/null 2>&1; then
  log "Refreshing config.sub (the bundled one predates android)"
  CONFIG_SUB_CACHE="$BUILD_DIR/autoconf-config.sub"
  if [ ! -f "$CONFIG_SUB_CACHE" ]; then
    mkdir -p "$BUILD_DIR"
    aria2c --console-log-level=error --check-certificate=false --max-tries=5 \
      --dir="$BUILD_DIR" -o autoconf-config.sub "$CONFIG_SUB_URL"
  fi
  cp "$CONFIG_SUB_CACHE" "$CONFIG_SUB_DIR/autoconf-config.sub"
  bash "$CONFIG_SUB_DIR/config.sub" "$TARGET" >/dev/null 2>&1 || {
    echo "refreshed config.sub still cannot parse '$TARGET'" >&2; exit 1; }
fi

# --- jdk8: give the clang toolchain a PIC flag ------------------------------
# 8 sets PICFLAG only for gcc; the clang branch leaves it empty, because 8's
# clang support was written for macosx, where PIC is the default and saying so
# is unnecessary. Everywhere else that means the JDK's own shared libraries are
# compiled without -fPIC and every one of them fails to link:
#   ld.lld: error: relocation R_AARCH64_ADR_PREL_PG_HI21 cannot be used against
#   symbol 'TT_RunIns'; recompile with -fPIC
# Give clang what gcc gets, except where the flag is meaningless: macosx has PIC
# by default, and windows has no such concept. 8 ships a checked-in
# generated-configure.sh alongside the .m4, so both carry the change.
if [ "$JDK_VERSION" = 8 ]; then
  pic_patched=0
  for f in "$SRC/common/autoconf/flags.m4" "$SRC/common/autoconf/generated-configure.sh"; do
    [ -f "$f" ] || continue
    grep -q "^      PICFLAG=''\$" "$f" || continue
    sed -i "s%^      PICFLAG=''\$%      case \$OPENJDK_TARGET_OS in\n        macosx|windows) PICFLAG='' ;;\n        *) PICFLAG='-fPIC' ;;\n      esac%" "$f"
    pic_patched=1
  done
  [ "$pic_patched" = 1 ] || {
    echo "unexpected jdk8 tree: no empty clang PICFLAG to set" >&2; exit 1; }
fi

# --- configure --------------------------------------------------------------
CONF="custom-$TARGET"
IMAGE_DIR="$SRC/build/$CONF/images/jdk"

# Flags common to every modern (11+) configure. Bundled libs keep the build
# self-contained per target; headless-only drops the X11/CUPS desktop deps.
common_conf=(
  --host="$TARGET"
  --target="$TARGET"
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
  --with-freetype=bundled
  --with-libpng=bundled
  --with-giflib=bundled
  --with-libjpeg=bundled
  --with-lcms=bundled
  --with-zlib=bundled
  --with-conf-name="$CONF"
)

# --with-build-user arrived in 17. configure treats unknown options as fatal
# ("configure: error: unrecognized options: --with-build-user"), so 11 only gets
# the environment fallback below.
if [ "$JDK_VERSION" -ge 17 ] 2>/dev/null; then
  common_conf+=(--with-build-user=builder)
fi
# Same intent for the releases without the option: the build otherwise stamps
# whoever ran it into the release file.
export USER=builder

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
  # ciphers work out of the box. Neither --disable-warnings-as-errors nor
  # --with-build-user exists yet in 8, and configure makes unknown options fatal,
  # so both are left off. BUILD_CC/BUILD_CXX matter more here than on 11+:
  # hotspot-spec.gmk.in maps BUILD_CXX onto hotspot's HOSTCXX, which builds adlc
  # — and hotspot hands that host tool the *target* compiler's flags, so with the
  # NDK clang as CXX it adds -flimit-debug-info and host g++ refuses it
  # ("g++: error: unrecognized command-line option '-flimit-debug-info'").
  # Building adlc with clang too keeps the flags and the compiler in agreement.
  bash ./configure \
    --host="$TARGET" \
    --target="$TARGET" \
    --with-boot-jdk="$BOOT_JDK" \
    --with-jvm-variants="$JVM_VARIANT" \
    --with-debug-level=release \
    --disable-debug-symbols \
    --disable-headful \
    --with-freetype=bundled \
    --enable-unlimited-crypto \
    BUILD_CC=clang \
    BUILD_CXX=clang++ \
    "${EXTRA_CONF[@]}"
  CONF8="$(ls -d "$SRC"/build/*/ 2>/dev/null | head -n1)"
  IMAGE_DIR="${CONF8%/}/images/j2sdk-image"
else
  bash ./configure "${common_conf[@]}" "${EXTRA_CONF[@]}"
fi

# --- build ------------------------------------------------------------------
log "Building (make images)"
if [ "$JDK_VERSION" = 8 ]; then
  # --disable-headful does not reach the makefiles on 8: configure emits
  # BUILD_HEADLESS:=true into spec.gmk, but Awt2dLibraries.gmk,
  # CompileLaunchers.gmk and CompileJavaClasses.gmk all gate on
  # BUILD_HEADLESS_ONLY, which nothing ever sets. So libawt_xawt gets built
  # regardless — it wants glibc's <execinfo.h> backtrace(), which bionic has
  # no equivalent of, and it would then try to link the X11 libraries this
  # repository only stages headers for. Set the variable the makefiles are
  # actually looking for.
  make BUILD_HEADLESS_ONLY=true images
else
  make CONF="$CONF" images
fi

[ -d "$IMAGE_DIR" ] || { echo "expected JDK image not found at $IMAGE_DIR" >&2; exit 1; }

log "Staging install tree"
mkdir -p "$INSTALL_DIR/$JDK_VERSION-$TARGET"
cp -R "$IMAGE_DIR"/. "$INSTALL_DIR/$JDK_VERSION-$TARGET"
log "Done -> $INSTALL_DIR/$JDK_VERSION-$TARGET"
