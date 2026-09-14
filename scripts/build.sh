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
    # aarch64, ppc, sparc, x86 and zero only, JDK 8's ARM32 JIT lived in
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
    # the fetched tree. 25 and 21 build and publish x86_64 and aarch64; i686 is
    # excluded for both (see make_jdk_windows.yml), 17 is in progress.
    TC=/opt/llvm-mingw
    export CC="$TC/bin/${TARGET}-clang" CXX="$TC/bin/${TARGET}-clang++"
    EXTRA_CONF+=(AR="$TC/bin/${TARGET}-ar" NM="$TC/bin/${TARGET}-nm" STRIP="$TC/bin/${TARGET}-strip" OBJCOPY="$TC/bin/${TARGET}-objcopy" OBJDUMP="$TC/bin/${TARGET}-objdump")
    export RC="$TC/bin/${TARGET}-windres"
    TARGET_OS=windows

    # Two configure assumptions keyed on the target OS rather than on the build
    # host or the compiler:
    #   basic.m4 runs BASIC_SETUP_PATHS_WINDOWS whenever the target is windows,
    #   and that macro wants cygpath or wslpath and a cmd.exe to run ("Incorrect
    #   linux installation. Neither cygpath nor wslpath was found"). None of it
    #   applies when the host is linux, so gate it on the host.
    #   toolchain.m4 allows only "microsoft" for windows targets, though the link
    #   layer below is keyed on TOOLCHAIN_TYPE: Link.gmk already has a clang
    #   branch, and LinkMicrosoft.gmk only supplies macros microsoft calls.
    for f in "$SRC/make/autoconf/basic.m4" "$SRC/common/autoconf/basic.m4"; do
      [ -f "$f" ] || continue
      grep -q '^  if test "x$OPENJDK_TARGET_OS" = "xwindows"; then$' "$f" || continue
      perl -0pi -e 's/^  if test "x\$OPENJDK_TARGET_OS" = "xwindows"; then\n    BASIC_SETUP_PATHS_WINDOWS\n  fi\n/  if test "x\$OPENJDK_TARGET_OS" = "xwindows" \&\& test "x\$OPENJDK_BUILD_OS" = "xwindows"; then\n    BASIC_SETUP_PATHS_WINDOWS\n  fi\n/m' "$f"
      log "Skipping the windows host-environment setup (cross build from linux)"
    done
    for f in "$SRC/make/autoconf/toolchain.m4" "$SRC/common/autoconf/toolchain.m4"; do
      [ -f "$f" ] || continue
      grep -q 'VALID_TOOLCHAINS_windows="microsoft"' "$f" || continue
      sed -i 's|VALID_TOOLCHAINS_windows="microsoft"|VALID_TOOLCHAINS_windows="microsoft clang"|' "$f"
      log "Allowing the clang toolchain for windows targets"
    done

    # Same shape again: lib-std.m4 hunts for the Visual Studio runtime DLLs to
    # bundle into the image whenever the target is windows, though they are a
    # microsoft-toolchain artifact:
    #   configure: error: Could not find . Please specify using --with-msvcr-dll
    # (the name is blank because MSVCR_NAME is only set by the VS detection that
    # never ran). mingw links the system msvcrt and carries its own runtime,
    # which -static folds in, so there is nothing to find or ship.
    for f in "$SRC/make/autoconf/lib-std.m4"; do
      [ -f "$f" ] || continue
      grep -q 'TOOLCHAIN_SETUP_VS_RUNTIME_DLLS' "$f" || continue
      perl -0pi -e 's/  if test "x\$OPENJDK_TARGET_OS" = "xwindows"; then\n    TOOLCHAIN_SETUP_VS_RUNTIME_DLLS\n  fi\n/  if test "x\$OPENJDK_TARGET_OS" = "xwindows" \&\& test "x\$TOOLCHAIN_TYPE" = "xmicrosoft"; then\n    TOOLCHAIN_SETUP_VS_RUNTIME_DLLS\n  fi\n/m' "$f"
      grep -q 'xmicrosoft"; then' "$f" &&
        log "Skipping the Visual Studio runtime DLLs (mingw has none)"
    done

    # Consequence of skipping the windows host setup: it is also what defines
    # FIXPATH_BASE, the helper that rewrites unix paths into windows ones.
    # MakeBase.gmk reaches for it on any windows target, so the command
    # collapses to a bare "convert" and the build tools fail:
    #   /usr/bin/bash: line 1: convert: command not found
    # Cross-compiling from linux, there is nothing to rewrite: every tool in
    # the build is a linux executable taking linux paths, so fall through to
    # the identity definitions the other platforms use, but only when
    # FIXPATH_BASE is genuinely absent, leaving a real windows host untouched.
    MB="$SRC/make/common/MakeBase.gmk"
    if [ -f "$MB" ] && grep -q 'FIXPATH_BASE' "$MB"; then
      # The line occurs exactly once in 11 through 25, so no first-match dance.
      perl -pi -e 's/^ifeq \(\$\(call isTargetOs, windows\), true\)$/ifeq (\$(call isTargetOs, windows)\$(if \$(FIXPATH_BASE),,-nofixpath), true)/' "$MB"
      grep -q 'nofixpath' "$MB" &&
        log "Using identity FixPath (no fixpath helper in a cross build)"
    fi

    # GenerateLinkOptData.gmk depends on the *build* JDK's launcher but spells
    # it with the *target* executable suffix:
    #   $(CLASSLIST_FILE): $(INTERIM_IMAGE_DIR)/bin/java$(EXECUTABLE_SUFFIX)
    # With --with-build-jdk pointing at the linux JDK that runs here, that asks
    # for a java.exe which does not and should not exist:
    #   No rule to make target '/work/boot-jdk/bin/java.exe'
    # The recipe below it already invokes .../bin/java unsuffixed, so the
    # dependency is simply the odd one out. Drop the suffix from both
    # dependency lines. Safe here because this repository only ever cross-builds
    # windows from linux; a windows-hosted build would still want the .exe.
    GLOD="$SRC/make/GenerateLinkOptData.gmk"
    if [ -f "$GLOD" ] && grep -q 'bin/java\$(EXECUTABLE_SUFFIX)' "$GLOD"; then
      perl -pi -e 's/\/bin\/java\$\(EXECUTABLE_SUFFIX\)/\/bin\/java/g' "$GLOD"
      log "Depending on the build JDK's launcher without a .exe suffix"
    fi

    # mingw's SDK headers are all lowercase, while windows code conventionally
    # writes <Windows.h>, <WinSock2.h>, <Psapi.h> and so on. MSVC never notices,
    # because NTFS is case-insensitive; here every one of them fails:
    #   fatal error: 'Windows.h' file not found
    # 162 files include <Windows.h> alone, so alias rather than edit: collect the
    # capitalised spellings the sources actually use, symlink each to the real
    # lowercase header, and put that directory on the include path. The
    # toolchain's own include dir is root-owned and not ours to write into.
    CASE_INC="$BUILD_DIR/mingw-case-include"
    MINGW_INC="$TC/$TARGET/include"
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
    LNK="$SRC/make/common/native/Link.gmk"
    if [ -f "$LNK" ] && grep -q '_STRIPFLAGS ?= $(STRIPFLAGS)' "$LNK"; then
      awk '
        { print }
        !done && index($0, "_STRIPFLAGS ?= $(STRIPFLAGS)") {
          print ""
          print "  # mingw wants -lfoo where MSVC wants foo.lib."
          print "  ifeq ($(call isTargetOs, windows)-$(TOOLCHAIN_TYPE), true-clang)"
          print "    $1_LIBS := $$(patsubst %.lib,-l%,$$($1_LIBS))"
          print "    $1_EXTRA_LIBS := $$(patsubst %.lib,-l%,$$($1_EXTRA_LIBS))"
          print "    # -stack:N is link.exe'\''s spelling of --stack. LDFLAGS_windows"
          print "    # arrives in EXTRA_LDFLAGS, so both have to be translated."
          print "    $1_LDFLAGS := $$(patsubst -stack:%,-Wl$$(COMMA)--stack$$(COMMA)%,$$($1_LDFLAGS))"
          print "    $1_EXTRA_LDFLAGS := $$(patsubst -stack:%,-Wl$$(COMMA)--stack$$(COMMA)%,$$($1_EXTRA_LDFLAGS))"
          print "  endif"
          done = 1
        }
      ' "$LNK" > "$LNK.tmp" && mv "$LNK.tmp" "$LNK"
      log "Translating foo.lib into -lfoo for the mingw linker"
    fi

    # Same translation for 17 and 21, which have no make/common/native/: the link
    # is set up inside SetupNativeCompilation in NativeCompilation.gmk instead, so
    # the block above finds no file and hotspot's own library list reaches clang
    # untranslated:
    #   clang: error: no such file or directory: 'kernel32.lib'
    # The anchor is the end of the LIBS assembly, the point Link.gmk's
    # _STRIPFLAGS line marks on 25: after the per-OS and per-toolchain lists are
    # folded in, before the link command is built. 21 spells that over two lines
    # (the second folding in _$(TOOLCHAIN_TYPE)), 17 has no such variants. Match
    # whichever line ends the statement so the block lands after the whole list
    # either way.
    NC="$SRC/make/common/NativeCompilation.gmk"
    if [ -f "$NC" ] && grep -q '\$1_EXTRA_LIBS += \$\$(\$1_LIBS_\$(OPENJDK_TARGET_OS_TYPE))' "$NC" &&
       ! grep -q 'mingw wants -lfoo' "$NC"; then
      awk '
        { print }
        !done && index($0, "_LIBS_$(OPENJDK_TARGET_OS") && substr($0, length($0)) != "\\" {
          print ""
          print "  # mingw wants -lfoo where MSVC wants foo.lib."
          print "  ifeq ($(call isTargetOs, windows)-$(TOOLCHAIN_TYPE), true-clang)"
          print "    # Only the bare names. 21 also lists inter-module dependencies as"
          print "    # whole paths -- FindStaticLib spells libjava as"
          print "    # $(SUPPORT_OUTPUTDIR)/native/java.base/libjava/java.lib -- and"
          print "    # -l<absolute path> is not a name lld can look up. Those entries are"
          print "    # the import library another module already built, so let clang link"
          print "    # the file directly, which is what MSVC is handed as well."
          print "    $1_LIBS := $$(foreach lib,$$($1_LIBS),$$(if $$(findstring /,$$(lib)),$$(lib),$$(patsubst %.lib,-l%,$$(lib))))"
          print "    $1_EXTRA_LIBS := $$(foreach lib,$$($1_EXTRA_LIBS),$$(if $$(findstring /,$$(lib)),$$(lib),$$(patsubst %.lib,-l%,$$(lib))))"
          print "    # -stack:N is link.exe'\''s spelling of --stack. LDFLAGS_windows"
          print "    # arrives in EXTRA_LDFLAGS, so both have to be translated."
          print "    $1_LDFLAGS := $$(patsubst -stack:%,-Wl$$(COMMA)--stack$$(COMMA)%,$$($1_LDFLAGS))"
          print "    $1_EXTRA_LDFLAGS := $$(patsubst -stack:%,-Wl$$(COMMA)--stack$$(COMMA)%,$$($1_EXTRA_LDFLAGS))"
          print "    # -libpath:<dir> is link.exe'\''s -L. 25 centralises this in"
          print "    # JdkNativeCompilation.gmk, which is where the block above patches it;"
          print "    # 21 has no -libpath: there at all and spells it per library instead,"
          print "    # so translate it here, wherever it came from."
          print "    $1_LDFLAGS := $$(patsubst -libpath:%,-L%,$$($1_LDFLAGS))"
          print "    $1_EXTRA_LDFLAGS := $$(patsubst -libpath:%,-L%,$$($1_EXTRA_LDFLAGS))"
          print "  endif"
          done = 1
        }
      ' "$NC" > "$NC.tmp" && mv "$NC.tmp" "$NC"
      grep -q '^    \$1_LIBS := \$\$(foreach lib,\$\$(\$1_LIBS),' "$NC" || {
        echo "failed to translate foo.lib in NativeCompilation.gmk" >&2; exit 1; }
      log "Translating foo.lib into -lfoo for the mingw linker (17/21 makefiles)"
    fi

    # java.base builds; the modules that link against it do not:
    #   lld: error: unable to find library -ljava
    # 21's libraries.m4 hands every non-microsoft toolchain
    #   BASIC_JDKLIB_LIBS="-ljava -ljvm"
    # which is the unix way of naming those two, keyed on the toolchain when what
    # it describes is the target: on windows the module makefiles already list
    # them, as $(WIN_JAVA_LIB), a full path to java.lib, and jvm.lib, so
    # mingw needs the empty value microsoft gets, not the unix one. 25 dropped
    # JDKLIB_LIBS entirely.
    LM4="$SRC/make/autoconf/libraries.m4"
    if [ -f "$LM4" ] && grep -q '^  if test "x\$TOOLCHAIN_TYPE" != xmicrosoft; then$' "$LM4"; then
      sed -i 's/^  if test "x\$TOOLCHAIN_TYPE" != xmicrosoft; then$/  if test "x$TOOLCHAIN_TYPE" != xmicrosoft \&\& test "x$OPENJDK_TARGET_OS" != xwindows; then/' "$LM4"
      grep -q 'test "x\$OPENJDK_TARGET_OS" != xwindows; then' "$LM4" || {
        echo "failed to drop the unix JDKLIB_LIBS for a windows target" >&2; exit 1; }
      log "Leaving JDKLIB_LIBS empty on windows, as the microsoft path has it"
    fi

    # Every library that declares no CXXFLAGS gets the C ones copied verbatim,
    # and -std=c11 is a C-only flag:
    #   error: invalid argument '-std=c11' not allowed with 'C++'
    # on libawt's CmdIDList.cpp. libawt is C everywhere but windows, where half
    # of it is C++, and it names only CFLAGS, which upstream gets away with
    # because cl.exe ignores -std:c11 on a C++ file rather than refusing it, and
    # because a unix library with C++ sources always sets CXXFLAGS or gcc would
    # have failed the same way. Swap the language standard as the flags are
    # copied, to the same C++ level 21 asks for elsewhere (LANGSTD_CXXFLAGS is
    # -std=c++14 there), rather than editing each library that has this shape.
    if [ -f "$NC" ] && grep -q '^    \$1_CXXFLAGS := \$\$(\$1_CFLAGS)$' "$NC"; then
      awk '
        $0 == "    $1_CXXFLAGS := $$($1_CFLAGS)" {
          print
          print "    # -std=c99 (17) and -std=c11 (21) are C-only; clang refuses them"
          print "    # on C++ sources, and a windows-only C++ library declares CFLAGS"
          print "    # alone because cl.exe accepts the C standard flag and ignores it."
          print "    ifeq ($(call isTargetOs, windows)-$(TOOLCHAIN_TYPE), true-clang)"
          print "      $1_CXXFLAGS := $$(patsubst -std=c11,-std=c++14,$$(patsubst -std=c99,-std=c++14,$$($1_CXXFLAGS)))"
          print "    endif"
          next
        }
        $0 == "    $1_EXTRA_CXXFLAGS := $$($1_EXTRA_CFLAGS)" {
          print
          print "    ifeq ($(call isTargetOs, windows)-$(TOOLCHAIN_TYPE), true-clang)"
          print "      $1_EXTRA_CXXFLAGS := $$(patsubst -std=c11,-std=c++14,$$(patsubst -std=c99,-std=c++14,$$($1_EXTRA_CXXFLAGS)))"
          print "    endif"
          next
        }
        { print }
      ' "$NC" > "$NC.tmp" && mv "$NC.tmp" "$NC"
      grep -q 'patsubst -std=c11,-std=c++14' "$NC" || {
        echo "failed to swap the C standard flag for C++ sources in NativeCompilation.gmk" >&2; exit 1; }
      log "Compiling C++ sources with the C++ standard when a library names only CFLAGS"
    fi

    # The translated names then have to match a file. MSVC resolves library
    # names case-insensitively on a case-insensitive filesystem; mingw ships
    # libmswsock.a and the build host is linux, so a capitalised name finds
    # nothing:
    #   Lib.gmk: LIBS_windows := jvm.lib Mswsock.lib ws2_32.lib
    #   lld: error: unable to find library -lMswsock
    # 25 lowercased these upstream; 21 still has Mswsock.lib in java.base and
    # Secur32.lib twice in java.security.jgss, so sweep the makefiles once. A
    # match must start a line or follow whitespace, which leaves path-valued
    # entries like $(SUPPORT_OUTPUTDIR)/.../net.lib alone.
    win_lib_case=0
    while IFS= read -r f; do
      grep -qE '(^|[[:space:]])[A-Za-z0-9_]*[A-Z][A-Za-z0-9_]*\.lib' "$f" || continue
      sed -i -E 's#(^|[[:space:]])([A-Za-z0-9_]*[A-Z][A-Za-z0-9_]*)\.lib#\1\L\2\E.lib#g' "$f"
      win_lib_case=$((win_lib_case + 1))
    done < <(find "$SRC/make" -name '*.gmk')
    if [ "$win_lib_case" -gt 0 ]; then
      if grep -rqE '(^|[[:space:]])[A-Za-z0-9_]*[A-Z][A-Za-z0-9_]*\.lib' "$SRC/make" --include='*.gmk'; then
        echo "failed to lowercase every MSVC library name in the makefiles" >&2; exit 1
      fi
      log "Lowercasing the MSVC library names in $win_lib_case makefiles"
    fi

    # Same casing problem, but coming from the sources rather than the
    # makefiles. 17 asks for the library from inside the C file:
    #   FileChannelImpl.c: #pragma comment(lib, "Mswsock.lib")
    # clang honours that pragma on windows targets and emits a linker request,
    # which lld resolves against mingw's lowercase libmswsock.a:
    #   ld.lld: error: could not open 'libMswsock.a': No such file or directory
    # 21 dropped the pragma and names the library in the makefile instead, where
    # the sweep above already reaches it. Lowercase these the same way. The name
    # is taken whole, between the quotes: the suffix is optional in this pragma
    # and jpackage writes both spellings, "Mswsock.lib" in java.base, bare
    # "Shell32" and "user32" of its own, so anything narrower rewrites some of
    # them and leaves the rest to fail at the next link.
    win_pragma_case=0
    while IFS= read -r f; do
      sed -i -E 's|(pragma comment\(lib, ")([^"]*)(")|\1\L\2\E\3|g' "$f"
      win_pragma_case=$((win_pragma_case + 1))
    done < <(grep -rlE '#pragma comment\(lib, "[^"]*[A-Z]' "$SRC/src" \
               --include='*.c' --include='*.cpp' --include='*.h' 2>/dev/null)
    if [ "$win_pragma_case" -gt 0 ]; then
      grep -rqE '#pragma comment\(lib, "[^"]*[A-Z]' "$SRC/src" \
        --include='*.c' --include='*.cpp' --include='*.h' && {
        echo "failed to lowercase every #pragma comment(lib) name" >&2; exit 1; }
      log "Lowercasing the MSVC library names in $win_pragma_case sources"
    fi

    # JdkNativeCompilation.gmk picks the flag spelling for module libraries by
    # OS: -libpath:<dir> and name.lib for windows, -L<dir> and -lname
    # otherwise. lld in GNU mode reads -libpath:... as -l ibpath:...:
    #   lld: error: unable to find library -libpath:.../modules_libs/java.base
    #   lld: error: unable to find library -ljvm
    # mingw wants the unix flag spelling with the windows file naming, and
    # lld's mingw mode does search for <name>.lib, which is what the import
    # libraries are called. Split the choice by toolchain and leave LIBFILE,
    # the make dependency, named as before.
    JNC="$SRC/make/common/JdkNativeCompilation.gmk"
    if [ -f "$JNC" ] && grep -q 'LDFLAGS += -libpath:' "$JNC"; then
      awk '
        skip > 0 { skip--; next }
        index($0, "ifeq ($$(filter -libpath:$$($1_$2_LIBPATH), $$($1_LDFLAGS)), )") {
          print "      ifeq ($(TOOLCHAIN_TYPE), microsoft)"
          print "        ifeq ($$(filter -libpath:$$($1_$2_LIBPATH), $$($1_LDFLAGS)), )"
          print "          $1_LDFLAGS += -libpath:$$($1_$2_LIBPATH)"
          print "        endif"
          print "        $1_LIBS += $$($1_$2_NAME)$(STATIC_LIBRARY_SUFFIX)"
          print "      else"
          print "        ifeq ($$(filter -L$$($1_$2_LIBPATH), $$($1_LDFLAGS)), )"
          print "          $1_LDFLAGS += -L$$($1_$2_LIBPATH)"
          print "        endif"
          print "        $1_LIBS += -l$$($1_$2_NAME)"
          print "      endif"
          skip = 3
          next
        }
        { print }
      ' "$JNC" > "$JNC.tmp" && mv "$JNC.tmp" "$JNC"
      log "Using -L/-l instead of -libpath: for the module libraries"
    fi

    # jvm.dll links, and then everything that depends on it cannot:
    #   No rule to make target '.../modules_libs/java.base/jvm.lib', needed by
    #   '.../verify.dll'
    # MSVC emits an import library beside every DLL, and the build copies
    # jvm.lib into place for the java.* libraries to link against.
    # LinkMicrosoft.gmk arranges that with -implib: and a rule to retrigger
    # dependants; the generic Link.gmk has no equivalent, because on ELF there
    # is nothing to emit. mingw will produce one on request, so ask for it under
    # the same name the rest of the build already expects.
    if [ -f "$LNK" ] && ! grep -q 'out-implib' "$LNK"; then
      awk '
        { print }
        !done && $0 == "define CreateDynamicLibraryOrExecutable" {
          print "  # mingw emits an import library only when asked; MSVC always does,"
          print "  # and the rest of the build expects one to exist."
          print "  ifeq ($(call isTargetOs, windows)-$(TOOLCHAIN_TYPE), true-clang)"
          print "    ifeq ($$($1_TYPE), LIBRARY)"
          print "      $1_IMPORT_LIBRARY := $$($1_OBJECT_DIR)/$$($1_NAME).lib"
          print "      $1_EXTRA_LDFLAGS += -Wl,--out-implib=$$($1_IMPORT_LIBRARY)"
          print ""
          print "      $$($1_IMPORT_LIBRARY): $$($1_TARGET)"
          printf "\t$(TOUCH) $$@\n"
          print ""
          print "      $1 += $$($1_IMPORT_LIBRARY)"
          print "    endif"
          print "  endif"
          print ""
          done = 1
        }
      ' "$LNK" > "$LNK.tmp" && mv "$LNK.tmp" "$LNK"
      log "Emitting import libraries for the mingw DLL links"
    fi

    # CompileJvm.gmk lists jvm.dll's vftable exports in a .def built by running
    # MSVC's dumpbin over the objects, then passes it as -def:. Neither the tool
    # nor the flag spelling exists here ("[.../win-exports.def] Error 127"), and
    # both are guarded on the target OS rather than the toolchain. mingw exports
    # the JNIEXPORT entry points from __declspec(dllexport) anyway; the .def only
    # adds vftable symbols for debugging tools.
    CJ="$SRC/make/hotspot/lib/CompileJvm.gmk"
    if [ -f "$CJ" ] && grep -q 'JVM_LDFLAGS += -def:\$(WIN_EXPORT_FILE)' "$CJ"; then
      perl -0pi -e 's/^  JVM_LDFLAGS \+= -def:\$\(WIN_EXPORT_FILE\)$/  ifeq (\$(TOOLCHAIN_TYPE), microsoft)\n    JVM_LDFLAGS += -def:\$(WIN_EXPORT_FILE)\n  endif/m' "$CJ"
      perl -0pi -e 's/^  \$\(BUILD_LIBJVM_TARGET\): \$\(WIN_EXPORT_FILE\)$/  ifeq (\$(TOOLCHAIN_TYPE), microsoft)\n    \$(BUILD_LIBJVM_TARGET): \$(WIN_EXPORT_FILE)\n  endif/m' "$CJ"
      log "Skipping the dumpbin-generated jvm.dll export file"
    fi

    # 21 reaches dumpbin by the other road. 25 deleted make/hotspot/lib/JvmMapfile.gmk
    # outright, but on 21 it still builds an EXPORTS mapfile for windows out of
    #   DUMP_SYMBOLS_CMD := $(DUMPBIN) -symbols *$(OBJ_SUFFIX)
    # and CompileJvm.gmk hands it to the link as MAPFILE, which becomes -def::
    #   JvmMapfile.gmk:133: [.../symbols-objects] Error 127
    # Same reasoning as the block above, so take the same reduction rather than
    # reimplementing the symbol dump on llvm-nm: the mapfile's contents are
    # vftable symbols for debugging tools, and mingw exports the JNI entry points
    # from __declspec(dllexport) on its own.
    # The whole file exists only to produce JVM_MAPFILE and nothing else consumes
    # its targets, so emptying that variable and skipping the include removes
    # the dumpbin call and leaves no rule with an empty target behind. Keyed on
    # the DUMPBIN branch actually being there, which is what 25 lacks.
    JMF="$SRC/make/hotspot/lib/JvmMapfile.gmk"
    if [ -f "$CJ" ] && [ -f "$JMF" ] && grep -q 'DUMP_SYMBOLS_CMD := \$(DUMPBIN)' "$JMF"; then
      awk '
        $0 == "JVM_MAPFILE := $(JVM_OUTPUTDIR)/mapfile" {
          print
          print "ifeq ($(OPENJDK_TARGET_OS), windows)"
          print "  ifneq ($(TOOLCHAIN_TYPE), microsoft)"
          print "    # The windows mapfile is dumpbin output; mingw exports from dllexport."
          print "    JVM_MAPFILE :="
          print "  endif"
          print "endif"
          next
        }
        $0 == "include lib/JvmMapfile.gmk" {
          print "ifneq ($(JVM_MAPFILE), )"
          print "  include lib/JvmMapfile.gmk"
          print "endif"
          next
        }
        { print }
      ' "$CJ" > "$CJ.tmp" && mv "$CJ.tmp" "$CJ"
      grep -q '^    JVM_MAPFILE :=$' "$CJ" && grep -q '^ifneq (\$(JVM_MAPFILE), )$' "$CJ" || {
        echo "failed to skip the dumpbin mapfile in CompileJvm.gmk" >&2; exit 1; }
      log "Skipping the dumpbin-generated jvm.dll mapfile"
    fi

    # Per-library makefiles spell windows compiler flags in MSVC's dialect, keyed
    # on the target OS rather than the toolchain:
    #   AwtLibraries.gmk: CFLAGS_windows := -EHsc ...
    #   clang: error: unknown argument: '-EHsc'
    # None has a cl.exe-independent meaning; clang's defaults already do what
    # each asks for. Strip them in one pass rather than one build failure at a
    # time. Three traps, each paid for once:
    #   -MD/-MT all select a cl.exe runtime here (checked every occurrence), but
    #   clang's -MT takes an argument, so leaving it in silently ate the define
    #   after it in "CXXFLAGS := -MT -DACCESSBRIDGE_ARCH_64".
    #   A comma ends an argument in these makefiles, so it must terminate -Zc:'s
    #   value. Eating the comma in "CXXFLAGS_FILTER_OUT := -Zc:wchar_t-," merged
    #   that argument with the next, costing jabswitch its whole flag list.
    #   cl.exe takes - and / alike and the JDK mixes them (21 has /Gy where 25
    #   has -Gy), so both spellings match. Whole tokens only, which leaves
    #   MakeBase's "mklink /J" and absolute paths alone.
    MSVC_ONLY='EHsc|EHa|wd[0-9]+|Zc:[^ ),]+|Z[i7]|permissive-|utf-8|nologo'
    MSVC_ONLY="$MSVC_ONLY|guard:cf|FS|GS|Gy|GR|Gd|Gm-?|Od|Ob[0-9]|Oi|Ot|Oy-?"
    MSVC_ONLY="$MSVC_ONLY|RTC[1csu]+|MP|W[0-4]|WX-?|analyze-?|sdl-?|MD|MT"
    if [ -d "$SRC/make" ]; then
      msvc_files=$(grep -rlE "(^|[[:space:]])[-/]($MSVC_ONLY)([[:space:],]|$)" \
                     --include='*.gmk' "$SRC/make" 2>/dev/null || true)
      if [ -n "$msvc_files" ]; then
        # Twice: a removed flag takes its trailing space with it, so adjacent
        # flags (-EHsc -wd4244) are not both seen in a single pass.
        for _ in 1 2; do
          printf '%s\n' "$msvc_files" | xargs sed -E -i \
            "s/(^|[[:space:]])[-\\/]($MSVC_ONLY)([[:space:],]|$)/\\1\\3/g"
        done
        log "Dropped MSVC-only compiler flags from $(printf '%s\n' "$msvc_files" | wc -l) makefiles"
      fi
    fi

    # The sweep above takes whole tokens, so it cannot reach a link.exe flag
    # that carries a value:
    #   clang: error: unknown argument: '-map:.../jdk.pack/unpack.map'
    # That map is a link.exe listing nothing in the build reads back. Only
    # jdk.pack asks for one, and 14 deleted jdk.pack, so this is 11 and 8.
    if [ -d "$SRC/make" ]; then
      map_files=$(grep -rlE '[-/]map:' --include='*.gmk' "$SRC/make" 2>/dev/null || true)
      if [ -n "$map_files" ]; then
        printf '%s\n' "$map_files" | xargs sed -E -i \
          "s/(^|[[:space:]])[-\\/]map:[^ ,]*/\\1/g"
        log "Dropped the link.exe map flag from $(printf '%s\n' "$map_files" | wc -l) makefiles"
      fi
    fi

    # The .rc itself compiles, but RC cannot report its own includes, so the
    # build re-runs the resource through the C compiler to harvest a dependency
    # list, in MSVC's dialect and without asking the toolchain:
    #   clang: error: unknown argument: '-showIncludes'
    # Nothing worth reconstructing: that .d only lets an incremental rebuild
    # notice an edited .rc header, and every build here starts from a fresh tree.
    # The block is identical in 25's make/common/native/CompileFile.gmk and 21's
    # NativeCompilation.gmk, so look in whichever file has it.
    for CFG in "$SRC/make/common/native/CompileFile.gmk" \
               "$SRC/make/common/NativeCompilation.gmk"; do
      [ -f "$CFG" ] || continue
      grep -q 'Windows RC compiler does not support' "$CFG" || continue
      awk '
        /# Windows RC compiler does not support -showIncludes/ { drop = 1 }
        drop && /> \$\$\(\$1_RES_DEPS_TARGETS_FILE\)/ { drop = 0; next }
        drop { next }
        { print }
      ' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
      if grep -q -- '-Fi\$\$(\$1_RES_DEPS_FILE)' "$CFG"; then
        echo "resource dependency scan still present in $(basename "$CFG")" >&2; exit 1
      fi
      log "Dropping the CL-based dependency scan for windows resource files"
    done

    # libawt's alloc.h declares its own std::bad_alloc rather than including
    # <new>, to keep awt.dll from depending on msvcp50.dll, a saving the
    # comment there puts at 500kb, and a concern that has not applied to any
    # toolchain in twenty years. It does apply here, as a hard error:
    #   alloc.h:35: error: redefinition of 'bad_alloc'
    # because mingw's C++ headers have already defined the real one by this
    # point. Include <new> and let the class come from where it belongs.
    ALC="$SRC/src/java.desktop/windows/native/libawt/windows/alloc.h"
    if [ -f "$ALC" ] && grep -q 'class bad_alloc {};' "$ALC"; then
      perl -0pi -e 's/namespace std \{\n    class bad_alloc \{\};\n\}/#include <new>/' "$ALC"
      if grep -q 'class bad_alloc {};' "$ALC"; then
        echo "failed to replace the local std::bad_alloc in alloc.h" >&2; exit 1
      fi
      log "Taking std::bad_alloc from <new> in libawt's alloc.h"
    fi

    # The other half of that: awt_DnDDS.cpp renames the STL's bad_alloc to
    # zbad_alloc across its <new> and <map> includes, so the STL copy could
    # coexist with the one alloc.h used to declare. With alloc.h now taking the
    # real one, that rename hides it instead:
    #   awt.h:274: error: no member named 'bad_alloc' in namespace 'std';
    #   did you mean 'zbad_alloc'?
    # The rename exists only to avoid the duplicate that no longer happens.
    for f in $(grep -rl '#define bad_alloc zbad_alloc' "$SRC/src/java.desktop" 2>/dev/null || true); do
      perl -ni -e 'print unless /^#define bad_alloc zbad_alloc$/' "$f"
      log "Dropping the zbad_alloc rename in $(basename "$f")"
    done

    # ToUnicodeEx writes UTF-16 code units into a WORD[2] and is declared to
    # take LPWSTR. Both are 16-bit unsigned on windows, and C++ still refuses
    # the conversion:
    #   awt_Component.cpp:3596: error: cannot initialize a parameter of type
    #   'LPWSTR' (aka 'wchar_t *') with an lvalue of type 'WORD[2]'
    # MSVC accepts it because the JDK builds with wchar_t as a typedef for
    # unsigned short rather than a distinct type. clang can be told the same
    # thing (-fno-wchar), but that changes C++ mangling for every translation
    # unit it touches, which is not a thing to do to one call site. Cast.
    AWC="$SRC/src/java.desktop/windows/native/libawt/windows/awt_Component.cpp"
    if [ -f "$AWC" ] && grep -q '^ *wChar, 2, 0, GetKeyboardLayout());' "$AWC"; then
      perl -0pi -e 's/^(\s+)wChar, 2, 0, GetKeyboardLayout\(\)\);/$1(LPWSTR)wChar, 2, 0, GetKeyboardLayout());/m' "$AWC"
      log "Casting the ToUnicodeEx buffer in awt_Component.cpp"
    fi

    # awt_ole.h reaches for the COM smart pointers, IStreamPtr and friends:
    #   awt_DnDDT.cpp:819: error: unknown type name 'IStreamPtr'
    # MSVC declares those in comdef.h. mingw has them too, in comdefsp.h, but
    # that file disables itself unless USE___UUIDOF is 1, and _mingw.h sets that
    # only for MSVC, everyone else gets the template-based __uuidof emulation
    # instead, which comdefsp.h was never taught about. Declare the ones this
    # tree actually names, with comdef.h's own macro, so the emulation is what
    # ends up being used. Each is guarded the way comdefsp.h guards its own, so
    # an interface whose header has not been reached yet stays a visible error
    # rather than a silently missing typedef.
    OLEH="$SRC/src/java.desktop/windows/native/libawt/windows/awt_ole.h"
    if [ -f "$OLEH" ] && ! grep -q '_COM_SMARTPTR_TYPEDEF' "$OLEH"; then
      COM_PTRS="$BUILD_DIR/com-smartptrs.h"
      : > "$COM_PTRS"
      grep -rhoE '\bI[A-Za-z0-9_]+Ptr\b' "$SRC/src/java.desktop/windows" 2>/dev/null \
        | sed 's/Ptr$//' | sort -u \
        | while read -r iface; do
            printf '#if defined(__%s_INTERFACE_DEFINED__)\n_COM_SMARTPTR_TYPEDEF(%s, __uuidof(%s));\n#endif\n' \
              "$iface" "$iface" "$iface" >> "$COM_PTRS"
          done
      if [ -s "$COM_PTRS" ]; then
        awk -v ptrs="$COM_PTRS" '
          { print }
          !done && $0 == "#include <comutil.h>" {
            print ""
            print "// mingw ships these in comdefsp.h but compiles it out for non-MSVC."
            while ((getline line < ptrs) > 0) print line
            close(ptrs)
            done = 1
          }
        ' "$OLEH" > "$OLEH.tmp" && mv "$OLEH.tmp" "$OLEH"
        grep -q '_COM_SMARTPTR_TYPEDEF' "$OLEH" || {
          echo "failed to add the COM smart pointer typedefs to awt_ole.h" >&2; exit 1; }
        log "Declaring $(grep -c _COM_SMARTPTR_TYPEDEF "$COM_PTRS") COM smart pointers in awt_ole.h"
      fi
    fi

    # sspi.cpp defines the gss_* entry points with __declspec(dllexport) while
    # gssapi.h has already declared them without it. MSVC allows an export
    # attribute to appear only on the definition; clang rejects it once the
    # earlier declaration has been used, which is why exactly the seven
    # functions called from higher up in the file failed:
    #   error: redeclaration of 'gss_release_cred' cannot add 'dllexport'
    # Drop the attribute from all of them. It is the only file in the library,
    # so with no explicit exports left, mingw falls back to exporting every
    # symbol, which is what a bridge DLL resolved through GetProcAddress
    # needs anyway.
    SSPI="$SRC/src/java.security.jgss/windows/native/libsspi_bridge/sspi.cpp"
    if [ -f "$SSPI" ] && grep -q '^__declspec(dllexport) ' "$SSPI"; then
      log "Dropping $(grep -c '^__declspec(dllexport) ' "$SSPI") dllexport attributes from sspi.cpp"
      sed -i 's/^__declspec(dllexport) //' "$SSPI"
    fi

    # The SSPI package names AcquireCredentialsHandleW wants as LPWSTR are cast
    # by the JDK-8281525 backport in patches/global/jdk/11.

    # jaccessinspectorWindow.rc names its menu cjaccessinspectorMenus, which no
    # header defines, the resource header still calls it cFerretMenus, from
    # before the tool was renamed. MSVC's rc quietly treats an unknown
    # identifier as a string resource name; llvm-rc does not:
    #   llvm-rc: Error parsing file: expected int or string, got
    #   cjaccessinspectorMenus
    # Quote it, as MSVC did, but only where the dialog refers to the menu
    # ("MENU <name>"), not where the menu declares itself ("<name> MENU"):
    # llvm-rc wants an int or string for the reference and an int or identifier
    # for the declaration, so quoting the wrong one trades one parse error for
    # another. Only genuinely undefined names are touched, since quoting a macro
    # would turn an integer id into a string one.
    for rc in "$SRC"/src/jdk.accessibility/windows/native/*/*.rc; do
      [ -f "$rc" ] || continue
      for tok in $(sed -nE 's/^MENU ([A-Za-z_][A-Za-z0-9_]*)$/\1/p' "$rc" | sort -u); do
        if grep -rqE "^#define[[:space:]]+$tok\b" "$SRC/src/jdk.accessibility"; then
          continue
        fi
        sed -i -E "s/^MENU $tok\$/MENU \"$tok\"/" "$rc"
        log "Quoting the undefined menu reference $tok in $(basename "$rc")"
      done
    done

    # splashscreen_sys.c calls alloca without including <malloc.h>, where both
    # MSVC and mingw declare it, MSVC's windows.h chain happens to pull it in:
    #   splashscreen_sys.c:147: error: use of undeclared identifier 'alloca'
    # The include alone is not enough: mingw hides the unprefixed spelling behind
    # NO_OLDNAMES, which _mingw.h sets whenever __STRICT_ANSI__ is, and the JDK
    # compiles C as -std=c11 rather than gnu11. Rather than loosen the language
    # level everywhere, spell out mingw's own definition; it is the same
    # __builtin_alloca. It must be object-like: sizecalc.h invokes it as
    # (func)(size), and a function-like macro is not expanded when its name is
    # not followed by a parenthesis. Aliasing the name works in both positions,
    # which is the form mingw's non-GNU branch uses.
    SPL="$SRC/src/java.desktop/windows/native/libsplashscreen/splashscreen_sys.c"
    if [ -f "$SPL" ] && ! grep -q '^#define alloca __builtin_alloca$' "$SPL"; then
      perl -0pi -e 's/^#include "splashscreen_impl\.h"$/#include <malloc.h>\n#undef alloca\n#define alloca __builtin_alloca\n#include "splashscreen_impl.h"/m' "$SPL"
      grep -q '^#define alloca __builtin_alloca$' "$SPL" || {
        echo "failed to define alloca in splashscreen_sys.c" >&2; exit 1; }
      log "Defining alloca in splashscreen_sys.c"
    fi

    # A library with C++ sources has to be linked by the C++ driver, or the
    # runtime it needs is simply absent:
    #   ld.lld: error: undefined symbol: operator delete(void*)
    #   ld.lld: error: undefined symbol: std::nothrow
    # SetupNativeCompilation takes that as LINK_TYPE := C++, which sspi_bridge
    # does not say and saproc contradicts (LINK_TYPE := C for every OS but
    # linux). Upstream never noticed: link.exe serves both languages. Infer it
    # from the sources instead of naming each library as it turns up. C++ sources
    # beat a declared C link type, which only ever meant "MSVC will sort it out";
    # a caller that named its own linker is left alone. Expressed twice, because
    # 25 picks the linker from LINK_TYPE under make/common/native/ while 21 and
    # older name a whole toolchain (TOOLCHAIN_LINK_CXX) in NativeCompilation.gmk.
    NCG="$SRC/make/common/NativeCompilation.gmk"
    if [ -f "$NCG" ] && ! grep -q 'INFERRED_LINK_TYPE' "$NCG" \
       && ! grep -q 'SetupSourceFiles' "$NCG"; then
      awk '
        { print }
        !done && $0 == "  $1_SRCS += $$($1_EXTRA_FILES)" {
          print ""
          print "  # INFERRED_LINK_TYPE: link with the C++ linker when the sources are C++."
          print "  ifneq ($$(filter %.cpp %.cc %.cxx %.C, $$($1_SRCS)), )"
          print "    # Only when the caller left the linker at its toolchain default."
          print "    ifeq ($$($1_LD), $$($$($1_TOOLCHAIN)_LD))"
          print "      ifeq ($$($1_TOOLCHAIN), TOOLCHAIN_DEFAULT)"
          print "        $1_LD := $$(LDCXX)"
          print "      endif"
          print "      ifeq ($$($1_TOOLCHAIN), TOOLCHAIN_BUILD)"
          print "        $1_LD := $$(BUILD_LDCXX)"
          print "      endif"
          print "    endif"
          print "  endif"
          done = 1
        }
      ' "$NCG" > "$NCG.tmp" && mv "$NCG.tmp" "$NCG"
      grep -q 'INFERRED_LINK_TYPE' "$NCG" || {
        echo "failed to add the C++ link inference to the monolithic NativeCompilation.gmk" >&2
        exit 1; }
      log "Linking libraries with C++ sources using the C++ linker"
    fi
    if [ -f "$NCG" ] && ! grep -q 'INFERRED_LINK_TYPE' "$NCG"; then
      awk '
        { print }
        !done && $0 == "  $$(eval $$(call SetupSourceFiles,$1))" {
          print ""
          print "  # INFERRED_LINK_TYPE: link with the C++ driver when the sources are C++."
          print "  ifeq ($$($1_LD_PROVIDED), )"
          print "    ifneq ($$(filter %.cpp %.cc %.cxx %.C, $$($1_SRCS)), )"
          print "      $1_LINK_TYPE := C++"
          print "      $1_LD := $$(if $$(filter BUILD, $$($1_TARGET_TYPE)), $$(BUILD_LDCXX), $$(LDCXX))"
          print "    endif"
          print "  endif"
          done = 1
        }
      ' "$NCG" > "$NCG.tmp" && mv "$NCG.tmp" "$NCG"
      grep -q 'INFERRED_LINK_TYPE' "$NCG" || {
        echo "failed to add the C++ link-type inference to NativeCompilation.gmk" >&2; exit 1; }
      # SetupToolchain runs before the sources are known and fills in $1_LD with
      # SetIfEmpty, so by the time the block above runs there is no way left to
      # tell "caller passed LD" from "we defaulted it". Record it beforehand.
      perl -0pi -e 's/(  # Setup the toolchain to be used\n)/  \$\$(eval \$1_LD_PROVIDED := \$\$(\$1_LD))\n$1/' "$NCG"
      grep -q 'LD_PROVIDED :=' "$NCG" || {
        echo "failed to record the caller-provided LD in NativeCompilation.gmk" >&2; exit 1; }
      log "Linking libraries with C++ sources using the C++ driver"
    fi

    # 21's NativeCompilation.gmk emits the windows link flags for anything
    # whose *target* is windows, including the build tools that run here:
    #   clang++: error: unknown argument: '-implib:.../adlc.lib'
    # adlc is a linux executable built with the BUILD toolchain; it has no
    # business being handed an import library at all. Skip the block for the
    # BUILD toolchains, and spell the flag by toolchain for the rest.
    # -manifest:embed goes the same way: it is a link.exe feature with no lld
    # equivalent, and 25's generic Link.gmk simply has no manifest support, so
    # gating it here leaves 21 behaving as 25 already does: executables from
    # the mingw path carry no embedded manifest.
    if [ -f "$NCG" ] && grep -q '"-implib:' "$NCG"; then
      awk '
        $0 == "    ifeq ($(call isTargetOs, windows), true)" {
          print "    ifeq ($(call isTargetOs, windows)$$(if $$(filter TOOLCHAIN_BUILD%, $$($1_TOOLCHAIN)),-build), true)"
          next
        }
        index($0, "$1_EXTRA_LDFLAGS += -manifest:embed") {
          print "        ifeq ($(TOOLCHAIN_TYPE), microsoft)"
          print "          $1_EXTRA_LDFLAGS += -manifest:embed"
          print "        endif"
          next
        }
        index($0, "$1_EXTRA_LDFLAGS += \"-implib:$$($1_IMPORT_LIBRARY)\"") {
          print "      ifeq ($(TOOLCHAIN_TYPE), microsoft)"
          print "        $1_EXTRA_LDFLAGS += \"-implib:$$($1_IMPORT_LIBRARY)\""
          print "      else"
          print "        $1_EXTRA_LDFLAGS += \"-Wl,--out-implib=$$($1_IMPORT_LIBRARY)\""
          print "      endif"
          next
        }
        { print }
      ' "$NCG" > "$NCG.tmp" && mv "$NCG.tmp" "$NCG"
      grep -q 'out-implib' "$NCG" || {
        echo "failed to translate -implib: in NativeCompilation.gmk" >&2; exit 1; }
      log "Emitting import libraries the mingw way, and not for the build tools"
    fi

    # The manifest recipe runs MT, which is empty without cl.exe, so the line
    # expands to one starting with -manifest. Make reads that leading dash as
    # ignore-errors, strips it and runs "manifest", 71 times per build:
    #   /usr/bin/bash: line 1: manifest: command not found
    # Nothing was embedded either way, so gate it on the toolchain until the
    # mingw path grows a real manifest resource.
    if [ -f "$NCG" ] && grep -q -- '-outputresource:' "$NCG"; then
      awk '
        index($0, "-outputresource:") {
          print "                  ifeq ($(TOOLCHAIN_TYPE), microsoft)"
          print $0
          print "                  endif"
          next
        }
        { print }
      ' "$NCG" > "$NCG.tmp" && mv "$NCG.tmp" "$NCG"
      grep -B1 -- '-outputresource:' "$NCG" | grep -q 'TOOLCHAIN_TYPE), microsoft' || {
        echo "failed to gate the manifest recipe in NativeCompilation.gmk" >&2; exit 1; }
      log "Running the manifest tool only for the microsoft toolchain"
    fi

    # jdk.pack keys its whole windows block on _MSC_VER, so mingw takes the unix
    # branch and gets the two-argument mkdir:
    #   utils.cpp:75: error: no matching function for call to 'mkdir'
    # Only MKDIR is touched. The rest of that branch (PATH_MAX, strcasecmp,
    # dup2) is fine on mingw, while the MSVC side spells things mingw would have
    # to be checked for one by one. 14 deleted jdk.pack, so this is 11 and 8.
    PACKDEF="$SRC/src/jdk.pack/share/native/common-unpack/defines.h"
    if [ -f "$PACKDEF" ] && grep -q '^#define MKDIR(dir) mkdir(dir, 0777);$' "$PACKDEF"; then
      awk '
        $0 == "#define MKDIR(dir) mkdir(dir, 0777);" {
          print "#ifdef _WIN32"
          print "#define MKDIR(dir) mkdir(dir)"
          print "#else"
          print $0
          print "#endif"
          next
        }
        { print }
      ' "$PACKDEF" > "$PACKDEF.tmp" && mv "$PACKDEF.tmp" "$PACKDEF"
      grep -q '^#define MKDIR(dir) mkdir(dir)$' "$PACKDEF" || {
        echo "failed to give jdk.pack the one-argument mkdir" >&2; exit 1; }
      log "Using the one-argument mkdir in jdk.pack"
    fi

    # Lib-jdk.accessibility.gmk asks for AccessBridgeStatusWindow.rc while the
    # file on disk is spelled .RC, which only works on a case-insensitive
    # filesystem:
    #   No rule to make target '.../common/AccessBridgeStatusWindow.rc'
    # It is the only uppercase .RC in the tree, so rename the file rather than
    # patch the three makefile references.
    ABRC="$SRC/src/jdk.accessibility/windows/native/common/AccessBridgeStatusWindow"
    if [ -f "$ABRC.RC" ] && [ ! -f "$ABRC.rc" ]; then
      mv "$ABRC.RC" "$ABRC.rc"
      log "Renamed AccessBridgeStatusWindow.RC to the spelling its makefile uses"
    fi

    # mlib_sys.c picks its aligned allocator with #if defined(_MSC_VER), and
    # everything else gets the unix branch:
    #   mlib_sys.c:85: error: call to undeclared function 'memalign'
    # mingw has no memalign; its malloc has the same 8-byte guarantee the MSVC
    # branch is there to document, so widen the test to the platform.
    MLB="$SRC/src/java.desktop/share/native/common/awt/medialib/mlib_sys.c"
    if [ -f "$MLB" ] && grep -q '^#if defined(_MSC_VER) || defined(AIX)$' "$MLB"; then
      sed -i 's/^#if defined(_MSC_VER) || defined(AIX)$/#if defined(_MSC_VER) || defined(_WIN32) || defined(AIX)/' "$MLB"
      log "Using malloc rather than memalign in mlib_sys.c on windows"
    fi

    # libsunmscapi passes WCHAR* straight to JNI's jchar* and back:
    #   security.cpp:660: error: cannot initialize a parameter of type
    #   'const jchar *' (aka 'const unsigned short *') with an lvalue of type
    #   'wchar_t *'
    # MSVC accepts it because the JDK builds windows C++ with -Zc:wchar_t-,
    # making wchar_t a typedef for unsigned short. clang's equivalent,
    # -fno-wchar, is unusable here: mingw's headers assume a builtin wchar_t in
    # C++ and stop declaring the type without it. Cast at the JNI boundary
    # instead; both types are 16-bit unsigned on windows, which is what the MSVC
    # flag encodes anyway. 21+ only, since 17 and earlier build the name with
    # NewStringUTF() off a char*. Guarding on the unfixed call keeps it
    # idempotent: once cast, the text no longer matches.
    SEC="$SRC/src/jdk.crypto.mscapi/windows/native/libsunmscapi/security.cpp"
    if [ -f "$SEC" ] && grep -q 'env->NewString(pszNameString' "$SEC"; then
      sed -i \
        -e 's/env->NewString(pszNameString, nameLen)/env->NewString((const jchar*)pszNameString, nameLen)/g' \
        -e 's/(pszCertAliasName = env->GetStringChars(jCertAliasName, NULL))/(pszCertAliasName = (const wchar_t*)env->GetStringChars(jCertAliasName, NULL))/g' \
        -e 's/env->ReleaseStringChars(jCertAliasName, pszCertAliasName)/env->ReleaseStringChars(jCertAliasName, (const jchar*)pszCertAliasName)/g' \
        "$SEC"
      grep -q '(const jchar\*)pszNameString' "$SEC" || {
        echo "failed to cast the JNI string arguments in security.cpp" >&2; exit 1; }
      log "Casting between WCHAR and jchar in security.cpp"
    fi

    # 17 and earlier keep VS2008/VS2012 fallbacks in the unwind headers, behind
    # "#if _MSC_VER < 1700". clang does not define _MSC_VER at all, so the guard
    # reads 0 < 1700, the fallbacks compile, and they collide with what
    # mingw-w64's winnt.h already declares:
    #   unwind_windows_x86.hpp:70: error: redefinition of '_DISPATCHER_CONTEXT'
    #   unwind_windows_aarch64.hpp:86: error: typedef redefinition with
    #   different types ('struct _DISPATCHER_CONTEXT' vs 'DISPATCHER_CONTEXT_ARM64')
    # 21 deleted the blocks outright, which is why it builds untouched. Here,
    # just require _MSC_VER to actually exist before honouring the version test.
    for UNW in "$SRC/src/hotspot/os_cpu/windows_x86/unwind_windows_x86.hpp" \
               "$SRC/src/hotspot/os_cpu/windows_aarch64/unwind_windows_aarch64.hpp"; do
      [ -f "$UNW" ] && grep -q '^#if _MSC_VER < ' "$UNW" || continue
      sed -i 's/^#if _MSC_VER < \([0-9]*\)$/#if defined(_MSC_VER) \&\& _MSC_VER < \1/' "$UNW"
      grep -q '^#if _MSC_VER < ' "$UNW" && {
        echo "failed to guard the _MSC_VER fallbacks in $(basename "$UNW")" >&2; exit 1; }
      log "Requiring _MSC_VER in $(basename "$UNW")'s legacy guards"
    done

    # 17 clears the first slot of symbolengine.cpp's template buffer with a char
    # literal, "_p[0] = '\0';". The buffer is instantiated for HMODULE too, and
    # a char is not a null pointer constant, so clang rejects that instantiation
    # where MSVC waves it through:
    #   symbolengine.cpp:114: error: incompatible integer to pointer conversion
    #   assigning to 'HINSTANCE__ *' from 'char'
    # 21 writes a plain 0: still zero for the char case, a null pointer
    # constant for the pointer one. Adopt that, which makes the file identical
    # to 21's here.
    SYE="$SRC/src/hotspot/os/windows/symbolengine.cpp"
    if [ -f "$SYE" ] && grep -qF "_p[0] = '\\0';" "$SYE"; then
      sed -i "s/_p\[0\] = '[\\]0';/_p[0] = 0;/g" "$SYE"
      grep -qF "_p[0] = '\\0';" "$SYE" && {
        echo "failed to zero symbolengine.cpp's buffer without a char literal" >&2; exit 1; }
      log "Zeroing symbolengine.cpp's buffer with 0 rather than a char literal"
    fi

    # topLevelExceptionFilter default-constructs a frame ("frame fr;"), but
    # frame::frame() is an inline living in the cpu's frame_<cpu>.inline.hpp, and
    # 17's os_windows.cpp never reaches it, no include of runtime/frame.inline.hpp
    # and no transitive path to it, so nothing emits the body:
    #   ld.lld: error: undefined symbol: frame::frame()
    #   >>> referenced by os_windows.obj:(topLevelExceptionFilter(...))
    # runtime/frame.inline.hpp pulls in CPU_HEADER_INLINE(frame), which is where
    # the definition is. 21 reaches it another way and links untouched, so key
    # this on runtime/thread.inline.hpp, which 21 replaced with javaThread.hpp.
    OSW="$SRC/src/hotspot/os/windows/os_windows.cpp"
    if [ -f "$OSW" ] && grep -q '#include "runtime/thread.inline.hpp"' "$OSW" &&
       ! grep -q '#include "runtime/frame.inline.hpp"' "$OSW"; then
      sed -i '0,\|#include "runtime/globals.hpp"|s||#include "runtime/frame.inline.hpp"\n&|' "$OSW"
      grep -q '#include "runtime/frame.inline.hpp"' "$OSW" || {
        echo "failed to include frame.inline.hpp in os_windows.cpp" >&2; exit 1; }
      log "Including frame.inline.hpp in os_windows.cpp for frame::frame()"
    fi

    # FLAGS_SETUP_ARFLAGS picks the archiver flags by target OS alone, so a
    # windows target gets lib.exe's spelling whatever the toolchain is:
    #   ARFLAGS="-nologo -NODEFAULTLIB:MSVCRT"
    # llvm-ar is not lib.exe and refuses them, which stops the first static
    # library the build reaches, 17 still archives fdlibm, 21 converted it to
    # java and never gets here:
    #   x86_64-w64-mingw32-ar: error: unknown option n
    #   CoreLibraries.gmk:44: .../fdlibm.lib] Error 1
    # AR_OUT_OPTION right above already keys off the toolchain and hands us the
    # GNU -rcs form, so only the flags are wrong. Require microsoft as well; 25
    # dropped the windows branch outright and needs nothing.
    ARF="$SRC/make/autoconf/flags-other.m4"
    if [ -f "$ARF" ] && grep -q '^  elif test "x\$OPENJDK_TARGET_OS" = xwindows; then$' "$ARF"; then
      sed -i 's|^  elif test "x\$OPENJDK_TARGET_OS" = xwindows; then$|  elif test "x$OPENJDK_TARGET_OS" = xwindows \&\& test "x$TOOLCHAIN_TYPE" = xmicrosoft; then|' "$ARF"
      grep -q 'xwindows && test "x\$TOOLCHAIN_TYPE" = xmicrosoft' "$ARF" || {
        echo "failed to scope the MSVC archiver flags to the microsoft toolchain" >&2; exit 1; }
      log "Leaving ARFLAGS empty for the mingw archiver"
    fi

    # Same file, 11 only: its version-info defines for the resource compiler sit
    # in the microsoft branch, so a clang build gets an empty RC_FLAGS and the
    # .rc keeps a bare token where a number belongs:
    #   llvm-rc: expected '-', '~', integer or '(', got JDK_VER
    # 17 moved them out of any toolchain test. Key the block on the target OS,
    # leaving behind only the two cl.exe switches windres rejects.
    if [ -f "$ARF" ] && grep -q '^    RC_FLAGS="-nologo -l0x409"$' "$ARF"; then
      awk '
        $0 == "  # On Windows, we need to set RC flags." { print; inrc = 1; next }
        inrc && $0 == "  if test \"x$TOOLCHAIN_TYPE\" = xmicrosoft; then" {
          print "  if test \"x$OPENJDK_TARGET_OS\" = xwindows; then"
          next
        }
        inrc && $0 == "    RC_FLAGS=\"-nologo -l0x409\"" {
          print "    if test \"x$TOOLCHAIN_TYPE\" = xmicrosoft; then"
          print "      RC_FLAGS=\"-nologo -l0x409\""
          print "      JVM_RCFLAGS=\"-nologo\""
          print "    fi"
          drop_jvm = 1
          next
        }
        drop_jvm && $0 == "    JVM_RCFLAGS=\"-nologo\"" { drop_jvm = 0; next }
        { print }
      ' "$ARF" > "$ARF.tmp" && mv "$ARF.tmp" "$ARF"
      grep -q '^  if test "x\$OPENJDK_TARGET_OS" = xwindows; then$' "$ARF" || {
        echo "failed to give the mingw resource compiler its version defines" >&2; exit 1; }
      log "Defining the version-info macros for the mingw resource compiler"
    fi

    # 11's windows JNI types come from the JDK-8308780 backport in
    # patches/global/jdk/11; nine companion files move with jni_md.h.
    #
    # count_trailing_zeros dispatches on toolchain, and its gcc branch assumes
    # unsigned long is as wide as uintx. False on win64, where it is half:
    #   count_trailing_zeros.hpp:44: STATIC_ASSERT_FAILURE<false>
    # __builtin_ctzl would truncate too. 17 rewrote the header into width
    # explicit helpers, dragging its callers along, so keep 11's shape and take
    # the long long builtin. Zero-extending cannot change the count for x != 0.
    CTZ="$SRC/src/hotspot/share/utilities/count_trailing_zeros.hpp"
    if [ -f "$CTZ" ] && grep -q '^  STATIC_ASSERT(sizeof(unsigned long) == sizeof(uintx));$' "$CTZ"; then
      perl -0pi -e 's/^  STATIC_ASSERT\(sizeof\(unsigned long\) == sizeof\(uintx\)\);\n(  assert\(x != 0, "precondition"\);\n)  return __builtin_ctzl\(x\);$/#ifdef __MINGW32__\n  STATIC_ASSERT(sizeof(unsigned long long) >= sizeof(uintx));\n$1  return __builtin_ctzll(x);\n#else\n  STATIC_ASSERT(sizeof(unsigned long) == sizeof(uintx));\n$1  return __builtin_ctzl(x);\n#endif/m' "$CTZ"
      grep -q '__builtin_ctzll' "$CTZ" || {
        echo "failed to widen count_trailing_zeros for mingw" >&2; exit 1; }
      log "Counting trailing zeros with the long long builtin on mingw"
    fi

    # sspi.cpp is C written as C++, and MSVC lets both of these pass where clang
    # does not:
    #   sspi.cpp:58: error: invalid suffix on literal; C++11 requires a space
    #   between literal and identifier
    #   sspi.cpp:389: error: cannot jump from this goto statement to its label
    # The first is "[SSPI:%ld] "fmt"\n" with no spaces around the macro
    # parameter; the second is the error path's gotos hopping over five
    # declarations-with-initialisers. 21 fixed both by splitting exactly those
    # five, so follow it. Not taken from 21: its new[]/delete[] to malloc/free
    # rewrite, a separate change whose allocation half alone would pair malloc
    # with delete[].
    SSPI="$SRC/src/java.security.jgss/windows/native/libsspi_bridge/sspi.cpp"
    if [ -f "$SSPI" ] && grep -qF '] "fmt"' "$SSPI"; then
      perl -0777 -i -pe '
        my @pairs = (
          [ qq{] "fmt"}, qq{] " fmt "} ],
          [ qq{    gss_name_struct* name = new gss_name_struct;},
            qq{    gss_name_struct* name;\n    name = new gss_name_struct;} ],
          [ qq{    size_t namelen = wcslen(fullname);},
            qq{    size_t namelen;\n    namelen = wcslen(fullname);} ],
          [ qq{    int mechLen = KRB5_OID.length;},
            qq{    int mechLen;\n    mechLen = KRB5_OID.length;} ],
          [ qq{    char* buffer = new char[10 + mechLen + len];},
            qq{    char* buffer;\n    buffer = new char[10 + mechLen + len];} ],
          [ qq{    int flag = flag_gss_to_sspi(req_flags) | ISC_REQ_ALLOCATE_MEMORY;},
            qq{    int flag;\n    flag = flag_gss_to_sspi(req_flags) | ISC_REQ_ALLOCATE_MEMORY;} ],
        );
        for my $p (@pairs) {
          my ($o, $n) = @$p;
          my $c = ($_ =~ s/\Q$o\E/$n/g);
          die "sspi.cpp anchor missed or ambiguous ($c): $o\n" unless $c == 1;
        }
      ' "$SSPI" || { echo "failed to make sspi.cpp compile as C++" >&2; exit 1; }
      log "Spacing sspi.cpp's PP macro and splitting the declarations its gotos skip"
    fi

    # With TSTRINGS_WITH_WCHAR on, which the block above turns on for clang,
    # tstrings::any streams into a wostringstream, and 17 has no overload taking
    # a narrow string, so "any << lastCRTError()" lands on the generic template.
    # The only way that compiles is through the any-to-wostream operator further
    # down the header, which two-phase lookup will not reach:
    #   tstrings.h:394: error: call to function 'operator<<' that is neither
    #   visible in the template definition nor found by argument-dependent lookup
    #   note: 'operator<<' should be declared prior to the call site
    # 21 added an explicit std::string overload that converts with fromUtf8, so
    # the template is never instantiated for it. 17 already has the matching
    # constructor and fromUtf8, so take the overload as 21 writes it, ahead of
    # the TSTRINGS_WITH_WCHAR block, so the narrow build gets it too.
    TST="$SRC/src/jdk.jpackage/share/native/common/tstrings.h"
    if [ -f "$TST" ] && ! grep -q 'any& operator << (const std::string& msg)' "$TST"; then
      perl -0777 -i -pe '
        my $o = qq{        any(const std::string& msg) {\n            data << fromUtf8(msg);\n        }\n\n#ifdef TSTRINGS_WITH_WCHAR\n};
        my $n = qq{        any(const std::string& msg) {\n            data << fromUtf8(msg);\n        }\n\n        any& operator << (const std::string& msg) {\n            data << fromUtf8(msg);\n            return *this;\n        }\n\n#ifdef TSTRINGS_WITH_WCHAR\n};
        die "tstrings.h any/ifdef anchor missed\n" unless ($_ =~ s/\Q$o\E/$n/g) == 1;
      ' "$TST" || { echo "failed to add the narrow-string operator to tstrings.h" >&2; exit 1; }
      log "Giving jpackage's tstrings::any a narrow std::string overload"
    fi

    # 17's D3D macros paste adjacent string literals with ##, which is not a
    # valid preprocessing token and only survives because MSVC allows it:
    #   D3DBlitLoops.cpp:147: error: pasting formed '" failed in "__FILE__",
    #   return;"', an invalid preprocessing token
    # Every ## in the header joins string literals, the neighbouring # that
    # stringifies a macro argument is a different operator and stays. 21 removed
    # them all, leaving plain literal concatenation, so do the same.
    D3DP="$SRC/src/java.desktop/windows/native/libawt/java2d/d3d/D3DPipeline.h"
    if [ -f "$D3DP" ] && grep -q ' ## ' "$D3DP"; then
      d3d_pastes=$(grep -c ' ## ' "$D3DP")
      sed -i 's/ ## / /g' "$D3DP"
      grep -q ' ## ' "$D3DP" && {
        echo "failed to drop the string-literal pastes in D3DPipeline.h" >&2; exit 1; }
      log "Concatenating rather than pasting the D3D trace literals ($d3d_pastes macros)"
    fi

    # Same shape as sspi.cpp: JNI_CHECK_PEER_GOTO and friends jump to a label
    # further down, and C++ will not let that skip an initialisation where MSVC
    # only warns:
    #   awt_Canvas.cpp:215: error: cannot jump from this goto statement to its
    #   label; jump bypasses variable initialization
    # Splitting the declaration from the assignment fixes it without touching the
    # control flow. awt_Canvas is the one the compiler named; the other three are
    # the same construct, found by reading the sources. Splitting a pointer or
    # handle declaration is semantics-neutral whether or not a goto crosses it,
    # so all four go in at once rather than one 9-minute build at a time. Each
    # applies only if its exact text is present, awt_Canvas required.
    awt_dir="$SRC/src/java.desktop/windows/native/libawt/windows"
    if [ -d "$awt_dir" ]; then
      # Find them rather than meet them one build at a time: walk each file
      # tracking brace depth and, from a _GOTO macro until its label, report the
      # declarations-with-initialiser sitting at the goto's own depth. Depth is
      # what makes this accurate, a declaration inside a nested block is jumped
      # over, not into, and is legal. const and static are skipped: one cannot be
      # separated from its initialiser, the other would change meaning.
      mkdir -p "$BUILD_DIR"
      cat > "$BUILD_DIR/awt-goto-scan.awk" <<'AWKEOF'
FNR == 1 { depth = 0; active = 0 }
{
  line = $0
  gsub(/"[^"]*"/, "", line)
  gsub(/\047[^\047]*\047/, "", line)
  opens = gsub(/\{/, "{", line); closes = gsub(/\}/, "}", line)
  if (active && depth <= mindepth && $0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/) active = 0
  if (active && depth == mindepth &&
      $0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_:]*[[:space:]]+\*?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[^=]/ &&
      $0 !~ /^[[:space:]]*(return|delete|if|for|while|else|const|static)\b/)
    print FILENAME ":" FNR
  if ($0 ~ /_GOTO\(/ || $0 ~ /^[[:space:]]*goto[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*;/) { active = 1; mindepth = depth }
  depth += opens - closes
  if (active && depth < mindepth) mindepth = depth
}
AWKEOF
      # Only the type moves to a line of its own; the initialiser stays put, so
      # a continuation line keeps its place and alignment.
      cat > "$BUILD_DIR/awt-goto-split.pl" <<'PLEOF'
if ($. == $ENV{LN}) {
    if (/^(\s*)((?:[A-Za-z_][\w:]*\s+|\*\s*)+)(\w+)(\s*=.*)$/) {
        $_ = "$1$2$3;\n$1$3$4\n";
    } else {
        die "unexpected declaration shape at $ARGV line $.: $_";
    }
}
PLEOF
      awt_goto_splits=0
      # Highest line first, so the line numbers ahead of each edit stay valid.
      while IFS=: read -r f ln; do
        [ -n "${ln:-}" ] || continue
        LN="$ln" perl -i -p "$BUILD_DIR/awt-goto-split.pl" "$f" ||
          { echo "failed to split $f:$ln" >&2; exit 1; }
        awt_goto_splits=$((awt_goto_splits + 1))
      done < <(awk -f "$BUILD_DIR/awt-goto-scan.awk" "$awt_dir"/*.cpp | sort -t: -k1,1 -k2,2nr)
      if [ "$awt_goto_splits" -gt 0 ]; then
        awt_left=$(awk -f "$BUILD_DIR/awt-goto-scan.awk" "$awt_dir"/*.cpp | wc -l)
        [ "$awt_left" -eq 0 ] || {
          echo "$awt_left libawt declarations still sit under a goto" >&2; exit 1; }
        log "Splitting $awt_goto_splits libawt declarations the JNI gotos skip"
      fi
    fi

    # One the scan above will not touch: a const cannot be split from its
    # initialiser.
    #   awt_PrintJob.cpp:927: cannot jump from this goto statement to its label
    #     935 |     const double epsilon = 0.10;
    # Move it above the goto instead; it is a literal depending on nothing, and
    # JNI_CHECK_NULL_GOTO is the first jump in that function. 21 has the same
    # constant but replaced that macro with an explicit null check.
    # This is the only qualified declaration in libawt sitting under a goto, so
    # it is done by name rather than by another scan.
    PJ="$awt_dir/awt_PrintJob.cpp"
    pj_eps='    const double epsilon = 0.10;'
    pj_goto='    JNI_CHECK_NULL_GOTO(printDC, "Invalid printDC", done);'
    if [ -f "$PJ" ] && grep -qxF "$pj_eps" "$PJ" &&
       [ "$(grep -nxF "$pj_eps" "$PJ" | cut -d: -f1)" -gt "$(grep -nxF "$pj_goto" "$PJ" | cut -d: -f1)" ]; then
      EPS="$pj_eps" GOTO="$pj_goto" perl -0777 -i -pe '
        my ($e, $g) = ($ENV{EPS} . "\n", $ENV{GOTO} . "\n");
        die "epsilon declaration not unique\n" unless ($_ =~ s/\Q$e\E//) == 1;
        die "printDC goto not unique\n" unless ($_ =~ s/\Q$g\E/$e$g/) == 1;
      ' "$PJ" || { echo "failed to hoist epsilon above the goto in awt_PrintJob.cpp" >&2; exit 1; }
      log "Declaring awt_PrintJob's epsilon before the goto that would skip it"
    fi

    # Three of the access bridge's getters return jobject but hand
    # EXCEPTION_CHECK, which expands to a return, an AccessibleContext, and a
    # fourth returns one directly. AccessibleContext is a jlong, so that is an
    # integer where a pointer belongs:
    #   AccessBridgeJavaEntryPoints.cpp:1044: error: cannot initialize return
    #   object of type 'jobject' (aka '_jobject *') with an rvalue of type
    #   'AccessibleContext' (aka 'long long')
    # 21 wrapped exactly these four in reinterpret_cast<jobject>, which is the
    # same conversion the rest of the file already makes by hand. Take that,
    # keyed on each site's own text: the other EXCEPTION_CHECKs passing
    # (AccessibleContext)0 sit in functions that really do return one, and must
    # be left alone.
    ABJ="$SRC/src/jdk.accessibility/windows/native/libjavaaccessbridge/AccessBridgeJavaEntryPoints.cpp"
    if [ -f "$ABJ" ] && grep -q 'EXCEPTION_CHECK("Getting ParentWithRole - call to CallObjectMethod()", (AccessibleContext)0)' "$ABJ"; then
      perl -0777 -i -pe '
        my @sites = (
          qq{EXCEPTION_CHECK("Getting ParentWithRole - call to CallObjectMethod()", (AccessibleContext)0)},
          qq{EXCEPTION_CHECK("Getting ParentWithRoleElseRoot - call to CallObjectMethod()", (AccessibleContext)0)},
          qq{EXCEPTION_CHECK("Getting ActiveDescendent - call to CallObjectMethod()", (AccessibleContext)0)},
          qq{        return (AccessibleContext)0;\n},
        );
        for my $s (@sites) {
          my $n = $s;
          $n =~ s/\(AccessibleContext\)0/reinterpret_cast<jobject>((AccessibleContext)0)/;
          die "access bridge site missed or ambiguous: $s\n" unless ($_ =~ s/\Q$s\E/$n/g) == 1;
        }
      ' "$ABJ" || { echo "failed to cast the access bridge jobject returns" >&2; exit 1; }
      log "Returning jobject rather than AccessibleContext at 4 access bridge sites"
    fi

    # alloc.h poisons malloc/calloc/realloc so JDK code cannot call them:
    #   #define malloc Do_Not_Use_malloc_Use_safe_Malloc_Instead
    # awt_ole.h includes mingw's comdef.h, which includes comip.h, which calls
    # malloc itself, so once awt.h has been included first, a system header
    # inherits the poison and stops the build:
    #   comip.h:252: error: use of undeclared identifier
    #   'Do_Not_Use_malloc_Use_safe_Malloc_Instead'
    # awt_ole.h includes comdef.h before awt.h precisely to avoid this, which
    # only works if it is reached first. 21 rearranged both DnD files to include
    # it ahead of anything pulling in awt.h; do the same, keyed on the ordering
    # rather than on a file list, so a file already in that shape is left alone.
    mkdir -p "$BUILD_DIR"
    cat > "$BUILD_DIR/awt-ole-hoist.pl" <<'PLEOF'
my $inc = "#include \"awt_ole.h\"\n";
exit 0 unless /\Q$inc\E/;
my @lines = split /^/, $_;
my ($ole) = grep { $lines[$_] eq $inc } 0 .. $#lines;
my ($first) = grep { $lines[$_] =~ /^#include\s+[<"]awt[.\w]*[>"]/ } 0 .. $#lines;
exit 0 if !defined $ole || !defined $first || $ole <= $first;
splice(@lines, $ole, 1);
splice(@lines, $first, 0, $inc);
$_ = join "", @lines;
PLEOF
    awt_ole_hoists=0
    for f in "$awt_dir"/*.cpp; do
      [ -f "$f" ] || continue
      grep -q '#include "awt_ole.h"' "$f" || continue
      ole=$(grep -n '#include "awt_ole.h"' "$f" | head -1 | cut -d: -f1)
      first=$(grep -nE '^#include[[:space:]]+[<"]awt[._A-Za-z0-9]*[>"]' "$f" | head -1 | cut -d: -f1)
      [ -n "${first:-}" ] && [ "$ole" -gt "$first" ] || continue
      perl -0777 -i -p "$BUILD_DIR/awt-ole-hoist.pl" "$f" ||
        { echo "failed to hoist awt_ole.h in $(basename "$f")" >&2; exit 1; }
      awt_ole_hoists=$((awt_ole_hoists + 1))
    done
    if [ "$awt_ole_hoists" -gt 0 ]; then
      log "Including awt_ole.h before awt.h in $awt_ole_hoists sources"
    fi

    # libjsvml's windows sources are MASM, assembled by ml64.exe upstream and
    # unparseable to clang's GNU assembler from the copyright header down:
    #   jsvml_d_acos_windows_x86.S:25: error: invalid instruction mnemonic
    #   'questions.'
    # Hundreds of files, no translation worth attempting. Linux has the same
    # routines as separate GNU-syntax sources, so only windows hits this.
    #
    # A functional reduction, and a soft one: VectorMathLibrary loads "jsvml" and
    # falls back to "new Java()" on any Throwable, so the Vector API still works,
    # computing transcendental vector math in Java. Slower, and correct.
    VEC="$SRC/make/modules/jdk.incubator.vector/Lib.gmk"
    if [ -f "$VEC" ] && grep -q 'isTargetOs, linux windows' "$VEC"; then
      sed -i 's/isTargetOs, linux windows/isTargetOs, linux/' "$VEC"
      log "Skipping libjsvml on windows (MASM sources); Vector API falls back to Java"
    fi

    # awt.dll carries two different global arrays called StdBlendRules: the
    # OpenGL pipeline's, in C, and Direct3D's, in C++.
    #   ld.lld: error: duplicate symbol: StdBlendRules
    #   >>> defined at D3DContext.obj
    #   >>> defined at OGLContext.obj
    # MSVC decorates namespace-scope C++ variables, so the two never meet
    # there; the Itanium ABI leaves them undecorated and they collide. Rename
    # the D3D one across its directory rather than making it static, so any
    # other file in the pipeline that refers to it moves with it.
    D3D="$SRC/src/java.desktop/windows/native/libawt/java2d/d3d"
    if [ -d "$D3D" ] && grep -rq '\bStdBlendRules\b' "$D3D"; then
      grep -rl '\bStdBlendRules\b' "$D3D" | xargs sed -i 's/\bStdBlendRules\b/D3DStdBlendRules/g'
      log "Renaming the D3D StdBlendRules table so it cannot clash with OpenGL's"
    fi

    # socketTransport.c names a variable "interface", which is a macro in the
    # windows SDK, basetyps.h defines it as struct for COM's benefit:
    #   socketTransport.c:58: error: declaration of anonymous struct must be a
    #   definition
    # WIN32_LEAN_AND_MEAN keeps that out of hotspot's include chain, but this
    # file reaches it through winsock2.h. Undefining it once works here, unlike
    # in hotspot, because everything this file includes comes before the
    # declaration, there is no later windows.h to bring the macro back.
    SKT="$SRC/src/jdk.jdwp.agent/share/native/libdt_socket/socketTransport.c"
    if [ -f "$SKT" ] && ! grep -q '^#undef interface$' "$SKT"; then
      perl -0pi -e 's/^(static struct jdwpTransportNativeInterface_ interface;)$/#undef interface\n$1/m' "$SKT"
      grep -q '^#undef interface$' "$SKT" || {
        echo "failed to undefine the interface macro in socketTransport.c" >&2; exit 1; }
      log "Undefining the interface macro in socketTransport.c"
    fi

    # libawt uses _bstr_t from comutil.h, whose BSTR functions live in
    # oleaut32:
    #   ld.lld: error: undefined symbol: __declspec(dllimport) SysAllocString
    # MSVC never has to be told, because comutil.h asks for the library with
    # #pragma comment(lib, "oleaut32.lib") and cl.exe records that in the
    # object for the linker to act on. clang emits no such directive outside
    # its MSVC-compatible driver, so name the library where the others are
    # named.
    # Three makefile shapes: 25 has AwtLibraries.gmk, 17 and 21
    # modules/java.desktop/lib/Awt2dLibraries.gmk, 11 make/lib/Awt2dLibraries.gmk.
    # All three spell the setup the same, so anchor on that and its own
    # LIBS_windows rather than on a filename or the flag order.
    for AWL in "$SRC/make/modules/java.desktop/lib/AwtLibraries.gmk" \
               "$SRC/make/modules/java.desktop/lib/Awt2dLibraries.gmk" \
               "$SRC/make/lib/Awt2dLibraries.gmk"; do
      [ -f "$AWL" ] || continue
      grep -q 'oleaut32.lib' "$AWL" && continue
      awk '
        /SetupJdkLibrary, BUILD_LIBAWT,/ { inawt = 1 }
        inawt && !done && /^ *LIBS_windows := / {
          sub(/LIBS_windows := /, "LIBS_windows := oleaut32.lib ")
          done = 1
        }
        { print }
      ' "$AWL" > "$AWL.tmp" && mv "$AWL.tmp" "$AWL"
      grep -q 'LIBS_windows := oleaut32.lib ' "$AWL" || {
        echo "failed to add oleaut32 to the libawt link in $(basename "$AWL")" >&2; exit 1; }
      log "Linking libawt against oleaut32 for the BSTR functions"
    done

    # jpackage decides between wide and narrow strings on _MSC_VER alone:
    #   #ifdef _MSC_VER
    #   #   define TSTRINGS_WITH_WCHAR
    # so a clang windows build gets tstring = std::string while the windows
    # sources around it use _T() literals and the W half of the win32 API:
    #   AppLauncher.cpp:180: error: invalid operands to binary expression
    #   ('tstring' (aka 'basic_string<char>') and 'const wchar_t[5]')
    # Widen that one test to the platform. The other _MSC_VER tests in the file
    # only guard #pragma warning and are left alone.
    TST="$SRC/src/jdk.jpackage/share/native/common/tstrings.h"
    if [ -f "$TST" ] && ! grep -q 'defined(_MSC_VER) || defined(_WIN32)' "$TST"; then
      awk '
        !done && $0 == "#ifdef _MSC_VER" {
          print "#if defined(_MSC_VER) || defined(_WIN32)"
          done = 1
          next
        }
        { print }
      ' "$TST" > "$TST.tmp" && mv "$TST.tmp" "$TST"
      grep -q 'defined(_MSC_VER) || defined(_WIN32)' "$TST" || {
        echo "failed to widen the TSTRINGS_WITH_WCHAR test in tstrings.h" >&2; exit 1; }
      log "Giving jpackage wide strings on windows, as MSVC gets"
    fi

    # libsplashscreen's windows config defines INLINE as __inline, where the
    # unix one defines it as static:
    #   ld.lld: error: undefined symbol: getRGBA
    # Those helpers live in a header shared by several files. MSVC's __inline
    # emits a definition wherever one is needed; C99 inline emits none unless
    # some translation unit also declares the function extern, and none does,
    # so every call that was not inlined has nothing to reach. Use the unix
    # spelling, which is what every other clang build of this library uses.
    SPC="$SRC/src/java.desktop/windows/native/libsplashscreen/splashscreen_config.h"
    if [ -f "$SPC" ] && grep -q '^#define INLINE __inline$' "$SPC"; then
      sed -i 's/^#define INLINE __inline$/#define INLINE static/' "$SPC"
      log "Defining INLINE as static in libsplashscreen, as the unix config does"
    fi

    # jpackage reports the win32 function that failed by passing it straight to
    # SysError, whose parameter is a const void*:
    #   JP_THROW(SysError("ResumeThread() failed", ResumeThread));
    #   error: no known conversion from 'DWORD (HANDLE) __attribute__((stdcall))'
    #   to 'const void *' for 2nd argument
    # A function pointer does not implicitly convert to void* in standard C++;
    # MSVC permits it. The address is only used for diagnostics. Add a
    # forwarding constructor that takes any pointer and does the cast, rather
    # than editing the call sites, there are dozens across the windows
    # sources, and the non-template constructor still wins for the ordinary
    # data-pointer and nullptr cases.
    WEH="$SRC/src/jdk.jpackage/windows/native/common/WinErrorHandling.h"
    if [ -f "$WEH" ] && ! grep -q 'template <class T>' "$WEH"; then
      awk '
        { print }
        !done && index($0, "DWORD errorCode=GetLastError(), const char* label=\"System error\");") {
          print ""
          print "    // A function pointer does not convert to const void* implicitly."
          print "    template <class T>"
          print "    SysError(const tstrings::any& msg, T* caller,"
          print "            DWORD errorCode=GetLastError(), const char* label=\"System error\")"
          print "        : SysError(msg, reinterpret_cast<const void*>(caller), errorCode, label) {}"
          done = 1
        }
      ' "$WEH" > "$WEH.tmp" && mv "$WEH.tmp" "$WEH"
      grep -q 'template <class T>' "$WEH" || {
        echo "failed to add the SysError forwarding constructor" >&2; exit 1; }
      log "Letting SysError take a function pointer for the failing call"
    fi

    # jpackage opens files by handing a tstring (std::wstring on windows)
    # straight to std::ifstream:
    #   PackageFile.cpp:44: error: no matching constructor for initialization
    #   of 'std::ifstream'
    # MSVC's STL has a const std::wstring& overload; libc++ has only the
    # const wchar_t* one. Call c_str(), which keeps the path wide, converting
    # it to a narrow string would hand msvcrt an ANSI-codepage path and lose
    # any character outside it.
    # Both spellings need it: the constructor and a later open(). Restricted to
    # files that mention fstream at all, so an unrelated open() elsewhere in
    # jpackage cannot be caught by the same pattern. Not "#include <fstream>":
    # WinFileUtils.cpp names std::ifstream but picks the header up indirectly,
    # and that is the file with the open() call.
    for f in $(grep -rl 'fstream' "$SRC/src/jdk.jpackage" 2>/dev/null || true); do
      before=$(grep -c 'c_str()' "$f" || true)
      sed -i -E \
        -e 's/(std::(i|o)?fstream [A-Za-z_][A-Za-z0-9_]*\([A-Za-z_][A-Za-z0-9_]*)([,)])/\1.c_str()\3/g' \
        -e 's/\.open\(([A-Za-z_][A-Za-z0-9_]*)([,)])/.open(\1.c_str()\2/g' \
        "$f"
      after=$(grep -c 'c_str()' "$f" || true)
      [ "$before" = "$after" ] || log "Opening the stream with a wide c_str() in $(basename "$f")"
    done

    # The same FARPROC conversion hotspot needed, in jpackage:
    #   WinDll.cpp:67: error: cannot initialize a variable of type 'void *'
    #   with an rvalue of type 'FARPROC'
    WDL="$SRC/src/jdk.jpackage/windows/native/common/WinDll.cpp"
    if [ -f "$WDL" ] && grep -q '^    void \*ptr = GetProcAddress' "$WDL"; then
      sed -i 's/^\( *\)void \*ptr = \(GetProcAddress(.*)\);$/\1void *ptr = reinterpret_cast<void*>(\2);/' "$WDL"
      grep -q 'reinterpret_cast<void\*>(GetProcAddress' "$WDL" || {
        echo "failed to cast the GetProcAddress result in WinDll.cpp" >&2; exit 1; }
      log "Casting the GetProcAddress result in WinDll.cpp"
    fi

    # tstrings::unsafe_format has an MSVC branch calling the TCHAR-aware
    # _vsntprintf_s and an everyone-else branch calling narrow vsnprintf. With
    # tstring now wide, clang takes the second and is handed a wchar_t buffer:
    #   tstrings.cpp:60: error: no matching function for call to 'vsnprintf'
    # Pick the wide CRT function on windows. _vsnwprintf returns -1 when the
    # buffer is too small, which is what the surrounding loop grows on.
    TSC="$SRC/src/jdk.jpackage/share/native/common/tstrings.cpp"
    if [ -f "$TSC" ] && ! grep -q '_vsnwprintf' "$TSC"; then
      perl -0pi -e 's/^(        )(ret = vsnprintf\(&\*fmtout\.begin\(\), fmtout\.size\(\), format, args\);)$/#ifdef _WIN32\n$1ret = _vsnwprintf(&*fmtout.begin(), fmtout.size(), format, args);\n#else\n$1$2\n#endif/m' "$TSC"
      grep -q '_vsnwprintf' "$TSC" || {
        echo "failed to use the wide vsnprintf in tstrings.cpp" >&2; exit 1; }
      log "Formatting with the wide CRT function in tstrings.cpp"
    fi

    # jpackage's MSI custom actions export themselves through the linker from
    # inside the function body:
    #   __pragma(comment(linker, "/EXPORT:" __FUNCTION__ "=" __FUNCDNAME__));
    #   error: pragma comment requires parenthesized identifier and optional
    #   string
    # __FUNCDNAME__ is the decorated name, and neither it nor a linker comment
    # of that shape exists outside MSVC. The comment above the macro says what
    # it is for: registering the CA with the linker so no .def file is needed.
    # These functions are already extern "C", so __declspec(dllexport) exports
    # each under the plain name MSI looks up, which is the same outcome. Both
    # macros get it, adding it to the definition alone would leave the
    # declaration in JP_CA_DECLARE disagreeing, which clang rejects once the
    # earlier one has been used.
    MCA="$SRC/src/jdk.jpackage/windows/native/common/MsiCA.h"
    if [ -f "$MCA" ] && grep -q '__FUNCDNAME__' "$MCA"; then
      awk '
        index($0, "__pragma(comment(linker, \"/EXPORT:") { next }
        index($0, "__pragma(comment(linker, \"/INCLUDE:") { next }
        index($0, "extern \"C\" UINT name(MSIHANDLE hInstall) {") {
          sub(/extern "C" UINT/, "extern \"C\" __declspec(dllexport) UINT"); print; next
        }
        index($0, "extern \"C\" UINT name(MSIHANDLE); \\") {
          print "    extern \"C\" __declspec(dllexport) UINT name(MSIHANDLE)"; next
        }
        { print }
      ' "$MCA" > "$MCA.tmp" && mv "$MCA.tmp" "$MCA"
      if grep -q '__FUNCDNAME__' "$MCA"; then
        echo "failed to replace the linker-comment exports in MsiCA.h" >&2; exit 1
      fi
      log "Exporting the MSI custom actions with dllexport instead of a linker comment"
    fi

    # The jpackage launchers enter at wmain / wWinMain, the wide entry
    # points, which MSVC's CRT selects on its own:
    #   ld.lld: error: undefined symbol: WinMain
    #   >>> referenced by crtexewin.c:62  libmingw32.a(crtexewin.o):(main)
    # Nothing defines main, so the linker pulled in the mingw shim that
    # provides one and calls WinMain, which nothing defines either. -municode
    # is how mingw is told to start at the wide entry instead. Console and GUI
    # variants both get it; each defines exactly one of the two (JP_LAUNCHERW
    # picks between them), and lld infers the subsystem from which one it is.
    JPL="$SRC/make/modules/jdk.jpackage/Lib.gmk"
    if [ -f "$JPL" ] && ! grep -q 'municode' "$JPL"; then
      awk '
        { print }
        /^ *NAME := jpackageapplauncherw?,/ {
          match($0, /^ */)
          print substr($0, 1, RLENGTH) "LDFLAGS_windows := -municode, \\"
        }
      ' "$JPL" > "$JPL.tmp" && mv "$JPL.tmp" "$JPL"
      [ "$(grep -c municode "$JPL")" = 2 ] || {
        echo "expected to add -municode to both jpackage launchers" >&2; exit 1; }
      log "Starting the jpackage launchers at the wide entry point (-municode)"
    fi

    # The access bridge includes one of its own headers by the wrong name:
    #   JavaAccessBridge.cpp:35: fatal error: 'accessBridgeCallbacks.h' file
    #   not found
    # the file is AccessBridgeCallbacks.h. NTFS never noticed; a linux host
    # does. Same problem as the capitalised windows headers above, except these
    # are the JDK's own, so alias them where they live. Written as a search
    # rather than a rename so a header that really is lowercase,
    # accessBridgeResource.h is one, is left alone.
    ACC="$SRC/src/jdk.accessibility"
    if [ -d "$ACC" ]; then
      grep -rhoE '#[[:space:]]*include[[:space:]]*"[A-Za-z0-9_]+\.h"' "$ACC" 2>/dev/null \
        | grep -oE '"[A-Za-z0-9_]+\.h"' | tr -d '"' | sort -u \
        | while read -r hdr; do
            if find "$ACC" -name "$hdr" | grep -q .; then continue; fi
            real=$(find "$ACC" -iname "$hdr" | head -1)
            [ -n "$real" ] || continue
            ln -s "$(basename "$real")" "$(dirname "$real")/$hdr"
            log "Aliasing $hdr to $(basename "$real")"
          done
    fi

    # And the same jchar/wchar_t split as libsunmscapi, here passing a WCHAR
    # buffer to NewString:
    #   error: cannot initialize a parameter of type 'const jchar *' with an
    #   lvalue of type 'const wchar_t *'
    # The whole module treats the two as one type: every GetStringChars result
    # is cast to const wchar_t* on the way in, and handed back to
    # ReleaseStringChars uncast on the way out. Cast both directions, in every
    # file, rather than one call per probe, there are four NewString and
    # fifteen ReleaseStringChars sites across the two files, two of the latter
    # inside a macro.
    if [ -d "$ACC" ] && grep -rq 'NewString(.*wcslen(\|ReleaseStringChars(' "$ACC"; then
      grep -rl 'NewString(.*wcslen(\|ReleaseStringChars(' "$ACC" | xargs sed -E -i \
        -e 's/NewString\(([A-Za-z_][A-Za-z0-9_]*), \(jsize\)wcslen\(/NewString((const jchar*)\1, (jsize)wcslen(/g' \
        -e 's/ReleaseStringChars\(([A-Za-z_][A-Za-z0-9_]*), ([A-Za-z_][A-Za-z0-9_]*)\)/ReleaseStringChars(\1, (const jchar*)\2)/g'
      log "Casting between WCHAR and jchar at the access bridge's JNI calls"
    fi

    # WinNTFileSystem_md.c sets errno = ENOMEM but includes no <errno.h>; MSVC's
    # headers happen to drag it in, mingw's do not:
    #   WinNTFileSystem_md.c:718: error: use of undeclared identifier 'ENOMEM'
    WNT="$SRC/src/java.base/windows/native/libjava/WinNTFileSystem_md.c"
    if [ -f "$WNT" ] && ! grep -q '^#include <errno.h>$' "$WNT"; then
      perl -0pi -e 's/^#include <limits\.h>$/#include <errno.h>\n#include <limits.h>/m' "$WNT"
      log "Including <errno.h> in WinNTFileSystem_md.c"
    fi

    # java_props_md.c asks SHGetKnownFolderPath for FOLDERID_Profile, which
    # mingw's knownfolders.h at most declares:
    #   ld.lld: error: undefined symbol: FOLDERID_Profile
    # MSVC finds the definition in uuid.lib, which it links by default. Pulling
    # <initguid.h> in first, the documented way to make DEFINE_GUID emit
    # definitions, did not work here: it left the identifier undeclared
    # entirely, so knownfolders.h evidently keys off something other than the
    # INITGUID that header sets. Define the one GUID this file needs outright.
    # A plain definition satisfies both shapes: it stands alone if nothing
    # declared the name, and completes the tentative definition if something
    # did. The value is FOLDERID_Profile as knownfolders.h spells it.
    JPM="$SRC/src/java.base/windows/native/libjava/java_props_md.c"
    if [ -f "$JPM" ] && grep -q 'FOLDERID_Profile' "$JPM" \
       && ! grep -q 'FOLDERID_Profile =' "$JPM"; then
      perl -0pi -e 's/^#include "java_props\.h"$/#include "java_props.h"\n\nconst GUID FOLDERID_Profile =\n    {0x5e6c858f, 0x0e22, 0x4760, {0x9a, 0xfe, 0xea, 0x33, 0x17, 0xb6, 0x71, 0x73}};/m' "$JPM"
      grep -q 'FOLDERID_Profile =' "$JPM" || {
        echo "failed to define FOLDERID_Profile in java_props_md.c" >&2; exit 1; }
      log "Defining FOLDERID_Profile in java_props_md.c"
    fi

    OSW="$SRC/src/hotspot/os/windows/os_windows.cpp"
    if [ -f "$OSW" ] && grep -q '::GetProcAddress' "$OSW"; then
      perl -pi -e 's/^  return ::GetProcAddress\(nullptr, name\);$/  return reinterpret_cast<void*>(::GetProcAddress(nullptr, name));/' "$OSW"
      perl -pi -e 's/^  void\* ret = ::GetProcAddress\(\(HMODULE\)lib, name\);$/  void* ret = reinterpret_cast<void*>(::GetProcAddress((HMODULE)lib, name));/' "$OSW"
      log "Casting the GetProcAddress results in os::dll_lookup and os::lookup_function"
    fi

    # _GNU_SOURCE has no business being defined for a windows target, and it
    # steers shared code down glibc paths:
    #   os.cpp:186: error: no member named 'tm_gmtoff' in 'tm'
    # because os.cpp tests for _GNU_SOURCE before _WINDOWS when picking how to
    # find the UTC offset. flags-cflags.m4 sets it for the whole gcc/clang
    # toolchain family without asking what the target is. Set it only where it
    # means something.
    # The gcc/clang branch hands out ELF linker flags whatever the target is:
    #   lld: error: unknown argument: -soname=jvm.dll
    # PE has no soname, no $ORIGIN and no version scripts. The microsoft branch
    # a few lines below clears exactly these three for exactly this reason, so
    # do the same when clang is aimed at windows. SHARED_LIBRARY_FLAGS stays
    # -shared, which is right for the clang driver producing a DLL.
    FCF="$SRC/make/autoconf/flags-cflags.m4"
    if [ -f "$FCF" ] && grep -q 'SET_SHARED_LIBRARY_NAME=.-Wl,-soname=' "$FCF"; then
      perl -0pi -e 's/(        SET_SHARED_LIBRARY_ORIGIN="-Wl,-z,origin \$SET_EXECUTABLE_ORIGIN"\n      fi\n)/$1\n      if test "x\$OPENJDK_TARGET_OS" = xwindows; then\n        # PE has none of these concepts\n        SET_EXECUTABLE_ORIGIN=\x27\x27\n        SET_SHARED_LIBRARY_ORIGIN=\x27\x27\n        SET_SHARED_LIBRARY_NAME=\x27\x27\n      fi\n/s' "$FCF"
      grep -q 'PE has none of these concepts' "$FCF" &&
        log "Clearing the ELF-only linker flags for a windows target"
    fi

    if [ -f "$FCF" ] && grep -q '^    ALWAYS_DEFINES_JVM="-D_GNU_SOURCE"$' "$FCF"; then
      perl -0pi -e 's/^    ALWAYS_DEFINES_JVM="-D_GNU_SOURCE"$/    if test "x\$OPENJDK_TARGET_OS" = xwindows; then\n      ALWAYS_DEFINES_JVM="-DNOMINMAX"\n    else\n      ALWAYS_DEFINES_JVM="-D_GNU_SOURCE"\n    fi/m' "$FCF"
      log "Swapping _GNU_SOURCE for NOMINMAX on a windows JVM build"
    fi

    # The target was being classified as a unix one, so the build pulled in
    # src/java.base/unix/classes and the other unix source roots:
    #   unix/classes/sun/nio/fs/UnixPath.java: error: cannot find symbol
    # PLATFORM_EXTRACT_VARS_FROM_OS leaves VAR_OS_TYPE alone in its windows
    # branches and relies on the caller defaulting OS_TYPE to VAR_OS. But the
    # build platform is extracted first, and linux sets VAR_OS_TYPE=unix, which
    # is still set when the target pass runs, so the default never applies and
    # the target inherits "unix". A windows host never sees this, because there
    # both passes take the same branch. Set it explicitly.
    for f in "$SRC/make/autoconf/platform.m4" "$SRC/common/autoconf/platform.m4"; do
      [ -f "$f" ] || continue
      grep -q '^      VAR_OS=windows$' "$f" || continue
      perl -0pi -e 's/^      VAR_OS=windows$/      VAR_OS=windows\n      VAR_OS_TYPE=windows/mg' "$f"
      log "Classifying the windows target as OS_TYPE=windows, not unix"
    done

    # From here on the problems are hotspot's rather than the build system's.
    #
    # globalDefinitions_gcc.hpp comes in because the toolchain is clang, and it
    # is written for unix: alloca is in <malloc.h> on mingw, and <dlfcn.h> and
    # <pthread.h> do not exist ("fatal error: 'dlfcn.h' file not found").
    # hotspot reaches dynamic loading and threads through its os layer on
    # windows, so it needs neither. Guarded separately because 21 has the dlfcn
    # and pthread includes but no alloca.h; keying both on alloca silently
    # skipped the dlfcn fix there.
    # The windows halves of ZGC and XGC call XMemory/ZMemory accessors without
    # including the headers that define them:
    #   ld.lld: error: undefined symbol: ZMemory::start() const
    # They reach xMemory.hpp for the declarations, but the bodies are inline in
    # xMemory.inline.hpp and nothing pulls it in. cl.exe hides that by emitting a
    # COMDAT copy of every inline function each TU uses, so another TU's copy
    # satisfies the reference; clang inlines them away and emits nothing. Add the
    # include each file should have had. 21 only: both files are gone in 25.
    for gc in x z; do
      XVM="$SRC/src/hotspot/os/windows/gc/$gc/${gc}VirtualMemory_windows.cpp"
      [ -f "$XVM" ] || continue
      grep -q "^#include \"gc/$gc/${gc}Memory.inline.hpp\"\$" "$XVM" && continue
      perl -pi -e "s{^#include \"gc/$gc/${gc}Mapper_windows\\.hpp\"\$}{#include \"gc/$gc/${gc}Mapper_windows.hpp\"\n#include \"gc/$gc/${gc}Memory.inline.hpp\"}m" "$XVM"
      grep -q "^#include \"gc/$gc/${gc}Memory.inline.hpp\"\$" "$XVM" || {
        echo "failed to include ${gc}Memory.inline.hpp in ${gc}VirtualMemory_windows.cpp" >&2; exit 1; }
      log "Including ${gc}Memory.inline.hpp in ${gc}VirtualMemory_windows.cpp"
    done

    GD="$SRC/src/hotspot/share/utilities/globalDefinitions_gcc.hpp"
    if [ -f "$GD" ] && grep -q '^#include <alloca.h>$' "$GD"; then
      perl -0pi -e 's/^#include <alloca\.h>$/#ifdef __MINGW32__\n#include <malloc.h>\n#else\n#include <alloca.h>\n#endif/m' "$GD"
      log "Taking alloca from <malloc.h> in globalDefinitions_gcc.hpp"
    fi
    if [ -f "$GD" ] && grep -q '^#include <dlfcn.h>$' "$GD"; then
      perl -0pi -e 's/^#include <dlfcn\.h>\n#include <pthread\.h>$/#ifndef __MINGW32__\n#include <dlfcn.h>\n#include <pthread.h>\n#endif/m' "$GD"
      grep -q '^#ifndef __MINGW32__$' "$GD" || {
        echo "failed to guard the unix-only headers in globalDefinitions_gcc.hpp" >&2; exit 1; }
      log "Skipping <dlfcn.h> and <pthread.h> in globalDefinitions_gcc.hpp"
    fi

    # Same header, further down: g_isnan is defined per platform for apple,
    # linux, the BSDs and aix, and anything else gets
    #   error: "missing platform-specific definition here"
    # because windows is expected to have taken globalDefinitions_visCPP.hpp.
    # isnan behaves the same on mingw, so mingw joins the linux branch. Only the
    # #elif is touched, the #if above it pulls in ucontext.h and friends, which
    # mingw genuinely lacks and must keep skipping.
    # 21 spells that branch without _AIX (aix has its own header there), so the
    # _AIX half is optional in the pattern; matching only 25's spelling made this
    # a silent no-op on 21 and left the #error standing.
    if [ -f "$GD" ] && grep -q '^#error "missing platform-specific definition here"$' "$GD"; then
      perl -0pi -e 's/^#elif defined\(LINUX\) \|\| defined\(_ALLBSD_SOURCE\)( \|\| defined\(_AIX\))?$/#elif defined(LINUX) || defined(_ALLBSD_SOURCE)$1 || defined(__MINGW32__)/m' "$GD"
      grep -q '^#elif defined(LINUX) || defined(_ALLBSD_SOURCE).* || defined(__MINGW32__)$' "$GD" || {
        echo "failed to give mingw the g_isnan definitions in globalDefinitions_gcc.hpp" >&2; exit 1; }
      log "Giving mingw the linux g_isnan definitions"
    fi

    # Same header, the include block: 21 puts <inttypes.h> inside the
    # "#if defined(LINUX) || defined(_ALLBSD_SOURCE)" group, so PRIxPTR is never
    # defined on a windows target, globalDefinitions.hpp builds PTR_FORMAT and
    # INTPTR_FORMAT out of it, and every use of either becomes a bare identifier:
    #   growableArray.hpp:334: error: expected ')'
    #   array.hpp:152: error: expected ')'
    # 25 hoisted <inttypes.h> and <stdint.h> out to the top for everyone; give
    # mingw the same two rather than joining the linux branch, which also pulls
    # in <ucontext.h> and <sys/time.h> that mingw has no use for.
    # The test is where the include sits, not whether it is there: on 21 the only
    # <inttypes.h> is below the "#if defined(LINUX)" line, on 25 it is above it
    # and this must do nothing.
    if [ -f "$GD" ] && grep -q '^#include <errno.h>$' "$GD"; then
      gd_inttypes=$(grep -n '^#include <inttypes.h>$' "$GD" | head -n1 | cut -d: -f1)
      gd_linux=$(grep -n '^#if defined(LINUX)' "$GD" | head -n1 | cut -d: -f1)
      if [ -n "$gd_linux" ] && { [ -z "$gd_inttypes" ] || [ "$gd_inttypes" -gt "$gd_linux" ]; }; then
        perl -0pi -e 's/^#include <errno\.h>$/#include <errno.h>\n\n#ifdef __MINGW32__\n\/\/ 21 includes these only for linux and the BSDs; PRIxPTR, and so PTR_FORMAT,\n\/\/ is needed everywhere.\n#include <stdint.h>\n#include <inttypes.h>\n#endif/m' "$GD"
        grep -q '^\/\/ is needed everywhere\.$' "$GD" || {
          echo "failed to add <inttypes.h> for mingw in globalDefinitions_gcc.hpp" >&2; exit 1; }
        log "Including <inttypes.h> on mingw, for PRIxPTR"
      fi
    fi

    # Same header again, 21 and older only: everything that is neither linux nor
    # a BSD gets a block of hand-written "compiler-specific primitive types"
    # (uint16_t, uint32_t, uint64_t, intptr_t, uintptr_t) left over from the
    # Solaris/Studio days, and it assumes ILP32:
    #   globalDefinitions_gcc.hpp:105: error: typedef redefinition with
    #   different types ('int' vs 'long long')
    # against mingw's own corecrt.h. mingw has a complete <stdint.h>, so the
    # whole block is dead weight there; exclude it the same way linux is. 25
    # deleted the block outright, so this finds nothing there.
    if [ -f "$GD" ] && grep -q '^#if !defined(LINUX) && !defined(_ALLBSD_SOURCE)$' "$GD"; then
      perl -0pi -e 's/^#if !defined\(LINUX\) && !defined\(_ALLBSD_SOURCE\)$/#if !defined(LINUX) \&\& !defined(_ALLBSD_SOURCE) \&\& !defined(__MINGW32__)/m' "$GD"
      grep -q '^#if !defined(LINUX) && !defined(_ALLBSD_SOURCE) && !defined(__MINGW32__)$' "$GD" || {
        echo "failed to exclude the legacy primitive typedefs in globalDefinitions_gcc.hpp" >&2; exit 1; }
      log "Skipping the pre-stdint primitive typedefs on mingw"
    fi

    # Same header, the <math.h> include: mingw follows MSVC in hiding M_PI and
    # the other math constants behind _USE_MATH_DEFINES, while glibc defines them
    # unconditionally, so the gcc header never asks for them and 21's parallel GC
    # does not get them:
    #   psParallelCompact.cpp:917: error: use of undeclared identifier 'M_PI'
    # globalDefinitions_visCPP.hpp defines _USE_MATH_DEFINES right before its own
    # <math.h> for exactly this reason; do the same on mingw. It lands on 25 as
    # well, where nothing in hotspot uses M_PI any more; it only makes the
    # constants available, so that is a no-op in effect rather than by guard.
    if [ -f "$GD" ] && grep -q '^#include <math.h>$' "$GD" &&
       ! grep -q '_USE_MATH_DEFINES' "$GD"; then
      perl -0pi -e 's/^#include <math\.h>$/#ifdef __MINGW32__\n\/\/ mingw hides M_PI and friends behind this, as MSVC does; see\n\/\/ globalDefinitions_visCPP.hpp, which defines it for the same reason.\n#define _USE_MATH_DEFINES\n#endif\n#include <math.h>/m' "$GD"
      grep -q '^#define _USE_MATH_DEFINES$' "$GD" || {
        echo "failed to define _USE_MATH_DEFINES for mingw in globalDefinitions_gcc.hpp" >&2; exit 1; }
      log "Asking for the math constants (M_PI) on mingw"
    fi

    # Same header, both LP64 branches: 21 reads _LP64 as "long is 64 bits", which
    # holds for every unix it targets but not for win64, where long stays 32 bits
    # and intptr_t is long long. Two macros come out wrong there, and 25 deleted
    # both, so this whole block is 21-and-older only.
    #
    #   NULL_WORD is 0L under _LP64. LIR_OprFact::intptrConst is overloaded on
    #   void* and intptr_t; on linux 0L matches intptr_t exactly and wins, on
    #   mingw it matches neither exactly:
    #     g1BarrierSetC1.cpp:172: error: call to 'intptrConst' is ambiguous
    #   The !_LP64 branch right below already spells the portable form, for the
    #   same reason (macos, where intptr_t is not int32_t), take that branch.
    if [ -f "$GD" ] && grep -q '^    #define NULL_WORD  0L$' "$GD"; then
      perl -0pi -e 's/^  #ifdef _LP64\n    #define NULL_WORD  0L$/  #if defined(_LP64) \&\& !defined(__MINGW32__)\n    #define NULL_WORD  0L/m' "$GD"
      grep -q '^  #if defined(_LP64) && !defined(__MINGW32__)$' "$GD" || {
        echo "failed to give mingw the portable NULL_WORD" >&2; exit 1; }
      log "Taking the intptr_t-cast NULL_WORD on mingw, not 0L"
    fi
    #   FORMAT64_MODIFIER is "l" under _LP64 except on apple, so every jlong
    #   printed through it would go through a 32-bit conversion on win64. mingw
    #   wants "ll" for the same reason apple does.
    if [ -f "$GD" ] && grep -q '^# define FORMAT64_MODIFIER "l"$' "$GD"; then
      perl -0pi -e 's/^# ifdef __APPLE__\n# define FORMAT64_MODIFIER "ll"$/# if defined(__APPLE__) || defined(__MINGW32__)\n# define FORMAT64_MODIFIER "ll"/m' "$GD"
      grep -q '^# if defined(__APPLE__) || defined(__MINGW32__)$' "$GD" || {
        echo "failed to give mingw the ll FORMAT64_MODIFIER" >&2; exit 1; }
      log "Formatting 64-bit values with ll on mingw, as long is 32 bits there"
    fi

    # jni.h reaches jvm_md.h, which includes <windows.h>, which defines
    # "interface" as a macro for struct. hotspot uses it as an ordinary
    # identifier, opto/type.hpp declares a bool parameter called interface,
    # so the declaration turns into "bool struct" and every call to it then has
    # one argument too many:
    #   type.hpp:958: error: declaration of anonymous struct must be a definition
    #   type.hpp:1332: error: too many arguments to function call, expected 4, have 5
    # MSVC's windows.h defers that definition to the COM headers, which hotspot
    # never pulls in; mingw's defines it up front. Undefine it, and "small"
    # alongside, immediately after the jni.h include that brings them in.
    # Neither is used as a macro anywhere in hotspot.
    if [ -f "$GD" ] && ! grep -q '^#undef interface$' "$GD"; then
      perl -0pi -e 's/^#include "jni\.h"$/#include "jni.h"\n\n#ifdef __MINGW32__\n\/\/ <windows.h>, reached through jni.h, defines these as macros; hotspot uses\n\/\/ them as identifiers.\n#undef interface\n#undef small\n#endif/m' "$GD"
      log "Undefining the windows.h identifier macros (interface, small)"
    fi

    # hotspot poisons sprintf/vsprintf/vsnprintf by redeclaring them extern "C".
    # mingw's stdio.h declares its own ANSI-stdio versions with C++ linkage, so
    # the two collide before anything else can compile:
    #   error: declaration of 'sprintf' has a different language linkage
    # Leave those three unpoisoned on mingw; the os:: replacements they point at
    # are still what the code calls.
    FF="$SRC/src/hotspot/share/utilities/forbiddenFunctions.hpp"
    if [ -f "$FF" ] && grep -q 'FORBID_C_FUNCTION(int sprintf' "$FF"; then
      perl -0pi -e 's/(FORBID_C_FUNCTION\(int sprintf.*?PRAGMA_DIAG_POP\n)/#ifndef __MINGW32__\n$1#endif \/\/ !__MINGW32__\n/s' "$FF"
      log "Not poisoning sprintf/vsprintf/vsnprintf (mingw declares them C++)"
    fi

    # CreateWindowsResourceFile compiles the .rc with RC (windres, fine), then
    # runs the C compiler over it again just to list includes for a dependency
    # file, with -showIncludes -nologo -TC -P -Fi. clang refuses those, and the
    # dependency files are only ever -included, so skipping the step costs
    # nothing on a clean build. Kept for the microsoft toolchain.
    #
    # Fold llvm-mingw's runtime (libunwind, libc++, libwinpthread) into each
    # binary so no DLLs ship beside the JDK. That is as static as Windows gets:
    # the CRT itself is an OS component with no static archive to link. dlopen
    # is unaffected, LoadLibrary being a system call rather than a libc feature.
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

