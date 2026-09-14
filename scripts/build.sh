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
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
SRC="${SRC:-$ROOTDIR/jdk-src}"
BOOT_JDK="${BOOT_JDK:-$ROOTDIR/boot-jdk}"
ARCH="${TARGET%%-*}"
BUILD_DIR="$ROOTDIR/build"
INSTALL_DIR="$ROOTDIR/install"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Download with retries; aria2's own --retry-on-unknown is missing from older
# builds. --allow-overwrite/--auto-file-renaming keep a retry from parking the
# second attempt beside the first as NAME.1.
fetch() {
  local i=0
  until aria2c --console-log-level=error --check-certificate=false \
               --max-tries=5 --retry-wait=2 --connect-timeout=15 \
               --allow-overwrite=true --auto-file-renaming=false "$@"; do
    i=$((i + 1)); [ "$i" -ge 5 ] && { echo "fetch: giving up after $i attempts" >&2; return 1; }
    echo "fetch: aria2c failed, retry $i/5 in 2s..." >&2; sleep 2
  done
}

unpack() {
  local archive="$1" dest="$2"; shift 2
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$dest" "$@" ;;
    *.tar.xz)       tar -xJf "$archive" -C "$dest" "$@" ;;
    *.tar.bz2)      tar -xjf "$archive" -C "$dest" "$@" ;;
    *.zip)          unzip -qq -o "$archive" -d "$dest" ;;
    *) echo "unpack: don't know how to unpack $archive" >&2; return 1 ;;
  esac
}

# aria2c cannot detect a truncated download from an endpoint that streams
# without a Content-Length: it has no expected total, so it reports success on a
# short file and the damage surfaces later as "unexpected end of file". Unpacking
# is the only integrity check available, so retry the two together.
# Args: url, archive path, destination, then any extra options for tar.
fetch_unpack() {
  local url="$1" archive="$2" dest="$3" i=0; shift 3
  mkdir -p "$dest"
  while :; do
    rm -f "$archive" "$archive.aria2"
    if fetch --dir="$(dirname "$archive")" -o "$(basename "$archive")" "$url" \
       && unpack "$archive" "$dest" "$@"; then
      rm -f "$archive"
      return 0
    fi
    i=$((i + 1))
    [ "$i" -ge 5 ] && { echo "fetch_unpack: $url still incomplete after $i attempts" >&2; return 1; }
    echo "fetch_unpack: $(basename "$archive") came down incomplete, retry $i/5 in $((5 * i))s..." >&2
    sleep $((5 * i))
  done
}

[ -x "$BOOT_JDK/bin/javac" ] || { echo "boot JDK not found at $BOOT_JDK (run fetch-source.sh)" >&2; exit 1; }
[ -d "$SRC" ] || { echo "source tree not found at $SRC (run fetch-source.sh)" >&2; exit 1; }

if [ -d "$INSTALL_DIR/$JDK_VERSION-$TARGET" ]; then
    log "JDK $JDK_VERSION already built for $TARGET"; exit 0
fi