# --- newer-clang fallout ----------------------------------------------------
# llvm-mingw carries clang 22, well ahead of the NDK and zig clangs. Both fixes
# are toolchain-driven rather than platform-driven, so they sit outside the
# windows branch.
#
# harfbuzz trips -Wunused-template in its own headers hundreds of times, and the
# JDK promotes it. Upstream's per-library list is the right place to say
# otherwise; it just predates the warning. The list moved between releases, so
# find it rather than name the file.
hb_warn=0
while IFS= read -r f; do
  grep -q 'HARFBUZZ_DISABLED_WARNINGS_clang := ' "$f" || continue
  grep -q 'HARFBUZZ_DISABLED_WARNINGS_clang := unused-template' "$f" && continue
  sed -i 's/^\([[:space:]]*HARFBUZZ_DISABLED_WARNINGS_clang := \)/\1unused-template /' "$f"
  grep -q 'HARFBUZZ_DISABLED_WARNINGS_clang := unused-template ' "$f" || {
    echo "failed to disable -Wunused-template for harfbuzz in $f" >&2; exit 1; }
  hb_warn=1
done < <(find "$SRC/make" -name '*.gmk')
if [ "$hb_warn" = 1 ]; then
  log "Disabling -Wunused-template for harfbuzz"
fi