# --- HotSpot variant --------------------------------------------------------
# Server everywhere. Zero builds, but an interpreter-only JDK is not what any of
# these targets is for, so a CPU without a JIT port should fail where the port is
# missing rather than quietly produce one. Set JVM_VARIANT to override.
#
# Known to have no upstream JIT, for when this is revisited: 32-bit x86 on 25
# (JEP 503 deleted it), 32-bit ARM on 8 (its JIT lived in Oracle's arm-port
# forest and never landed in jdk8u), loongarch64 before 21, mips after 15.
JVM_VARIANT="${JVM_VARIANT:-server}"

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
    # -static-libgcc folds libgcc in to match. What that costs is dlopen: it
    # always fails in a statically linked musl binary, so anything the JDK
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
    # Windows via llvm-mingw, cross-compiled from linux. Upstream has no such
    # mode: configure only recognises a windows build host, every release
    # declares VALID_TOOLCHAINS_windows="microsoft", and the windows halves of
    # the makefiles are written around MSVC conventions (.obj, link.exe, LIB,
    # MT, RC, manifests). Everything below rewrites those three assumptions in
    # the fetched tree. 11, 17, 21 and 25 all build and publish x86_64 and
    # aarch64; i686, armv7 and arm64ec need hotspot ports (see
    # make_jdk_windows.yml).
    TC=/opt/llvm-mingw
    export CC="$TC/bin/${TARGET}-clang" CXX="$TC/bin/${TARGET}-clang++"
    EXTRA_CONF+=(AR="$TC/bin/${TARGET}-ar" NM="$TC/bin/${TARGET}-nm" STRIP="$TC/bin/${TARGET}-strip" OBJCOPY="$TC/bin/${TARGET}-objcopy" OBJDUMP="$TC/bin/${TARGET}-objdump")
    export RC="$TC/bin/${TARGET}-windres"
    TARGET_OS=windows

    CASE_INC="$BUILD_DIR/mingw-case-include"
    MINGW_INC="$TC/$TARGET/include"
    # llvm-mingw ships no sysroot of its own for arm64ec, which uses the aarch64
    # headers. Without this the whole shim below is skipped, and the first thing
    # to miss it is clang's own arm64intr.h, whose #include_next then has nothing
    # to find.
    if [ ! -d "$MINGW_INC" ] && [ -d "$TC/aarch64-w64-mingw32/include" ]; then
      MINGW_INC="$TC/aarch64-w64-mingw32/include"
      log "Using the aarch64 mingw headers for $TARGET"
    fi
    if [ -d "$MINGW_INC" ]; then
      rm -rf "$CASE_INC"; mkdir -p "$CASE_INC"
      grep -rhoE '#[[:space:]]*include[[:space:]]*<[A-Za-z0-9_]+\.h>' "$SRC/src" 2>/dev/null \
        | grep -oE '<[A-Za-z0-9_]+\.h>' | tr -d '<>' | sort -u \
        | while read -r hdr; do
            low=$(printf '%s' "$hdr" | tr '[:upper:]' '[:lower:]')
            [ "$hdr" = "$low" ] && continue
            [ -e "$MINGW_INC/$hdr" ] && continue
            [ -e "$MINGW_INC/$low" ] || continue
            ln -sf "$MINGW_INC/$low" "$CASE_INC/$hdr"
          done
      log "Aliased $(ls -1 "$CASE_INC" | wc -l) capitalised windows headers"

      # hotspot's windows_aarch64 orderAccess includes <arm64intr.h> for the
      # barrier operand names. clang ships that header, but its body is behind
      # #ifndef _MSC_VER -> #include_next <arm64intr.h>: it is an MSVC-only
      # header that expects the platform SDK to provide the real one. mingw-w64
      # has no arm64intr.h at all, so the delegation dead-ends:
      #   arm64intr.h:12: fatal error: 'arm64intr.h' file not found
      # Supply it here, ahead of clang's copy on the include path. The values
      # are the architectural DMB/DSB operand encodings, not a Microsoft
      # invention, so they are the same numbers clang's MSVC branch uses.
      case "$TARGET" in
        aarch64-*|arm64ec-*)
          cat > "$CASE_INC/arm64intr.h" <<'EOF'
#ifndef __ARM64INTR_H
#define __ARM64INTR_H

#define ARM64_SYSREG(op0, op1, crn, crm, op2) \
        (((op0 & 1) << 14) | ((op1 & 7) << 11) | ((crn & 15) << 7) | \
         ((crm & 15) << 3) | ((op2 & 7) << 0))

#define ARM64_FPCR ARM64_SYSREG(3, 3, 4, 4, 0)
#define ARM64_FPSR ARM64_SYSREG(3, 3, 4, 4, 1)

typedef enum _tag_ARM64INTR_BARRIER_TYPE {
  _ARM64_BARRIER_OSHLD = 0x1,
  _ARM64_BARRIER_OSHST = 0x2,
  _ARM64_BARRIER_OSH   = 0x3,
  _ARM64_BARRIER_NSHLD = 0x5,
  _ARM64_BARRIER_NSHST = 0x6,
  _ARM64_BARRIER_NSH   = 0x7,
  _ARM64_BARRIER_ISHLD = 0x9,
  _ARM64_BARRIER_ISHST = 0xA,
  _ARM64_BARRIER_ISH   = 0xB,
  _ARM64_BARRIER_LD    = 0xD,
  _ARM64_BARRIER_ST    = 0xE,
  _ARM64_BARRIER_SY    = 0xF
} _ARM64INTR_BARRIER_TYPE;

/* __dmb / __isb / __dsb themselves come from mingw's intrin.h. */
#include <intrin.h>

#endif
EOF
          log "Providing an arm64intr.h shim (mingw-w64 ships none)"
          ;;
      esac

      # windows.h's min() and max() macros: mingw defines them for C only;
      # minwindef.h guards them with #ifndef __cplusplus, where MSVC defines
      # them for C++ as well. So every .c file is fine and the C++ ones are not:
      #   D3DVertexCacher.cpp:332: error: use of undeclared identifier 'max';
      #   did you mean 'fmax'?
      # Shadow minwindef.h, chain to the real one, and add the missing half.
      # Going through the header rather than the command line keeps this to the
      # translation units that actually include windows.h, which is what MSVC
      # does, and respects NOMINMAX, so hotspot, which sets it deliberately so
      # the macros cannot shadow std::min/std::max, still gets neither.
      if [ -e "$MINGW_INC/minwindef.h" ]; then
        cat > "$CASE_INC/minwindef.h" <<'EOF'
#include_next <minwindef.h>

#if defined(__cplusplus) && !defined(NOMINMAX)
#ifndef max
#define max(a, b) (((a) > (b)) ? (a) : (b))
#endif
#ifndef min
#define min(a, b) (((a) < (b)) ? (a) : (b))
#endif
#endif
EOF
        log "Extending minwindef.h with the C++ min/max macros MSVC defines"
      fi
      # flags-cflags.m4 sets these for every windows binary, but only in the
      # microsoft branch, so a clang windows build gets none of them:
      #   WIN32_LEAN_AND_MEAN  keeps windows.h from pulling in rpc.h, objbase.h
      #     and ole2.h, which define "interface" as a macro for struct. hotspot
      #     uses it as an identifier (opto/type.hpp has a bool parameter called
      #     interface), and undefining it once does not hold: a later windows.h
      #     in the same TU brings it back. MSVC's own windows.h leaves that
      #     definition to COM headers hotspot never asks for.
      #   WIN32 and IAL  from ALWAYS_DEFINES_JDK. Shared code tests WIN32 to pick
      #     the windows half of a #ifdef, so without it the unix half compiles:
      #     NativeFunc.h:37: fatal error: 'dlfcn.h' file not found
      #   -fms-extensions  clang parses the __try/__except guarding hotspot's
      #     memory probes only with MS extensions on.
      # NOMINMAX belongs here but goes to the JVM alone, further down: hotspot
      # wants windows.h's min/max gone so they cannot shadow std::min/std::max,
      # while the JDK libraries still use min() as a macro (ProcessImpl_md.c).
      WIN_DEFS="-DWIN32_LEAN_AND_MEAN -D_WIN32_WINNT=0x0602 -DWIN32 -DIAL"
      # -Wno-nonportable-include-path: the aliases above are exactly what that
      # warning is for, <Windows.h> resolving to a file named windows.h, so
      # it fires on every capitalised include in the tree, hundreds of times,
      # for something deliberate. Silencing it keeps real diagnostics findable.
      # The windows sources were written against MSVC, which takes mismatched
      # pointer types and implicit int conversions as warnings; clang 16 and
      # later reject them outright:
      #   java_md.c:705: error: incompatible pointer types passing 'int *' to
      #   parameter of type 'LPDWORD' (aka 'unsigned long *')
      # DWORD and int are both 32-bit on windows, so these are benign in fact,
      # and there are too many across the tree to hand-edit. Demote them to
      # warnings rather than silencing them, so they stay visible in the log.
      WIN_LAX="-Wno-error=incompatible-pointer-types -Wno-error=int-conversion"
      # hb.hh promotes 35 of its own warnings to errors with "#pragma GCC
      # diagnostic error", which no -Wno- on the command line can outrank:
      #   hb-meta.hh:131: error: unused function template [-Wunused-template]
      # Upstream's own off switch, set for every target but windows, since
      # windows meant a cl.exe that ignores GCC pragmas.
      WIN_HB="-DHB_NO_PRAGMA_GCC_DIAGNOSTIC"
      WIN_CFLAGS="-I$CASE_INC $WIN_DEFS -fms-extensions -Wno-nonportable-include-path $WIN_LAX $WIN_HB"

      # 11 keeps -std=gnu++98 only if it compiles with -Werror, which fails on
      # clang 22, leaving the JDK libraries at clang's default of C++17, where
      # the throw() in AWT's headers is gone:
      #   alloc.h:89: error: ISO C++17 does not allow dynamic exception
      #   specifications
      # Take the level 17 and later set for everything. cxxflags only: in
      # cflags it would fail every C compile.
      WIN_CXXSTD=""
      if [ "$JDK_VERSION" = 11 ]; then
        WIN_CXXSTD="-std=c++14"
      fi
      # 32-bit x86 only: hotspot reaches for SEH (__try/__except) in jni.cpp,
      # os_windows.cpp, os_windows_x86.cpp, safefetch_windows.hpp and
      # threadCrashProtection_windows.cpp. clang lowers those into MSVC-style
      # 32-bit SEH, but i686-w64-mingw32 defaults to the DWARF exception model,
      # whose asm printer never emits the tables the lowering refers to:
      #   error: assembler label 'L__ehtable$_JNI_CreateJavaVM@12' can not be
      #   undefined
      # Ask for the SEH model explicitly so the two halves agree. x86_64 and
      # aarch64 already default to SEH and build without this, so it is scoped to
      # the target that needs it rather than applied to all three.
      # Only SafeFetch and threadCrashProtection genuinely need __try semantics;
      # if this does not work, they are what stands between 21 and an i686 build.
      case "$TARGET" in
        i686-*) WIN_CFLAGS="$WIN_CFLAGS -fseh-exceptions" ;;
      esac
      EXTRA_CONF+=(--with-extra-cflags="$WIN_CFLAGS"
                   --with-extra-cxxflags="$WIN_CFLAGS $WIN_CXXSTD")
    fi

    # GetProcAddress returns FARPROC, a function pointer, and C++ has no
    # implicit conversion from one of those to void*. MSVC allows it as an
    # extension; clang does not:
    #   os_windows.cpp:1456: error: cannot initialize return object of type
    #   'void *' with an rvalue of type 'FARPROC'
    # Cast it, the way the same file already does elsewhere for GetProcAddress
    # results.
    # Windows libraries are listed MSVC-style throughout the build
    # (LIBS_windows := kernel32.lib ...), and mingw clang reads a bare foo.lib as
    # a filename ("no such file or directory: 'powrprof.lib'"). Translating at
    # each definition would mean touching hotspot and every java.* makefile, so
    # do it once where the link is set up.
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
      fetch_unpack "https://dl.google.com/android/repository/${NDK_NAME}-linux.zip" \
        "$ROOTDIR/ndk.zip" "$ROOTDIR"
    fi
    TC="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
    export CC="$TC/bin/${TARGET}${API}-clang" CXX="$TC/bin/${TARGET}${API}-clang++"
    EXTRA_CONF+=(--with-toolchain-type=clang AR="$TC/bin/llvm-ar" NM="$TC/bin/llvm-nm" STRIP="$TC/bin/llvm-strip" OBJCOPY="$TC/bin/llvm-objcopy" OBJDUMP="$TC/bin/llvm-objdump")
    TARGET_OS=linux
    ;;
  *) echo "Unknown/unsupported PLATFORM='$PLATFORM'" >&2; exit 1 ;;