# Two jpackage headers lean on includes they used to get transitively:
#   SysInfo.h:83: no type named 'nothrow_t' in namespace 'std'
#   ResourceEditor.h:105: no type named 'streamsize' in namespace 'std'
# The second cascades: with streamsize unknown the istream overload of
# ResourceEditor::apply never declares, so callers resolve to the tstring one.
RESED="$SRC/src/jdk.jpackage/windows/native/libjpackage/ResourceEditor.h"
if [ -f "$RESED" ] && grep -q 'std::streamsize' "$RESED" && ! grep -q '^#include <istream>$' "$RESED"; then
  perl -0pi -e 's/^#include <vector>$/#include <istream>\n#include <vector>/m' "$RESED"
  grep -q '^#include <istream>$' "$RESED" || {
    echo "failed to include <istream> in jpackage's ResourceEditor.h" >&2; exit 1; }
  log "Including <istream> in jpackage's ResourceEditor.h for std::streamsize"
fi

SYSI="$SRC/src/jdk.jpackage/share/native/common/SysInfo.h"
if [ -f "$SYSI" ] && grep -q 'std::nothrow_t' "$SYSI" && ! grep -q '^#include <new>$' "$SYSI"; then
  perl -0pi -e 's/^#include "tstrings\.h"$/#include <new>\n\n#include "tstrings.h"/m' "$SYSI"
  grep -q '^#include <new>$' "$SYSI" || {
    echo "failed to include <new> in jpackage's SysInfo.h" >&2; exit 1; }
  log "Including <new> in jpackage's SysInfo.h for std::nothrow_t"