esac

# --- tell configure what the build machine is -------------------------------
# config.guess probes the build system's libc by compiling with $CC, which is a
# cross compiler here, so it reports the builder as whatever we target. That
# breaks any target whose CPU matches the builder: for x86_64-linux-android the
# bogus build triple equals the host triple, configure calls it a native build,
# and host tools such as adlc come out as android binaries the build then tries
# to run ("adlc: cannot execute: required file not found"). Pass the real build
# triple so COMPILE_TYPE and every OPENJDK_BUILD_* value are derived correctly.
#
# It goes in as the autoconf --build/--host/--target set, not --openjdk-target:
# 8, 11 and 17 refuse the two together ("Specifying --openjdk-target together
# with autoconf legacy cross-compilation flags is not supported"), while all five
# accept the autoconf set on its own, which is what --openjdk-target expands to.
BUILD_TRIPLE="$(gcc -dumpmachine 2>/dev/null || clang -dumpmachine 2>/dev/null || true)"
[ -n "$BUILD_TRIPLE" ] || { echo "cannot determine the build triple (no gcc/clang?)" >&2; exit 1; }
EXTRA_CONF+=(--build="$BUILD_TRIPLE")

# --- bionic link stubs ------------------------------------------------------
# configure puts -lpthread and -lrt on the link line (libraries.m4: LIBPTHREAD,
# and the librt entry in BASIC_JVM_LIBS), and jdk8's makefiles hardcode -lpthread
# in several more places. bionic ships neither library: pthreads and the POSIX
# timers are part of libc. Rather than patch every reference in every release,
# put empty archives with those names on the link path, the linker resolves the
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
  # leaving the script's meaning intact for every symbol that is, cheaper than
  # patching version-script-clang.txt in each release.
  EXTRA_CONF+=(--with-extra-ldflags="-L$STUB_DIR -Wl,--undefined-version")