fi

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

# --- sound: ALSA out, miniaudio in ------------------------------------------
# miniaudio (src/libjsound/PLATFORM_API_MiniAudio_PCM.c) is the PCM provider on
# every platform: it needs nothing at build time and picks a backend at run time.
# Per platform:
#   linux/android  no sysroot has ALSA, bionic has none. Ports and MIDI go too:
#                  the ALSA sources implementing them include <alsa/asoundlib.h>.
#   bsd            OpenJDK has no BSD sound sources at all, but still builds
#                  libjsound with USE_DAUDIO=TRUE, so DAUDIO_* goes undefined.
#                  No native ports/MIDI to keep either.
#   windows/macosx nothing missing; one PCM implementation instead of five. Only
#                  the platform PCM file is dropped, so native ports and MIDI stay.
# 8 is linux-only: its makefile lists sources per OS and its windows port does not
# build yet.
#
# Copy the pinned header and the backend into the platform sound source directory;
# 8 and 11+ disagree on where that is, so the caller passes it in.
install_miniaudio() {
  local dest="$1" header="$BUILD_DIR/miniaudio-$MINIAUDIO_VERSION/miniaudio.h"

  [ -d "$dest" ] || { echo "libjsound sources not found at $dest" >&2; exit 1; }
  [ -f "$MINIAUDIO_BACKEND" ] || {
    echo "miniaudio backend not found at $MINIAUDIO_BACKEND" >&2; exit 1; }
  if [ ! -f "$header" ]; then
    log "Downloading miniaudio $MINIAUDIO_VERSION (libjsound PCM backend)"
    mkdir -p "$(dirname "$header")"
    fetch --dir="$(dirname "$header")" -o miniaudio.h \
      "https://raw.githubusercontent.com/mackron/miniaudio/$MINIAUDIO_VERSION/miniaudio.h"
  fi
  cp "$header" "$dest/miniaudio.h"
  cp "$MINIAUDIO_BACKEND" "$dest/"
}

# The libjsound makefile on 11+: 11 in make/lib/, 17+ in make/modules/.
jsound_makefile() {
  local gmk="$SRC/make/modules/java.desktop/Lib.gmk"
  [ -f "$gmk" ] || gmk="$SRC/make/lib/Lib-java.desktop.gmk"
  [ -f "$gmk" ] || { echo "libjsound makefile not found under $SRC/make" >&2; exit 1; }
  printf '%s\n' "$gmk"
}

# Drop platform sources from libjsound (11+). No release has an EXCLUDE_FILES
# there, so this is always an insertion; values are basenames, which is what
# EXCLUDE_FILES matches on.
jsound_exclude() {
  local gmk="$1" files="$2"
  awk -v excl="$files" '
    { print }
    !done && index($0, "NAME := jsound, \\") {
      match($0, /^[[:space:]]*/)
      print substr($0, 1, RLENGTH) "EXCLUDE_FILES := " excl ", \\"
      done = 1
    }
    END { if (!done) exit 1 }
  ' "$gmk" > "$gmk.tmp" || {
    echo "unexpected $gmk: no libjsound NAME to anchor to" >&2; exit 1; }
  mv "$gmk.tmp" "$gmk"
  grep -q "EXCLUDE_FILES := $files" "$gmk" || {
    echo "failed to exclude $files from libjsound in $gmk" >&2; exit 1; }
}