fi

# --- libffi (Zero only) -----------------------------------------------------
# Zero calls native code through libffi, and configure requires it whenever the
# variant is zero (libraries.m4: NEEDS_LIB_FFI). Unlike cups/fontconfig this one
# is genuinely linked, lib-ffi.m4 sets LIBFFI_LIBS=-lffi, and no cross sysroot
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
      fetch_unpack \
        "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz" \
        "$BUILD_DIR/libffi/libffi.tar.gz" "$FFI_SRC" --strip-components=1
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
  # just built instead, the .pc file installed alongside it carries the same
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
# configure requires cups and fontconfig everywhere but windows/macosx, and
# --enable-headless-only does not exempt them: libawt_headless compiles
# CUPSfuncs.c and fontpath.c. Neither is ever linked (configure exports only the
# *_CFLAGS, and both are dlopened at run time), so the headers are all that is
# needed, and being pure API they serve every target. X11 rides along: 11, 17 and
# 21 compile libawt against it whatever headless-only says, since rect.h includes
# <X11/Xlib.h>; only the headful libawt_xawt links the libraries. 25 dropped that
# include, where the extra -I is harmless.
#
# Stage them in a private include dir rather than passing /usr/include, whose -I
# would be searched ahead of the target's own libc headers. Pass -I directly and
# not through --x-includes: 17 and 25 answer "X11 not needed" and clear X_CFLAGS,
# dropping anything routed through configure's X11 support.
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
  # differs from glibc in ways that trip it, socklen_t is signed there, so
  # SctpNet.c fails on -Wpointer-sign. Turn errors back into warnings, matching
  # what every other release here is configured with.
  EXTRA_CFLAGS="-I$DEP_INC"
  [ "$JDK_VERSION" = 8 ] && EXTRA_CFLAGS="$EXTRA_CFLAGS -Wno-error"
  EXTRA_CONF+=(--with-cups-include="$DEP_INC" --with-fontconfig-include="$DEP_INC"
               --with-extra-cflags="$EXTRA_CFLAGS")
fi

# --- configure --------------------------------------------------------------
# autoconf has never heard of arm64ec: config.sub rejects the triple outright and
# platform.m4 would fold it into 32-bit arm, since only "aarch64" matches exactly
# and "arm*" catches the rest. ARM64EC is an ABI on ARM64, not a CPU, so the tree
# is configured as aarch64 and the arm64ec-prefixed compiler decides the ABI.
# Only the triple handed to autoconf changes; CC and the build directory keep the
# real one.
CONF_TRIPLE="$TARGET"
case "$ARCH" in
  arm64ec) CONF_TRIPLE="aarch64-${TARGET#*-}" ;;