if [ "$TARGET_OS" = linux ]; then
  if [ "$JDK_VERSION" = 8 ]; then
    log "Building libjsound against miniaudio instead of libjsoundalsa"
    # 8: ALSA lives in its own libjsoundalsa, pulled in only when the makefile
    # adds jsoundalsa to EXTRA_SOUND_JNI_LIBS. Rather than keep a second library
    # alive, fold the miniaudio provider straight into libjsound the way macosx
    # and solaris already fold in their own platform PCM files, libjsound's
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
    JSOUND_GMK="$(jsound_makefile)"
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
      jsound_exclude "$JSOUND_GMK" "$ALSA_SRC"
    fi
  fi
elif [ "$JDK_VERSION" != 8 ]; then
  case "$TARGET_OS" in
    bsd)
      log "Building libjsound against miniaudio (the BSDs ship no sound sources)"
      # Nothing to replace, only a hole to fill. FindSrcDirsForLib wildcards
      # src/<module>/$(OPENJDK_TARGET_OS)/native/lib<name>, so creating the
      # directory is enough to get both files compiled in.
      JSOUND_SRC="$SRC/src/java.desktop/bsd/native/libjsound"
      mkdir -p "$JSOUND_SRC"
      install_miniaudio "$JSOUND_SRC"

      JSOUND_GMK="$(jsound_makefile)"
      if ! grep -q 'LIBS_bsd :=' "$JSOUND_GMK"; then
        # No BSD ports/MIDI to keep; leaving them on leaves PORT_*/MIDI_* undefined.
        sed -i \
          -e 's/-DUSE_PORTS=TRUE/-DUSE_PORTS=FALSE/' \
          -e 's/-DUSE_PLATFORM_MIDI_OUT=TRUE/-DUSE_PLATFORM_MIDI_OUT=FALSE/' \
          -e 's/-DUSE_PLATFORM_MIDI_IN=TRUE/-DUSE_PLATFORM_MIDI_IN=FALSE/' \
          "$JSOUND_GMK"
        # miniaudio needs libm and threads; dlopen is in libc on the BSDs, so
        # there is no -ldl to add. awk, not sed: this sed writes a literal \n
        # rather than a line break, silently merging LIBS_bsd into the next line.
        awk '
          !done && index($0, "LIBS_linux := $(ALSA_LIBS),") {
            match($0, /^[[:space:]]*/)
            print substr($0, 1, RLENGTH) "LIBS_bsd := -lm -lpthread, \\"
            done = 1
          }
          { print }
          END { if (!done) exit 1 }
        ' "$JSOUND_GMK" > "$JSOUND_GMK.tmp" || {
          echo "unexpected $JSOUND_GMK: no LIBS_linux to anchor LIBS_bsd to" >&2; exit 1; }
        mv "$JSOUND_GMK.tmp" "$JSOUND_GMK"
        # -F with the trailing backslash: the continuation is what matters, and
        # this grep will not match a "\\$" in a basic regexp.
        grep -qF 'LIBS_bsd := -lm -lpthread, \' "$JSOUND_GMK" || {
          echo "failed to add LIBS_bsd to libjsound in $JSOUND_GMK" >&2; exit 1; }
      fi
      ;;
    macosx|windows)
      # Only the PCM file goes; the rest of the directory stays, so CoreMIDI /
      # WinMM MIDI and the mixer ports are untouched. Both keep their non-DAUDIO
      # helpers to themselves, checked against every other source there.
      if [ "$TARGET_OS" = macosx ]; then
        JSOUND_SRC="$SRC/src/java.desktop/macosx/native/libjsound"
        JSOUND_PCM=PLATFORM_API_MacOSX_PCM.cpp
        log "Building libjsound's PCM provider on miniaudio, keeping CoreMIDI and the ports"
      else
        JSOUND_SRC="$SRC/src/java.desktop/windows/native/libjsound"
        JSOUND_PCM=PLATFORM_API_WinOS_DirectSound.cpp
        log "Building libjsound's PCM provider on miniaudio, keeping WinMM MIDI and the ports"
      fi
      install_miniaudio "$JSOUND_SRC"
      [ -f "$JSOUND_SRC/$JSOUND_PCM" ] || {
        echo "unexpected $JSOUND_SRC: no $JSOUND_PCM to replace" >&2; exit 1; }

      JSOUND_GMK="$(jsound_makefile)"
      # The library list already carries what miniaudio resolves against
      # (CoreAudio/AudioToolbox on macOS, ole32 for WASAPI on windows), so only
      # the source swap is needed. USE_PORTS and USE_PLATFORM_MIDI_* stay TRUE
      # here, unlike every other platform.
      grep -q "EXCLUDE_FILES := $JSOUND_PCM" "$JSOUND_GMK" ||
        jsound_exclude "$JSOUND_GMK" "$JSOUND_PCM"
      ;;
  esac
fi

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

  # bionic's linker honours DT_RUNPATH and ignores DT_RPATH outright, so a JDK
  # that asks for the old tag cannot find its own libraries and no launcher
  # starts:
  #   WARNING: linker: ... unused DT entry: DT_RPATH (type 0xf arg 0xcf) (ignoring)
  #   CANNOT LINK EXECUTABLE "./java": library "libjli.so" not found
  # OpenJDK asks for it deliberately, RPATH outranks LD_LIBRARY_PATH, so the
  # JDK's internal dependencies cannot be hijacked (JDK-8326891), but on
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
  # take either, the libjvm object count was unchanged with JVM_EXCLUDE_FILES
  # set, so remove the file, which is unambiguous. Patch 0015 supplies the
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
  # hotspot makefiles are handed no libc information, so do it here where the
  # platform is known. Two edits: stop saproc.make building the library, and take
  # it out of the export list, which demands it either way. Only the libsaproc
  # entry goes; ADD_SA_BINARIES also names sa-jdi.jar, which is pure Java and is
  # what the images stage looks for ("No rule to make target sa-jdi.jar").
  # Editing the entry rather than the EXPORT_LIST line keeps the per-arch gating,
  # so Zero targets that never had SA stay untouched.
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

# --- a config.sub that knows android ----------------------------------------
# 8, 11 and 17 ship an autoconf-config.sub from 2008, which predates android and
# rejects every triple built here, configure stops at "checking host system
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
    fetch --dir="$BUILD_DIR" -o autoconf-config.sub "$CONFIG_SUB_URL"
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
    --host="$TARGET" \
    --target="$TARGET" \
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