esac
CONF="custom-$TARGET"
IMAGE_DIR="$SRC/build/$CONF/images/jdk"

# Flags common to every modern (11+) configure. Bundled libs keep the build
# self-contained per target; headless-only drops the X11/CUPS desktop deps.
common_conf=(
  --host="$CONF_TRIPLE"
  --target="$CONF_TRIPLE"
  --with-boot-jdk="$BOOT_JDK"
  --with-build-jdk="$BOOT_JDK"
  --with-jvm-variants="$JVM_VARIANT"
  --with-debug-level=release
  --with-native-debug-symbols=none
  --disable-warnings-as-errors
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

# headless-only is a unix idea: it exists to build without X11, and windows and
# macosx have their toolkits either way, so configure refuses the flag outright
# ("headless-only is not supported on macOS and Windows"). Ask for it only where
# it means something, which is also where the missing X11/ALSA sysroots make it
# necessary.
case "$TARGET_OS" in
  windows|macosx) ;;
  *) common_conf+=(--enable-headless-only) ;;
esac

# 21 and 22 deprecated windows-x86 but still build it, and configure stops on it:
#   configure: error: The Windows 32-bit x86 port is deprecated and may be
#   removed in a future release. Use --enable-deprecated-ports=yes to suppress
#   this error.
# The option is keyed on the tree actually having PLATFORM_CHECK_DEPRECATION, not
# on a version number: 17 and older never emit the error and would reject the
# unknown option, and 25 removed the port along with the check
# (see the version-conditional target list in make_jdk_windows.yml).
if [ "$TARGET_OS" = windows ] && [ "${TARGET%%-*}" = i686 ] &&
   grep -qr 'enable-deprecated-ports' "$SRC/make/autoconf" 2>/dev/null; then
  common_conf+=(--enable-deprecated-ports=yes)
fi

# 11 only: make images builds hotspot's gtest tests, and one puts a vector of an
# anonymous-namespace type through libc++, where the unqualified swap() in
# __split_buffer finds both std::swap and hotspot's global swap:
#   __split_buffer:195: error: call to 'swap' is ambiguous
# Nothing here runs those tests and they are not in the image, so switch them off
# rather than reconcile a libc++ internal with a hotspot header. 17 and later
# renamed the option, where passing it would be fatal as unknown.
if [ "$JDK_VERSION" = 11 ]; then
  common_conf+=(--disable-hotspot-gtest)
fi

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
  # jdk8u: legacy build system, same intent as common_conf above in a smaller,
  # differently spelled option set.
  #   --disable-headful  8's --enable-headless-only; also sets X11_NOT_NEEDED.
  #     Same targets as above: windows and macosx need no X11.
  #   --with-freetype=bundled  accepted on every target OS here (the other
  #     bundled-lib toggles are not), and without it configure hunts for a
  #     system freetype.
  #   --enable-unlimited-crypto  the JCE policy 11+ ships by default.
  #   BUILD_CC/BUILD_CXX  hotspot-spec.gmk.in maps BUILD_CXX onto HOSTCXX, which
  #     builds adlc, and hotspot hands that host tool the *target* compiler's
  #     flags; with the NDK clang as CXX it adds -flimit-debug-info and host g++
  #     refuses it. Building adlc with clang keeps flags and compiler agreeing.
  # --disable-warnings-as-errors and --with-build-user do not exist in 8, and
  # unknown options are fatal, so both are left off.
  conf8_headful=()
  case "$TARGET_OS" in
    windows|macosx) ;;
    *) conf8_headful=(--disable-headful) ;;
  esac
  bash ./configure \
    --host="$CONF_TRIPLE" \
    --target="$CONF_TRIPLE" \
    --with-boot-jdk="$BOOT_JDK" \
    --with-jvm-variants="$JVM_VARIANT" \
    --with-debug-level=release \
    --disable-debug-symbols \
    --with-freetype=bundled \
    --enable-unlimited-crypto \
    BUILD_CC=clang \
    BUILD_CXX=clang++ \
    "${conf8_headful[@]}" \
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
  # regardless, it wants glibc's <execinfo.h> backtrace(), which bionic has
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
