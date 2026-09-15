#!/usr/bin/env bash
# Thin wrapper: resolve the OpenJDK GA build tag from the Azul Zulu API, fetch
# that source from the matching openjdk/jdk<N>u repo, download the Azul Zulu JDK
# we use as the boot + interim build JDK, and apply the global (+ per-patchset)
# patches. No state file is written, build.sh recomputes the same paths from
# $ROOTDIR and reads JDK_VERSION from the env, like the sibling repos.
#
#   JDK_VERSION   required feature version: 8 | 11 | 17 | 21 | 25
#   JDK_TAG       optional exact source tag (e.g. jdk-21.0.5+11, jdk8u432-b06);
#                 when unset it is resolved from the Azul Zulu API
#   BOOT_JDK_VERSION optional boot feature (default: same as JDK_VERSION; OpenJDK
#                 builds feature N with a boot JDK of N or N-1)
#   PLATFORM      optional (linux|bsd|windows|macos|android); picks the default
#                 patch set (musl source fixes for the zig linux/bsd targets)
#   PATCHSET      optional extra patch dir under patches/ (e.g. musl); overrides
#                 the PLATFORM-based default
#   TARGET        optional target triple; used to pick the musl patch set when
#                 PLATFORM is unset
#   MINIAUDIO_VERSION  miniaudio release used for libjsound (all platforms)
#   ROOTDIR       work dir (default: cwd)
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${JDK_VERSION:?set JDK_VERSION (8|11|17|21|25)}"
BOOT_JDK_VERSION="${BOOT_JDK_VERSION:-$JDK_VERSION}"

# The musl patch set carries source fixes every zig-built target needs (musl
# linux + the BSDs); bionic (NDK clang), windows (llvm-mingw) and macos
# (osxcross) don't use it.
PATCHSET="${PATCHSET:-}"
if [ -z "$PATCHSET" ]; then
  case "${PLATFORM:-}" in
    linux|bsd) PATCHSET=musl ;;
    "") case "${TARGET:-}" in
          *musl*|*-freebsd-*|*-netbsd-*|*-openbsd-*) PATCHSET=musl ;;
        esac ;;
  esac
fi
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PATCHES_DIR="${PATCHES_DIR:-$SCRIPT_DIR/../patches}"

SRC="${SRC:-$ROOTDIR/jdk-src}"
BOOT_JDK="${BOOT_JDK:-$ROOTDIR/boot-jdk}"

# Shared with build.sh, which recomputes the same paths from $ROOTDIR. The
# scratch dir has to exist here: the edits below write helper scripts into it,
# and it used to be created by the toolchain setup that runs in build.sh.
BUILD_DIR="${BUILD_DIR:-$ROOTDIR/build}"
mkdir -p "$BUILD_DIR"
# OpenJDK's own name for the target OS, which is what the source layout and the
# makefiles key on. build.sh derives the same value from the same two inputs.
case "${PLATFORM:-}" in
  linux|android) TARGET_OS=linux ;;
  bsd)           TARGET_OS=bsd ;;
  windows)       TARGET_OS=windows ;;
  macos)         TARGET_OS=macosx ;;
  *)             TARGET_OS="" ;;
esac

# The triple configure is actually given. build.sh normalises arm64ec to aarch64
# because autoconf has never heard of it, and anything here that asks whether
# the tree can parse a triple has to ask about the same one.
CONF_TRIPLE="${TARGET:-}"
case "${TARGET:-}" in
  arm64ec-*) CONF_TRIPLE="aarch64-${TARGET#*-}" ;;
esac
# The same file 21 and 25 ship, pinned to a tag; see the config.sub block below.
CONFIG_SUB_URL="${CONFIG_SUB_URL:-https://raw.githubusercontent.com/openjdk/jdk21u/jdk-21.0.12%2B8/make/autoconf/build-aux/autoconf-config.sub}"
MINIAUDIO_VERSION="${MINIAUDIO_VERSION:-0.11.25}"
MINIAUDIO_BACKEND="${MINIAUDIO_BACKEND:-$SCRIPT_DIR/../src/libjsound/PLATFORM_API_MiniAudio_PCM.c}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Download with retries so transient GitHub/Azul 5xx recover; aria2's own
# --retry-on-unknown is missing from older builds. --allow-overwrite/
# --auto-file-renaming keep a retry from parking the second attempt beside the
# first as NAME.1. Pass aria2c args, e.g. --dir=/tmp -o f.zip URL.
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

# aria2c cannot detect a truncated download from an endpoint that streams without
# a Content-Length: it has no expected total, so it reports success on a short
# file and the damage surfaces later as "unexpected end of file". Unpacking is
# the only integrity check available, so retry the two together.
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

# Source = the upstream OpenJDK tree. Override JDK_REPO to build from a fork.
JDK_REPO="${JDK_REPO:-https://github.com/openjdk/jdk${JDK_VERSION}u}"

# Resolve the exact GA build tag from the Azul Zulu API unless one was pinned.
# The tag (jdk-21.0.5+11 / jdk8u432-b06) is the upstream OpenJDK git tag that
# Azul ships in their latest GA release. python3 is in the builder image; parse
# JSON with it rather than depending on jq.
if [ -z "${JDK_TAG:-}" ]; then
  log "Resolving latest GA tag for JDK $JDK_VERSION from Azul Zulu API"
  feed="https://api.azul.com/zulu/download/community/v1.0/bundles/latest/?jdk_version=${JDK_VERSION}&os=linux&arch=x64&ext=tar.gz&bundle_type=jdk&release_status=ga"
  fetch --dir=/tmp -o azul-feed.json "$feed"
  JDK_TAG="$(python3 -c '
import json
d = json.load(open("/tmp/azul-feed.json"))
v = d["jdk_version"]
if v[0] == 8:
    # 8u pads the build number to two digits: jdk8u502-b07, not -b7.
    print(f"jdk8u{v[2]}-b{v[3]:02d}")
else:
    print(f"jdk-{v[0]}.{v[1]}.{v[2]}+{v[3]}")
' < /dev/null)"
  rm -f /tmp/azul-feed.json
fi
[ -n "$JDK_TAG" ] || { echo "Failed to resolve a source tag for JDK $JDK_VERSION" >&2; exit 1; }
log "OpenJDK source tag: $JDK_TAG"

# --- OpenJDK source ---------------------------------------------------------
if [ ! -d "$SRC" ]; then
  log "Fetching OpenJDK source ($JDK_REPO @ $JDK_TAG)"
  git clone --quiet --depth 1 --branch "$JDK_TAG" "$JDK_REPO" "$SRC"
fi
# Make $SRC its own git repo so `git apply` resolves patch paths against it and
# not the outer CI checkout (which would silently no-op). The shallow clone above
# already leaves a .git here; re-init is harmless and covers the tarball path.
git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1 || git init -q "$SRC"

# --- boot / build JDK (Azul Zulu) ------------------------------------------
# One Azul Zulu x64 JDK serves as both the boot JDK and, for cross builds, the
# --with-build-jdk that runs the interim Java tools on the build host.
if [ ! -x "$BOOT_JDK/bin/javac" ]; then
  log "Downloading Azul Zulu $BOOT_JDK_VERSION (boot + build JDK, linux x64)"
  # Resolve the download URL from the API (lets us use a plain CDN URL below).
  boot_api="https://api.azul.com/zulu/download/community/v1.0/bundles/latest/?jdk_version=${BOOT_JDK_VERSION}&os=linux&arch=x64&ext=tar.gz&bundle_type=jdk&release_status=ga"
  fetch --dir=/tmp -o azul-boot.json "$boot_api"
  boot_url="$(python3 -c 'import json; print(json.load(open("/tmp/azul-boot.json"))["url"])' < /dev/null)"
  rm -f /tmp/azul-boot.json
  rm -rf "$BOOT_JDK"
  # Azul Zulu archives nest everything under one zulu*-ca-jdk*/ dir; strip it.
  fetch_unpack "$boot_url" "$ROOTDIR/boot-jdk.tar.gz" "$BOOT_JDK" --strip-components=1
fi

# --- patches ----------------------------------------------------------------
# Layout mirrors the sibling repos: patches/<set>/jdk/<feature>/*.patch, applied
# strict for the global set (must apply) and loose for the optional patch set.
apply_set() {
  local dir="$1" strict="$2" p
  [ -d "$dir" ] || return 0
  for p in "$dir"/*.patch; do
    [ -f "$p" ] || continue
    log "patch: $(basename "$p")"
    if [ "$strict" = strict ]; then git -C "$SRC" apply "$p"; else git -C "$SRC" apply "$p" || true; fi
  done
}
[ -n "${PATCHSET:-}" ] && apply_set "$PATCHES_DIR/$PATCHSET/jdk/$JDK_VERSION" loose
apply_set "$PATCHES_DIR/global/jdk/$JDK_VERSION" strict

# --- globalDefinitions_gcc.hpp on mingw -------------------------------------
# The gcc/clang half of hotspot's compiler-specific header, which windows was
# never meant to reach: upstream sends it to globalDefinitions_visCPP.hpp. The
# same edits serve every release here, 8 included, so they take the path as an
# argument rather than assuming the modern source layout.
fix_globaldefinitions_gcc() {
    GD="$1"
    if [ -f "$GD" ] && grep -q '^#include <alloca.h>$' "$GD"; then
      perl -0pi -e 's/^#include <alloca\.h>$/#ifdef __MINGW32__\n#include <malloc.h>\n#else\n#include <alloca.h>\n#endif/m' "$GD"
      log "Taking alloca from <malloc.h> in globalDefinitions_gcc.hpp"
    fi
    # The include survives inside the guard, so test for the guard itself or a
    # second run nests another one around it.
    if [ -f "$GD" ] && grep -q '^#include <dlfcn.h>$' "$GD" &&
       ! grep -q '^#ifndef __MINGW32__$' "$GD"; then
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
      # 8 spells the include "prims/jni.h"; keep whichever form is there.
      perl -0pi -e 's/^(#include "(?:prims\/)?jni\.h")$/$1\n\n#ifdef __MINGW32__\n\/\/ <windows.h>, reached through jni.h, defines these as macros; hotspot uses\n\/\/ them as identifiers.\n#undef interface\n#undef small\n#endif/m' "$GD"
      log "Undefining the windows.h identifier macros (interface, small)"
    fi
}

# --- windows: source fixes ---------------------------------------------------
# Everything the llvm-mingw cross build needs changed in the tree. Kept at the
# indentation it had in build.sh's platform case: five heredocs below would
# break if these lines were re-indented.
# Everything below was written against the modern source layout, where hotspot
# lives at src/hotspot and the JDK at src/java.*. 8 predates that: it is still
# the multi-repo forest, hotspot/ and jdk/ and corba/ beside each other, with a
# build system to match. Not one of these edits finds its file there, and the
# handful whose makefiles happen to share a path find a different file inside.
# A windows port for 8 is its own piece of work; until it exists, let 8 reach
# its own errors rather than stopping inside guards written for another tree.
if [ "${PLATFORM:-}" = windows ] && [ "${JDK_VERSION}" != 8 ]; then
    # Upstream has no windows port for 32-bit ARM: hotspot builds os_cpu from
    # <os>_<cpu>, and only windows_x86 and windows_aarch64 exist, so the VM stops
    # at "globals_windows_arm.hpp file not found". The port lives in this repo
    # rather than in a patch because the directory is new in every release, so a
    # patch would have to be duplicated once per version. arm64ec is deliberately
    # not matched here: it is 64-bit and configures as aarch64.
    case "${TARGET:-}" in
      arm-w64-mingw32|armv7*-w64-mingw32|thumb*-w64-mingw32)
        PORT_SRC="$SCRIPT_DIR/../src/hotspot/os_cpu/windows_arm"
        PORT_DST="$SRC/src/hotspot/os_cpu/windows_arm"
        if [ -d "$PORT_SRC" ]; then
          mkdir -p "$PORT_DST"
          cp "$PORT_SRC"/* "$PORT_DST/"
          log "Installed the windows_arm hotspot port ($(ls -1 "$PORT_DST" | wc -l) files)"

          # Most of this directory is os_cpu/linux_arm under another name, and
          # that tree moves between releases in both content and file names:
          # thread_* became javaThread_* in 21, copy_*.inline.hpp became
          # copy_*.hpp, 17 writes "memval_lo + 1" where 25 writes
          # as_Register(memval_lo->encoding() + 1). So mirror the release's own
          # linux_arm set rather than carrying a fixed copy, and keep only the
          # files that are genuinely different on windows.
          ARM_SRC="$SRC/src/hotspot/os_cpu/linux_arm"
          A64_SRC="$SRC/src/hotspot/os_cpu/windows_aarch64"
          for d in "$ARM_SRC" "$A64_SRC"; do
            [ -d "$d" ] || { echo "expected $d in this release" >&2; exit 1; }
          done
          for f in "$ARM_SRC"/*; do
            b=$(basename "$f")
            case "$b" in
              # linux assembly with no windows counterpart, and the files the
              # port replaces outright
              *.S|*.s) continue ;;
              os_linux_arm.cpp|thread_linux_arm.cpp|javaThread_linux_arm.cpp) continue ;;
              vm_version_linux_arm_32.cpp|atomic_linux_arm.hpp) continue ;;
              copy_linux_arm.hpp|copy_linux_arm.inline.hpp) continue ;;
              globals_linux_arm.hpp|vmStructs_linux_arm.hpp) continue ;;
              # linux_arm swaps bytes with glibc's <byteswap.h>; the windows
              # copy uses the _byteswap_* intrinsics, and byte order is the
              # same on both ARM targets, so take that one below
              bytes_linux_arm.hpp|bytes_linux_arm.inline.hpp) continue ;;
              # only the releases that include OS_CPU_HEADER(os) want this one
              os_linux_arm.hpp)
                grep -q 'OS_CPU_HEADER(os)' "$SRC/src/hotspot/share/runtime/os.hpp" || continue ;;
            esac
            out=$(echo "$b" | sed 's/linux_arm/windows_arm/')
            sed -e 's/LINUX_ARM/WINDOWS_ARM/g' -e 's/linux_arm/windows_arm/g' "$f" > "$PORT_DST/$out"
          done
          # The atomics are this release's own file with the kernel helper calls
          # replaced: windows has no helper page at 0xffff0fxx and no pre-v7 CPU,
          # so each one becomes a compiler builtin. Deriving rather than carrying a
          # copy keeps the method names and specializations the release expects:
          # 17 spells the adds add_and_fetch and has no AddUsingCmpxchg, 21 renamed
          # them and added it, and 11 passes the value before the destination.
          python3 - "$ARM_SRC/atomic_linux_arm.hpp" "$PORT_DST/atomic_windows_arm.hpp" <<'PYEOF'
import io, sys

src, dst = sys.argv[1], sys.argv[2]
s = io.open(src, encoding='utf-8', newline='').read()
s = s.replace('LINUX_ARM', 'WINDOWS_ARM').replace('linux_arm', 'windows_arm')

# The kernel user helper page at 0xffff0fxx does not exist on windows, and no
# windows ARM CPU predates v7, so every read-modify-write goes to the compiler
# builtin, which lowers to ldrex/strex plus dmb. Everything else about the file,
# the method names and which specializations exist, is left exactly as this
# release wrote it: 17 spells the adds add_and_fetch and has no
# AddUsingCmpxchg, 21 renamed them and added it.
CAS_HELPER = '''
// windows has no kernel helper page to call, so compare-and-swap goes straight
// to the builtin. It reports the value it saw through its expected argument,
// and hotspot wants that value whether or not the swap happened.
template<typename T>
inline T hs_windows_arm_cas(T volatile* dest, T compare_value, T exchange_value) {
  T expected = compare_value;
  __atomic_compare_exchange_n(dest, &expected, exchange_value,
                              /*weak*/ false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
  return expected;
}

'''

def alt(cands, label, required=True):
    global s
    for old, new in cands:
        if s.count(old) == 1:
            s = s.replace(old, new, 1)
            return
    if required:
        raise SystemExit("atomic_windows_arm.hpp: %s matched no known form" % label)

# 17 reaches the helpers as os::atomic_*_func; 21 moved them to ARMAtomicFuncs.
alt([("(*os::atomic_load_long_func)(reinterpret_cast<const volatile int64_t*>(src))",
      "__atomic_load_n(reinterpret_cast<const volatile int64_t*>(src), __ATOMIC_SEQ_CST)"),
     ("(*ARMAtomicFuncs::_load_long_func)(reinterpret_cast<const volatile int64_t*>(src))",
      "__atomic_load_n(reinterpret_cast<const volatile int64_t*>(src), __ATOMIC_SEQ_CST)")],
    "64-bit load")

alt([("(*os::atomic_store_long_func)(\n"
      "    PrimitiveConversions::cast<int64_t>(store_value), reinterpret_cast<volatile int64_t*>(dest));",
      "__atomic_store_n(reinterpret_cast<volatile int64_t*>(dest),\n"
      "                   PrimitiveConversions::cast<int64_t>(store_value), __ATOMIC_SEQ_CST);"),
     ("(*ARMAtomicFuncs::_store_long_func)(\n"
      "    PrimitiveConversions::cast<int64_t>(store_value), reinterpret_cast<volatile int64_t*>(dest));",
      "__atomic_store_n(reinterpret_cast<volatile int64_t*>(dest),\n"
      "                   PrimitiveConversions::cast<int64_t>(store_value), __ATOMIC_SEQ_CST);")],
    "64-bit store")

alt([("add_using_helper<int32_t>(os::atomic_add_func, dest, add_value)",
      "__atomic_add_fetch(dest, add_value, __ATOMIC_SEQ_CST)"),
     ("add_using_helper<int32_t>(ARMAtomicFuncs::_add_func, dest, add_value)",
      "__atomic_add_fetch(dest, add_value, __ATOMIC_SEQ_CST)"),
     ("add_using_helper<int32_t>(os::atomic_add_func, add_value, dest)",
      "__atomic_add_fetch(dest, add_value, __ATOMIC_SEQ_CST)")],
    "32-bit add")

alt([("xchg_using_helper<int32_t>(os::atomic_xchg_func, dest, exchange_value)",
      "__atomic_exchange_n(dest, exchange_value, __ATOMIC_SEQ_CST)"),
     ("xchg_using_helper<int32_t>(ARMAtomicFuncs::_xchg_func, dest, exchange_value)",
      "__atomic_exchange_n(dest, exchange_value, __ATOMIC_SEQ_CST)"),
     ("xchg_using_helper<int32_t>(os::atomic_xchg_func, exchange_value, dest)",
      "__atomic_exchange_n(dest, exchange_value, __ATOMIC_SEQ_CST)")],
    "32-bit exchange")

alt([("cmpxchg_using_helper<int32_t>(reorder_cmpxchg_func, dest, compare_value, exchange_value)",
      "hs_windows_arm_cas(dest, compare_value, exchange_value)"),
     ("cmpxchg_using_helper<int32_t>(reorder_cmpxchg_func, exchange_value, dest, compare_value)",
      "hs_windows_arm_cas(dest, compare_value, exchange_value)")],
    "32-bit compare-and-swap")

alt([("cmpxchg_using_helper<int64_t>(reorder_cmpxchg_long_func, dest, compare_value, exchange_value)",
      "hs_windows_arm_cas(dest, compare_value, exchange_value)"),
     ("cmpxchg_using_helper<int64_t>(reorder_cmpxchg_long_func, exchange_value, dest, compare_value)",
      "hs_windows_arm_cas(dest, compare_value, exchange_value)")],
    "64-bit compare-and-swap")

# the two reorder wrappers only existed to swap arguments for the kernel call
for name in ('reorder_cmpxchg_func', 'reorder_cmpxchg_long_func'):
    start = s.find('inline int' + ('64_t ' if 'long' in name else '32_t ') + name)
    if start == -1:
        continue
    end = s.index('\n}\n', start) + len('\n}\n')
    s = s[:start] + s[end:]

anchor = 'template<>\ntemplate<typename T>\ninline T Atomic::PlatformLoad<8>'
if s.count(anchor) != 1:
    raise SystemExit("atomic_windows_arm.hpp: cannot place the cas helper")
s = s.replace(anchor, CAS_HELPER + anchor, 1)

# only a surviving helper *call* matters; the ARMAtomicFuncs declaration itself
# is unused and harmless
for leftover in ('cmpxchg_using_helper', 'add_using_helper', 'xchg_using_helper'):
    if leftover in s:
        raise SystemExit("atomic_windows_arm.hpp: %s survived" % leftover)

io.open(dst, 'w', encoding='utf-8', newline='').write(s)
PYEOF

          # vmStructs, the inline os header and the byte swaps are OS-shaped
          # rather than CPU-shaped, so they come from the windows port instead.
          for b in vmStructs_windows_aarch64.hpp os_windows_aarch64.inline.hpp                    bytes_windows_aarch64.hpp bytes_windows_aarch64.inline.hpp; do
            [ -f "$A64_SRC/$b" ] || continue
            out=$(echo "$b" | sed 's/windows_aarch64/windows_arm/')
            sed -e 's/WINDOWS_AARCH64/WINDOWS_ARM/g' -e 's/windows_aarch64/windows_arm/g'                 "$A64_SRC/$b" > "$PORT_DST/$out"
          done
          # 11's cpu/arm carries both the 32-bit and the 64-bit ARM sources, and
          # the exclusion that picks one is keyed on the target being linux:
          #   assembler_arm_64.cpp: no member named 'LogicalImmediate'
          # Which width to build depends on the CPU, not the OS. Later releases
          # keep the same linux-only gate but ship no _64 files, so widening it
          # changes nothing there.
          CJVM="$SRC/make/hotspot/lib/CompileJvm.gmk"
          if [ -f "$CJVM" ] && grep -q 'isTargetOs, linux) $(call isTargetCpu, arm))' "$CJVM"; then
            sed -i 's@$(call isTargetOs, linux) $(call isTargetCpu, arm))@$(call isTargetOs, linux windows) $(call isTargetCpu, arm))@' "$CJVM"
            if ! grep -q 'isTargetOs, linux windows) $(call isTargetCpu, arm))' "$CJVM"; then
              echo "failed to widen the ARM source selection to windows" >&2; exit 1
            fi
            log "Excluding the 64-bit ARM sources on a 32-bit ARM windows target"
          fi

          # print_tos_pc is per-os_cpu in 17, shared windows code in 21 and 25,
          # and absent in 11. Keep the port's copy only where this release's own
          # windows_aarch64 carries one.
          if ! grep -q 'void os::print_tos_pc' "$A64_SRC/os_windows_aarch64.cpp"; then
            python3 - "$PORT_DST/os_windows_arm.cpp" "// BEGIN print_tos_pc" "// END print_tos_pc" <<'PYEOF'
import io, sys
p, b, e = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(p, encoding='utf-8', newline='').read()
start = s.index(b)
end = s.index(e) + len(e) + 1
io.open(p, 'w', encoding='utf-8', newline='').write(s[:start] + s[end:])
PYEOF
            log "Leaving print_tos_pc out, which this release defines elsewhere"
          fi

          # 11 wraps the pc in an ExtendedPC, hands the call wrapper a Thread*
          # rather than a JavaThread*, and has no PRAGMA_DISABLE_MSVC_WARNING.
          # Keep whichever prologue this release's own windows_aarch64 uses.
          if grep -q 'ExtendedPC os::fetch_frame_from_context' "$A64_SRC/os_windows_aarch64.cpp"; then
            pro_begin='// BEGIN prologue, address pc'
            pro_end='// END prologue, address pc'
          else
            pro_begin='// BEGIN prologue, ExtendedPC'
            pro_end='// END prologue, ExtendedPC'
          fi
          python3 - "$PORT_DST/os_windows_arm.cpp" "$pro_begin" "$pro_end" <<'PYEOF'
import io, sys
p, b, e = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(p, encoding='utf-8', newline='').read()
start = s.index(b)
end = s.index(e) + len(e) + 1
io.open(p, 'w', encoding='utf-8', newline='').write(s[:start] + s[end:])
PYEOF
          if [ "$(grep -c 'os::os_exception_wrapper' "$PORT_DST/os_windows_arm.cpp")" != 1 ]; then
            echo "expected exactly one prologue after trimming" >&2; exit 1
          fi
          log "Keeping the prologue this release uses"

          # print_register_info gained a continuation index in 21 so the error
          # handler can print registers in bounded chunks. The port carries both
          # shapes; keep the one this release declares.
          if grep -q 'print_register_info(outputStream\* st, const void\* context, int& continuation)'                   "$SRC/src/hotspot/share/runtime/os.hpp"; then
            drop_begin='// BEGIN print_register_info without continuation'
            drop_end='// END print_register_info without continuation'
          else
            drop_begin='// BEGIN print_register_info with continuation'
            drop_end='// END print_register_info with continuation'
          fi
          python3 - "$PORT_DST/os_windows_arm.cpp" "$drop_begin" "$drop_end" <<'PYEOF'
import io, sys
p, b, e = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(p, encoding='utf-8', newline='').read()
start = s.index(b)
end = s.index(e) + len(e) + 1
io.open(p, 'w', encoding='utf-8', newline='').write(s[:start] + s[end:])
PYEOF
          if [ "$(grep -c 'void os::print_register_info' "$PORT_DST/os_windows_arm.cpp")" != 1 ]; then
            echo "expected exactly one print_register_info after trimming" >&2; exit 1
          fi
          log "Keeping the print_register_info this release declares"

          # JavaThread moved out of runtime/thread.hpp into runtime/javaThread.hpp
          # in 21, and the port's own sources include the newer name.
          if [ ! -f "$SRC/src/hotspot/share/runtime/javaThread.hpp" ]; then
            sed -i 's|#include "runtime/javaThread.hpp"|#include "runtime/thread.hpp"|'                 "$PORT_DST"/*.cpp
            if grep -rq 'runtime/javaThread.hpp' "$PORT_DST"; then
              echo "port still includes runtime/javaThread.hpp, which this release lacks" >&2; exit 1
            fi
            log "Including runtime/thread.hpp, which is where JavaThread lives here"
          fi

          # The port's own javaThread body follows the release's spelling.
          if [ -f "$ARM_SRC/thread_linux_arm.cpp" ] && [ -f "$PORT_DST/javaThread_windows_arm.cpp" ]; then
            mv "$PORT_DST/javaThread_windows_arm.cpp" "$PORT_DST/thread_windows_arm.cpp"
          fi
          # pd_get_top_frame reads the same fetch_frame_from_context the prologue
          # above accounts for, so where that returns an ExtendedPC the caller
          # needs .pc(). After the rename, so the file is under its final name.
          if grep -q 'ExtendedPC os::fetch_frame_from_context' "$A64_SRC/os_windows_aarch64.cpp"; then
            for tf in "$PORT_DST/javaThread_windows_arm.cpp" "$PORT_DST/thread_windows_arm.cpp"; do
              [ -f "$tf" ] || continue
              sed -i 's|os::fetch_frame_from_context(ucontext, &ret_sp, &ret_fp);|os::fetch_frame_from_context(ucontext, \&ret_sp, \&ret_fp).pc();|' "$tf"
              if grep -q 'fetch_frame_from_context(ucontext, &ret_sp, &ret_fp);' "$tf"; then
                echo "failed to unwrap the ExtendedPC in $tf" >&2; exit 1
              fi
            done
            log "Unwrapping the ExtendedPC the javaThread body reads"
          fi
          # and so does the copy header, which is .inline.hpp before 17.
          if [ -f "$ARM_SRC/copy_linux_arm.inline.hpp" ] && [ -f "$PORT_DST/copy_windows_arm.hpp" ]; then
            mv "$PORT_DST/copy_windows_arm.hpp" "$PORT_DST/copy_windows_arm.inline.hpp"
          fi
          log "windows_arm port: $(ls -1 "$PORT_DST" | wc -l) files for this release"
          # os::fetch_bcp_from_context arrived in 24. The port carries it, so
          # drop it, and the assert helper only it uses, where os.hpp does not
          # declare it, rather than keeping a second copy of the file.
          if ! grep -q 'fetch_bcp_from_context' "$SRC/src/hotspot/share/runtime/os.hpp"; then
            python3 - "$PORT_DST/os_windows_arm.cpp" <<'PYEOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8', newline='').read()
start = s.index('#ifdef ASSERT\nstatic bool is_interpreter')
end = s.index('\n', s.index('intptr_t* os::fetch_bcp_from_context'))
end = s.index('\n}\n', end) + len('\n}\n')
io.open(p, 'w', encoding='utf-8', newline='').write(s[:start] + s[end:])
PYEOF
            if grep -q 'fetch_bcp_from_context' "$PORT_DST/os_windows_arm.cpp"; then
              echo "failed to drop fetch_bcp_from_context from the windows_arm port" >&2; exit 1
            fi
            log "Dropping fetch_bcp_from_context, which this release does not declare"
          fi
        else
          echo "windows_arm port sources missing at $PORT_SRC" >&2; exit 1
        fi

        # os_windows.cpp branches on _M_ARM64 and _M_AMD64 and stops at #error
        # for anything else, so every arch-specific site needs a 32-bit ARM arm:
        #   os_windows.cpp:132: error: "Unknown CPU"
        #   os_windows.cpp:2487: error: unknown architecture
        # Each substitution below insists on matching exactly once, so an
        # upstream rewrite fails here rather than silently skipping a site.
        # Only ARM32 targets run this; the others must not be able to break on it.
        python3 - "$SRC/src/hotspot/os/windows/os_windows.cpp" <<'PYEOF'
import io, sys

path = sys.argv[1]
s = io.open(path, encoding='utf-8', newline='').read()
orig = s

# Every site below inserts an arm after the _M_AMD64 one rather than before the
# closing #else, because only the #else differs across releases: 25 ends these
# chains with #error, while 21 and earlier still carry an _M_IX86 arm. Anchoring
# on the AMD64 arm makes one patch serve every version, and each substitution
# still insists on an exact number of matches.
def sub(old, new, label, want=1):
    global s
    n = s.count(old)
    if want == "optional":
        if n:
            s = s.replace(old, new)
        return
    if want == "all":
        if n == 0:
            raise SystemExit("os_windows.cpp: %s matched nothing" % label)
        s = s.replace(old, new)
        return
    if n != want:
        raise SystemExit("os_windows.cpp: %s matched %d times, expected %d"
                         % (label, n, want))
    s = s.replace(old, new)

def alt(cands, label, optional=False):
    # exactly one release-specific spelling must match, unless the site is
    # absent or already covered by a broader replacement above
    global s
    for old, new in cands:
        if s.count(old) == 1:
            s = s.replace(old, new, 1)
            return
    if optional:
        return
    raise SystemExit("os_windows.cpp: %s matched no known form" % label)

# The arch name in the fatal error header.
sub("  #define __CPU__ amd64\n",
    "  #define __CPU__ amd64\n#elif defined(_M_ARM)\n  #define __CPU__ arm\n",
    "__CPU__")

# dll_load's architecture check. ARMNT is the machine code windows gives a
# 32-bit ARM image; there is no separate one for the ARM/Thumb split.
sub('    {IMAGE_FILE_MACHINE_ARM64,     (char*)"ARM 64"}\n  };',
    '    {IMAGE_FILE_MACHINE_ARM64,     (char*)"ARM 64"},\n'
    '    {IMAGE_FILE_MACHINE_ARMNT,     (char*)"ARM 32"}\n  };',
    "arch_array")

sub("  static const uint16_t running_arch = IMAGE_FILE_MACHINE_AMD64;\n",
    "  static const uint16_t running_arch = IMAGE_FILE_MACHINE_AMD64;\n"
    "#elif (defined _M_ARM)\n"
    "  static const uint16_t running_arch = IMAGE_FILE_MACHINE_ARMNT;\n",
    "running_arch")

# The program counter's name in CONTEXT.
sub("  #define PC_NAME Rip\n",
    "  #define PC_NAME Rip\n#elif defined(_M_ARM)\n  #define PC_NAME Pc\n",
    "PC_NAME")

# DWORD64 truncates where CONTEXT::Pc is 32 bits; DWORD_PTR is pointer-sized on
# both and is what the rest of this file assigns to a context register.
sub("  exceptionInfo->ContextRecord->PC_NAME = (DWORD64)handler;",
    "  exceptionInfo->ContextRecord->PC_NAME = (DWORD_PTR)handler;",
    "PC_NAME assignment")

# ARM does not trap on integer division: sdiv yields min_jint for min_jint/-1
# and a zero divisor is tested before the divide, so this cannot be reached.
sub("  ctx->Rdx = (DWORD)0;             // remainder\n"
    "  // Continue the execution\n",
    "  ctx->Rdx = (DWORD)0;             // remainder\n"
    "  // Continue the execution\n"
    "#elif defined(_M_ARM)\n"
    "  // ARM does not trap on integer division: sdiv yields min_jint for\n"
    "  // min_jint/-1, and a zero divisor is checked before the divide.\n"
    "  ShouldNotReachHere();\n",
    "Handle_IDiv_Exception")

# The pc in topLevelExceptionFilter and topLevelVectoredExceptionFilter, which
# spell this identically, hence both.
sub("#if defined(_M_ARM64)\n"
    "  address pc = (address) exceptionInfo->ContextRecord->Pc;\n"
    "#elif defined(_M_AMD64)\n"
    "  address pc = (address) exceptionInfo->ContextRecord->Rip;\n",
    "#if defined(_M_ARM64)\n"
    "  address pc = (address) exceptionInfo->ContextRecord->Pc;\n"
    "#elif defined(_M_AMD64)\n"
    "  address pc = (address) exceptionInfo->ContextRecord->Rip;\n"
    "#elif defined(_M_ARM)\n"
    "  address pc = (address) exceptionInfo->ContextRecord->Pc;\n",
    "top level filter pc", want="all")

# topLevelUnhandledExceptionFilter. 25 and 21 indent it one level deeper than
# the other two filters; 17 keeps it level with them and drops the space after
# the cast on the ARM64 arm, so the spelling has to be tried both ways.
alt([("#if defined(_M_ARM64)\n"
      "    address pc = (address) exceptionInfo->ContextRecord->Pc;\n"
      "#elif defined(_M_AMD64)\n"
      "    address pc = (address) exceptionInfo->ContextRecord->Rip;\n",
      "#if defined(_M_ARM64)\n"
      "    address pc = (address) exceptionInfo->ContextRecord->Pc;\n"
      "#elif defined(_M_AMD64)\n"
      "    address pc = (address) exceptionInfo->ContextRecord->Rip;\n"
      "#elif defined(_M_ARM)\n"
      "    address pc = (address) exceptionInfo->ContextRecord->Pc;\n"),
     ("#if defined(_M_ARM64)\n"
      "  address pc = (address)exceptionInfo->ContextRecord->Pc;\n"
      "#elif defined(_M_AMD64)\n"
      "  address pc = (address) exceptionInfo->ContextRecord->Rip;\n",
      "#if defined(_M_ARM64)\n"
      "  address pc = (address)exceptionInfo->ContextRecord->Pc;\n"
      "#elif defined(_M_AMD64)\n"
      "  address pc = (address) exceptionInfo->ContextRecord->Rip;\n"
      "#elif defined(_M_ARM)\n"
      "  address pc = (address)exceptionInfo->ContextRecord->Pc;\n")],
    "unhandled filter pc", optional=True)

# Assembler::locate_next_instruction exists on aarch64 and x86 but not on
# 32-bit ARM, where every instruction is the same width. os_cpu/linux_arm
# computes the same thing as pc + Assembler::InstructionSize.
# 11 inlines this into the Handle_Exception argument instead of naming a
# next_pc local first, so it needs a helper rather than a block.
alt([("        address next_pc =  Assembler::locate_next_instruction(pc);",
      "#ifdef _M_ARM\n"
      "        address next_pc = pc + Assembler::InstructionSize;\n"
      "#else\n"
      "        address next_pc =  Assembler::locate_next_instruction(pc);\n"
      "#endif"),
     ("SharedRuntime::handle_unsafe_access(thread, (address)Assembler::locate_next_instruction(pc))",
      "SharedRuntime::handle_unsafe_access(thread, hs_windows_next_pc(pc))")],
    "locate_next_instruction")

if "hs_windows_next_pc(pc)" in s:
    HELPER = """
// os_cpu/linux_arm computes the next pc as pc + Assembler::InstructionSize.
// There is no locate_next_instruction on 32-bit ARM, where every instruction
// is the same width.
static inline address hs_windows_next_pc(address pc) {
#ifdef _M_ARM
  return pc + Assembler::InstructionSize;
#else
  return (address)Assembler::locate_next_instruction(pc);
#endif
}

"""
    _anchor = "LONG Handle_Exception(struct _EXCEPTION_POINTERS* exceptionInfo,"
    if s.count(_anchor) != 1:
        raise SystemExit("os_windows.cpp: cannot place the next-pc helper")
    s = s.replace(_anchor, HELPER + _anchor, 1)

# The thread-sampling context flags. 21 puts an IA32 arm ahead of this one, so
# match the condition itself rather than the directive in front of it.
sub("defined(AMD64) || defined(_M_ARM64)\n"
    "  #define sampling_context_flags (CONTEXT_FULL | CONTEXT_FLOATING_POINT)\n",
    "defined(AMD64) || defined(_M_ARM64) || defined(_M_ARM)\n"
    "  #define sampling_context_flags (CONTEXT_FULL | CONTEXT_FLOATING_POINT)\n",
    "sampling_context_flags")

# 21 and earlier keep their 32-bit windows code behind #ifndef _WIN64, and all
# of it is x86-32: stdcall name decoration, the NX protection checks, the FLT
# control word handler and the fast JNI accessor's __try. 32-bit ARM is not
# _WIN64 either, so it would compile every one of them:
#   os_windows.cpp: no member named 'Eip' in '_CONTEXT'
#   os_windows.cpp: use of undeclared identifier 'handle_FLT_exception'
# 25 dropped 32-bit windows and has none of these blocks left.
sub("#ifndef _WIN64\n",
    "#if !defined(_WIN64) && !defined(_M_ARM)\n",
    "32-bit windows blocks", want="optional")

# 11 spells one of them with two spaces, and it guards x87 control word asm
sub("#ifndef  _WIN64\n",
    "#if !defined(_WIN64) && !defined(_M_ARM)\n",
    "32-bit windows blocks, double space", want="optional")

if s == orig:
    raise SystemExit("os_windows.cpp: nothing changed")
io.open(path, 'w', encoding='utf-8', newline='').write(s)
PYEOF
        log "Giving os_windows.cpp its 32-bit ARM branches"
        ;;
      arm64ec-w64-mingw32)
        # ARM64EC is the x64-compatible ABI on ARM64 hardware, so windows hands
        # out an AMD64-shaped CONTEXT and clang defines _M_AMD64. hotspot is
        # built for aarch64, so os_windows_aarch64.cpp asks a CONTEXT for Pc and
        # X0 that are not there, while the shared file takes its AMD64 arms into
        # an x86 Assembler and VM_Version:
        #   os_windows_aarch64.cpp:83: no member named 'Pc' in '_CONTEXT'
        #   os_windows.cpp: no member named 'REX' in 'Assembler'
        # ARM64EC_NT_CONTEXT names the same bytes with the ARM64 registers, so
        # the fix is to read the context through it and to send every
        # arch-specific site down the aarch64 arm.
        python3 - "$SRC/src/hotspot/os/windows/os_windows.cpp" \
                 "$SRC/src/hotspot/os_cpu/windows_aarch64/os_windows_aarch64.cpp" <<'PYEOF'
import io, sys

shared, oscpu = sys.argv[1], sys.argv[2]

def edit(path, subs):
    s = io.open(path, encoding='utf-8', newline='').read()
    for old, new, label, want in subs:
        n = s.count(old)
        # want is an exact count, None for "one or more", or "optional" for a
        # site only some releases have. Releases differ in how often a form
        # appears, so a fixed count is not always the right check.
        if want == "optional":
            if n:
                s = s.replace(old, new)
            continue
        if want is None:
            if n == 0:
                raise SystemExit("%s: %s matched nothing" % (path.split('/')[-1], label))
        elif n != want:
            raise SystemExit("%s: %s matched %d times, expected %d"
                             % (path.split('/')[-1], label, n, want))
        s = s.replace(old, new)
    io.open(path, 'w', encoding='utf-8', newline='').write(s)

def alt(path, cands, label, optional=False):
    # exactly one release-specific spelling must match, unless the site itself
    # is absent from this release
    s = io.open(path, encoding='utf-8', newline='').read()
    for old, new in cands:
        if s.count(old) == 1:
            io.open(path, 'w', encoding='utf-8', newline='').write(s.replace(old, new, 1))
            return
    if optional:
        return
    raise SystemExit("%s: %s matched no known form" % (path.split('/')[-1], label))

# An ARM64EC process is x64-compatible, so every CONTEXT windows hands us is the
# AMD64 structure. ARM64EC_NT_CONTEXT names the same bytes with the ARM64
# registers (X0 sits in Rcx, Sp in Rsp, Pc in Rip), so this is a
# reinterpretation and not a conversion. HS_ARM64_CTX is the identity anywhere
# else, which lets the shared accesses below stay in one form.
CTX_MACRO = """
#if defined(__arm64ec__)
  #define HS_ARM64_CTX(c) ((PARM64EC_NT_CONTEXT)(c))
#else
  #define HS_ARM64_CTX(c) (c)
#endif
"""

edit(shared, [
    # Take the aarch64 arm everywhere the target is ARM64EC: hotspot is built
    # for aarch64, so the AMD64 arms reference an x86 Assembler and VM_Version
    # that are not there, even though the context layout is AMD64's.
    ("#if defined(_M_ARM64)\n  #define __CPU__ aarch64\n",
     CTX_MACRO +
     "\n#if defined(_M_ARM64) || defined(__arm64ec__)\n  #define __CPU__ aarch64\n",
     "__CPU__ and the context macro", 1),

    ("#if (defined _M_ARM64)\n  static const uint16_t running_arch = IMAGE_FILE_MACHINE_ARM64;\n",
     "#if (defined _M_ARM64) || (defined __arm64ec__)\n"
     "  static const uint16_t running_arch = IMAGE_FILE_MACHINE_ARM64;\n",
     "running_arch", 1),

    ("#if defined(_M_ARM64)\n  #define PC_NAME Pc\n",
     "#if defined(_M_ARM64) || defined(__arm64ec__)\n  #define PC_NAME Pc\n",
     "PC_NAME", "optional"),

    # 11 lists the ARM64 arm last, after AMD64 and IX86, so it is an #elif there
    ("#elif defined(_M_ARM64)\n  #define PC_NAME Pc\n",
     "#elif defined(_M_ARM64) || defined(__arm64ec__)\n  #define PC_NAME Pc\n",
     "PC_NAME with the ARM64 arm last", "optional"),

    # and with AMD64 leading that chain, ARM64EC would take Rip before ever
    # reaching the arm above, since clang defines _M_AMD64 for it
    ("#if defined(_M_AMD64)\n  #define PC_NAME Rip\n",
     "#if defined(_M_AMD64) && !defined(__arm64ec__)\n  #define PC_NAME Rip\n",
     "PC_NAME with the AMD64 arm leading", "optional"),

    ("  exceptionInfo->ContextRecord->PC_NAME = (DWORD64)handler;",
     "  HS_ARM64_CTX(exceptionInfo->ContextRecord)->PC_NAME = (DWORD64)handler;",
     "PC_NAME assignment", 1),

    # The deopt patch sits outside any arch conditional, so it needs the macro
    # as well. Only releases with the UD deopt trap have it.
    ("          exceptionInfo->ContextRecord->PC_NAME = (DWORD64)deopt;",
     "          HS_ARM64_CTX(exceptionInfo->ContextRecord)->PC_NAME = (DWORD64)deopt;",
     "deopt PC_NAME assignment", "optional"),

    ("#if defined(_M_ARM64)\n"
     "  PCONTEXT ctx = exceptionInfo->ContextRecord;\n"
     "  address pc = (address)ctx->Sp;\n",
     "#if defined(_M_ARM64) || defined(__arm64ec__)\n"
     "  auto ctx = HS_ARM64_CTX(exceptionInfo->ContextRecord);\n"
     "  address pc = (address)ctx->Sp;\n",
     "Handle_IDiv_Exception", 1),

    # The pc in topLevelExceptionFilter and topLevelVectoredExceptionFilter,
    # which spell this identically.
    ("#if defined(_M_ARM64)\n"
     "  address pc = (address) exceptionInfo->ContextRecord->Pc;\n",
     "#if defined(_M_ARM64) || defined(__arm64ec__)\n"
     "  address pc = (address) HS_ARM64_CTX(exceptionInfo->ContextRecord)->Pc;\n",
     "top level filter pc", None),

    ("#ifdef _M_ARM64\n    if (in_java &&\n",
     "#if defined(_M_ARM64) || defined(__arm64ec__)\n    if (in_java &&\n",
     "sigill not_entrant", "optional"),

    # topLevelUnhandledExceptionFilter, whose fallback reads Eip. 17 keeps it at
    # the same indent as the other filters and drops the space after the cast,
    # so that spelling is handled by the alt below instead.
    ("#if defined(_M_ARM64)\n"
     "    address pc = (address) exceptionInfo->ContextRecord->Pc;\n",
     "#if defined(_M_ARM64) || defined(__arm64ec__)\n"
     "    address pc = (address) HS_ARM64_CTX(exceptionInfo->ContextRecord)->Pc;\n",
     "unhandled filter pc", "optional"),

    ("#if defined(_M_ARM64)\n"
     "  address pc = (address)exceptionInfo->ContextRecord->Pc;\n",
     "#if defined(_M_ARM64) || defined(__arm64ec__)\n"
     "  address pc = (address)HS_ARM64_CTX(exceptionInfo->ContextRecord)->Pc;\n",
     "unhandled filter pc, 17 spelling", "optional"),

    # ARM64EC runs on ARM64 hardware, so it has the same 48-bit address space.
    ("#ifdef _M_ARM64\n  // AArch64 has a maximum addressable space of 48-bits\n",
     "#if defined(_M_ARM64) || defined(__arm64ec__)\n"
     "  // AArch64 has a maximum addressable space of 48-bits\n",
     "max addressable space", 1),

    ("#if defined(AMD64) || defined(_M_ARM64)\n"
     "  #define sampling_context_flags (CONTEXT_FULL | CONTEXT_FLOATING_POINT)\n",
     "#if defined(AMD64) || defined(_M_ARM64) || defined(__arm64ec__)\n"
     "  #define sampling_context_flags (CONTEXT_FULL | CONTEXT_FLOATING_POINT)\n",
     "sampling_context_flags", "optional"),

    ("#elif defined(AMD64) || defined(_M_ARM64)\n"
     "  #define sampling_context_flags (CONTEXT_FULL | CONTEXT_FLOATING_POINT)\n",
     "#elif defined(AMD64) || defined(_M_ARM64) || defined(__arm64ec__)\n"
     "  #define sampling_context_flags (CONTEXT_FULL | CONTEXT_FLOATING_POINT)\n",
     "sampling_context_flags (with an IA32 arm ahead of it)", "optional"),
])

# Handle_Exception saves the faulting pc before redirecting, and each release
# reaches the JavaThread differently: 11 casts, 17 calls as_Java_thread(), 21
# replaced that with JavaThread::cast.
alt(shared, [
    ("    JavaThread::cast(thread)->set_saved_exception_pc((address)(DWORD_PTR)exceptionInfo->ContextRecord->PC_NAME);",
     "    JavaThread::cast(thread)->set_saved_exception_pc((address)(DWORD_PTR)HS_ARM64_CTX(exceptionInfo->ContextRecord)->PC_NAME);"),
    ("    thread->as_Java_thread()->set_saved_exception_pc((address)(DWORD_PTR)exceptionInfo->ContextRecord->PC_NAME);",
     "    thread->as_Java_thread()->set_saved_exception_pc((address)(DWORD_PTR)HS_ARM64_CTX(exceptionInfo->ContextRecord)->PC_NAME);"),
    ("    ((JavaThread*)thread)->set_saved_exception_pc((address)(DWORD_PTR)exceptionInfo->ContextRecord->PC_NAME);",
     "    ((JavaThread*)thread)->set_saved_exception_pc((address)(DWORD_PTR)HS_ARM64_CTX(exceptionInfo->ContextRecord)->PC_NAME);"),
], "saved_exception_pc")

# clang defines _M_AMD64 for ARM64EC, so these two blocks, which are not part of
# an #elif chain, would otherwise compile and call into an x86 VM_Version and an
# x86 floating point handler that an aarch64 hotspot does not have. 21 and
# earlier spell both conditions with _M_IX86 alongside.
alt(shared, [
    ("#if defined(_M_AMD64)\n"
     "  if ((exception_code == EXCEPTION_ACCESS_VIOLATION) &&\n"
     "      VM_Version::is_cpuinfo_segv_addr(pc)) {",
     "#if defined(_M_AMD64) && !defined(__arm64ec__)\n"
     "  if ((exception_code == EXCEPTION_ACCESS_VIOLATION) &&\n"
     "      VM_Version::is_cpuinfo_segv_addr(pc)) {"),
    ("#if defined(_M_AMD64) || defined(_M_IX86)\n"
     "  if ((exception_code == EXCEPTION_ACCESS_VIOLATION) &&\n"
     "      VM_Version::is_cpuinfo_segv_addr(pc)) {",
     "#if (defined(_M_AMD64) || defined(_M_IX86)) && !defined(__arm64ec__)\n"
     "  if ((exception_code == EXCEPTION_ACCESS_VIOLATION) &&\n"
     "      VM_Version::is_cpuinfo_segv_addr(pc)) {"),
    # 11 tests the address alone, one indent deeper
    ("#if defined(_M_AMD64) || defined(_M_IX86)\n"
     "    if (VM_Version::is_cpuinfo_segv_addr(pc)) {",
     "#if (defined(_M_AMD64) || defined(_M_IX86)) && !defined(__arm64ec__)\n"
     "    if (VM_Version::is_cpuinfo_segv_addr(pc)) {"),
], "cpuinfo probe block")

alt(shared, [
    ("#if defined(_M_AMD64)\n"
     "    extern bool handle_FLT_exception(struct _EXCEPTION_POINTERS* exceptionInfo);",
     "#if defined(_M_AMD64) && !defined(__arm64ec__)\n"
     "    extern bool handle_FLT_exception(struct _EXCEPTION_POINTERS* exceptionInfo);"),
    ("#if defined(_M_AMD64) || defined(_M_IX86)\n"
     "    if ((in_java || in_native) && handle_FLT_exception(exceptionInfo)) {",
     "#if (defined(_M_AMD64) || defined(_M_IX86)) && !defined(__arm64ec__)\n"
     "    if ((in_java || in_native) && handle_FLT_exception(exceptionInfo)) {"),
], "handle_FLT_exception block", optional=True)  # 17 has no FLT handler

# The os_cpu file reads the ARM64 registers by name throughout, so give it one
# type to work in.
OSCPU_TYPEDEF = """
// See the note on HS_ARM64_CTX in os_windows.cpp: on ARM64EC the CONTEXT
// windows delivers is the AMD64 one, and ARM64EC_NT_CONTEXT is the same bytes
// under the ARM64 register names.
#if defined(__arm64ec__)
typedef ARM64EC_NT_CONTEXT HotSpotContext;
#else
typedef CONTEXT HotSpotContext;
#endif
"""

edit(oscpu, [
    ("void os::os_exception_wrapper(java_call_t f,",
     OSCPU_TYPEDEF + "\nvoid os::os_exception_wrapper(java_call_t f,",
     "HotSpotContext typedef", 1),
    # 21 predates fetch_bcp_from_context, so it has one cast where 25 has two.
    ("  CONTEXT* uc = (CONTEXT*)ucVoid;", "  HotSpotContext* uc = (HotSpotContext*)ucVoid;",
     "uc casts", None),
    ("static bool is_interpreter(const CONTEXT* uc) {",
     "static bool is_interpreter(const HotSpotContext* uc) {", "is_interpreter", "optional"),
    ("  const CONTEXT* uc = (const CONTEXT*)context;",
     "  const HotSpotContext* uc = (const HotSpotContext*)context;", "const uc casts", None),
    ("      intptr_t* fp = (intptr_t*)exceptionInfo->ContextRecord->Fp;\n"
     "      intptr_t* sp = (intptr_t*)exceptionInfo->ContextRecord->Sp;\n"
     "      address pc = (address)(exceptionInfo->ContextRecord->Lr",
     "      HotSpotContext* ctx = (HotSpotContext*)exceptionInfo->ContextRecord;\n"
     "      intptr_t* fp = (intptr_t*)ctx->Fp;\n"
     "      intptr_t* sp = (intptr_t*)ctx->Sp;\n"
     "      address pc = (address)(ctx->Lr",
     "stack banging registers", 1),

    # ARM64EC only maps the ARM64 registers that have an AMD64 slot to live in,
    # so x13, x14, x16 to x18, x23, x24 and x28 are simply not in the context
    # windows hands over. Print what there is rather than inventing values.
    ('  st->print_cr("Registers:");\n'
     '\n'
     '  st->print(  "X0 =" INTPTR_FORMAT, uc->X0);',
     '  st->print_cr("Registers:");\n'
     '\n'
     '#ifdef __arm64ec__\n'
     '  // ARM64EC carries only the registers with an AMD64 slot: x13, x14,\n'
     '  // x16 to x18, x23, x24 and x28 are not preserved across the boundary\n'
     '  // and windows does not report them.\n'
     '  const struct { const char* name; DWORD64 value; } ec_regs[] = {\n'
     '    {"X0", uc->X0},   {"X1", uc->X1},   {"X2", uc->X2},   {"X3", uc->X3},\n'
     '    {"X4", uc->X4},   {"X5", uc->X5},   {"X6", uc->X6},   {"X7", uc->X7},\n'
     '    {"X8", uc->X8},   {"X9", uc->X9},   {"X10", uc->X10}, {"X11", uc->X11},\n'
     '    {"X12", uc->X12}, {"X15", uc->X15}, {"X19", uc->X19}, {"X20", uc->X20},\n'
     '    {"X21", uc->X21}, {"X22", uc->X22}, {"X25", uc->X25}, {"X26", uc->X26},\n'
     '    {"X27", uc->X27}, {"FP", uc->Fp},   {"LR", uc->Lr},   {"SP", uc->Sp},\n'
     '  };\n'
     '  for (size_t i = 0; i < sizeof(ec_regs) / sizeof(ec_regs[0]); i++) {\n'
     '    st->print("%-4s=" INTPTR_FORMAT, ec_regs[i].name, ec_regs[i].value);\n'
     '    if ((i % 4) == 3) { st->cr(); } else { st->print(", "); }\n'
     '  }\n'
     '  st->cr();\n'
     '#else\n'
     '  st->print(  "X0 =" INTPTR_FORMAT, uc->X0);',
     "print_context EC branch", 1),

])

# Closing the EC branch: 17 and later end print_context right after the
# registers, while 11 goes on to dump the stack top in the same function.
alt(oscpu, [
    ('  st->print(", X28=" INTPTR_FORMAT, uc->X28);\n'
     '  st->cr();\n'
     '  st->cr();\n'
     '}',
     '  st->print(", X28=" INTPTR_FORMAT, uc->X28);\n'
     '  st->cr();\n'
     '#endif\n'
     '  st->cr();\n'
     '}'),
    ('  st->print(", X28=" INTPTR_FORMAT, uc->X28);\n'
     '  st->cr();\n'
     '  st->cr();\n',
     '  st->print(", X28=" INTPTR_FORMAT, uc->X28);\n'
     '  st->cr();\n'
     '#endif\n'
     '  st->cr();\n'),
], "print_context EC branch close")

# print_register_info walks X0 to X28 by index; leave a gap where ARM64EC has
# no register. A missing case prints nothing and the walk still advances.
missing = (13, 14, 16, 17, 18, 23, 24, 28)
s = io.open(oscpu, encoding='utf-8', newline='').read()
for r in missing:
    # 21 and 25 walk the registers by index through CASE_PRINT_REG; 17 predates
    # that and prints them as a flat sequence.
    forms = ['      CASE_PRINT_REG(%2d, "X%d=", X%d); break;\n' % (r, r, r),
             '      CASE_PRINT_REG(%2d, " X%d=", X%d); break;\n' % (r, r, r),
             '  st->print("X%d="); print_location(st, uc->X%d);\n' % (r, r),
             '  st->print(" X%d="); print_location(st, uc->X%d);\n' % (r, r)]
    for old in forms:
        if s.count(old) == 1:
            s = s.replace(old, '#ifndef __arm64ec__\n' + old + '#endif\n', 1)
            break
    else:
        raise SystemExit("os_windows_aarch64.cpp: no single register print for X%d" % r)
io.open(oscpu, 'w', encoding='utf-8', newline='').write(s)

print("arm64ec: shared and os_cpu context handling applied")
PYEOF
        log "Reading the ARM64EC context as ARM64 and taking the aarch64 arms"
        ;;
    esac

    # The Serviceability Agent's windbg back end handles x86_64 and ARM64 only:
    #   sawindbg.cpp:40: error: "SA windbg back-end is not supported for your cpu!"
    # configure already drops SA for zero, aix and s390x, so say so for 32-bit
    # ARM on windows the same way rather than porting that back end. The
    # condition tests the target, so it is inert for every other windows triple.
    JDKOPT="$SRC/make/autoconf/jdk-options.m4"
    if [ -f "$JDKOPT" ] && ! grep -q 'OPENJDK_TARGET_CPU" = xarm ; then' "$JDKOPT"; then
      python3 - "$JDKOPT" <<'PYEOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8', newline='').read()
old = '  if test "x$OPENJDK_TARGET_CPU" = xs390x ; then\n    INCLUDE_SA=false\n  fi\n'
new = old + ('  if test "x$OPENJDK_TARGET_OS" = xwindows && test "x$OPENJDK_TARGET_CPU" = xarm ; then\n'
             '    INCLUDE_SA=false\n  fi\n')
if s.count(old) != 1:
    raise SystemExit("jdk-options.m4: the s390x INCLUDE_SA block matched %d times, expected 1" % s.count(old))
io.open(p, 'w', encoding='utf-8', newline='').write(s.replace(old, new, 1))
PYEOF
      log "Leaving the serviceability agent out for 32-bit ARM on windows"
    fi

    # sharedRuntimeRem.cpp defines SharedRuntime::fmod_winx64, which
    # sharedRuntime.hpp declares only under _WIN64, while the file itself is
    # compiled for every windows target:
    #   sharedRuntimeRem.cpp:40: out-of-line definition of 'fmod_winx64'
    #   does not match any declaration in 'SharedRuntime'
    # The guard is right: it is a workaround for the windows x64 CRT's fmod, so
    # give the definition the same one. A no-op on the 64-bit targets.
    SRR="$SRC/src/hotspot/os/windows/sharedRuntimeRem.cpp"
    if [ -f "$SRR" ] && ! grep -q '^#ifdef _WIN64$' "$SRR"; then
      sed -i 's|^#include "runtime/sharedRuntime.hpp"$|#include "runtime/sharedRuntime.hpp"\n\n#ifdef _WIN64|' "$SRR"
      printf '#endif // _WIN64\n' >> "$SRR"
      if [ "$(grep -c '^#ifdef _WIN64$' "$SRR")" != 1 ] || [ "$(grep -c '^#endif // _WIN64$' "$SRR")" != 1 ]; then
        echo "failed to guard fmod_winx64 on _WIN64" >&2; exit 1
      fi
      log "Guarding fmod_winx64 the way its declaration is guarded"
    fi

    # NMT's mapping printer declares its classes for LINUX, _WIN64 or APPLE,
    # while memMapPrinter_windows.cpp implementing them is compiled for every
    # windows target, so on a 32-bit one the class is not declared at all:
    #   memMapPrinter_windows.cpp:148: unknown type name 'MappingPrintSession'
    # _WIN64 stands in for "windows" in both files. The implementation only
    # calls VirtualQuery and psapi, which 32-bit windows has, and its one
    # width-sensitive line already casts through unsigned long long.
    mmp_done=""
    for f in "$SRC/src/hotspot/share/nmt/memMapPrinter.hpp" \
             "$SRC/src/hotspot/share/nmt/memMapPrinter.cpp"; do
      [ -f "$f" ] || continue
      grep -q 'defined(_WIN64)' "$f" || continue
      sed -i 's/defined(_WIN64)/defined(_WIN32)/g' "$f"
      if grep -q 'defined(_WIN64)' "$f"; then
        echo "failed to widen the NMT map printer guard in $f" >&2; exit 1
      fi
      mmp_done=yes
    done
    if [ -n "$mmp_done" ]; then
      log "Declaring NMT's mapping printer for 32-bit windows too"
    fi

    # adlc emits a check into its generated sources for every -D it was given,
    # so they fail to compile unless the same defines are set. 25 hands it
    # -D_WIN64=1 for any windows target, taking windows to mean 64-bit:
    #   ad_arm.cpp:17621: error: "_WIN64 must be defined"
    # This restores the gate 11, 17 and 21 all still have; 25 dropped it when
    # JEP 503 made 64-bit the only windows it had left. Those releases keep
    # theirs at a different indentation, so this matches only the ungated line.
    ADLC_GMK="$SRC/make/hotspot/gensrc/GensrcAdlc.gmk"
    if [ -f "$ADLC_GMK" ] && grep -qx '    ADLCFLAGS += -D_WIN64=1' "$ADLC_GMK"; then
      awk '
        $0 == "    ADLCFLAGS += -D_WIN64=1" {
          print "    ifeq ($(call isTargetCpuBits, 64), true)"
          print "      ADLCFLAGS += -D_WIN64=1"
          print "    endif"
          next
        }
        { print }
      ' "$ADLC_GMK" > "$ADLC_GMK.tmp" && mv "$ADLC_GMK.tmp" "$ADLC_GMK"
      grep -qx '      ADLCFLAGS += -D_WIN64=1' "$ADLC_GMK" || {
        echo "failed to gate -D_WIN64 on the target being 64-bit" >&2; exit 1; }
      log "Defining _WIN64 for adlc only on 64-bit windows targets"
    fi

    # windef.h still defines the 16-bit memory-model keywords, so "far" expands
    # to nothing and adlc's generated ad_arm.cpp gets "bool  = ...":
    #   ad_arm.cpp:89: error: expected unqualified-id
    # Three locals in arm_32.ad are named far. Renaming them is smaller than
    # undefining a macro windows headers expect to own. arm.ad has none.
    ARMAD="$SRC/src/hotspot/cpu/arm/arm_32.ad"
    if [ -f "$ARMAD" ] && grep -q 'bool far = ' "$ARMAD"; then
      sed -i -e 's/bool far = /bool is_far = /g' \
             -e 's/(far ? 3 : 1)/(is_far ? 3 : 1)/g' "$ARMAD"
      if grep -qE '\bfar\b' <(grep -vE 'maybe_far_call|far_call' "$ARMAD"); then
        echo "arm_32.ad still names a local far after the rename" >&2; exit 1
      fi
      log "Renaming arm_32.ad's far locals, which windef.h defines away"
    fi

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
    # 8 ships a NativeCompilation.gmk of its own that predates the toolchain
    # abstraction and has no $1_EXTRA_FILES line to anchor on, so require the
    # anchor and leave that release to fail on its own terms instead of here.
    NCG="$SRC/make/common/NativeCompilation.gmk"
    if [ -f "$NCG" ] && ! grep -q 'INFERRED_LINK_TYPE' "$NCG" \
       && ! grep -q 'SetupSourceFiles' "$NCG" \
       && grep -qF '$1_SRCS += $$($1_EXTRA_FILES)' "$NCG"; then
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
    # The other spelling, for the releases that call SetupSourceFiles. 8 has
    # neither anchor, so it takes neither branch.
    if [ -f "$NCG" ] && ! grep -q 'INFERRED_LINK_TYPE' "$NCG" \
       && grep -qF '$$(eval $$(call SetupSourceFiles,$1))' "$NCG"; then
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

    # AccessBridgeStatusWindow is spelled .RC on disk, .rc by the three library
    # makefiles and .RC again by the launcher one, which only resolves on a
    # case-insensitive filesystem:
    #   No rule to make target '.../common/AccessBridgeStatusWindow.rc'
    # Renaming the file alone just moves the failure to the launcher, so settle
    # every reference on the lowercase name the other two .rc files already use.
    ABRC="$SRC/src/jdk.accessibility/windows/native/common/AccessBridgeStatusWindow"
    if [ -f "$ABRC.RC" ] && [ ! -f "$ABRC.rc" ]; then
      mv "$ABRC.RC" "$ABRC.rc"
      grep -rl 'AccessBridgeStatusWindow\.RC' --include='*.gmk' "$SRC/make" 2>/dev/null \
        | xargs -r sed -i 's/AccessBridgeStatusWindow\.RC/AccessBridgeStatusWindow.rc/g'
      if grep -rq 'AccessBridgeStatusWindow\.RC' --include='*.gmk' "$SRC/make" 2>/dev/null; then
        echo "failed to settle AccessBridgeStatusWindow on one spelling" >&2; exit 1
      fi
      log "Renamed AccessBridgeStatusWindow.RC and its makefile references"
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
    # Both lines have to be there before the line numbers are compared: 21 and 25
    # keep the constant but check printDC explicitly instead of through the
    # macro, so the second grep comes back empty and the comparison would be
    # "[: : integer expression expected".
    if [ -f "$PJ" ] && grep -qxF "$pj_eps" "$PJ" && grep -qxF "$pj_goto" "$PJ" &&
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

    fix_globaldefinitions_gcc "$SRC/src/hotspot/share/utilities/globalDefinitions_gcc.hpp"

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
fi

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

  # ARM64EC is x64-ABI-compatible, so clang defines _M_X64 for it. miniaudio
  # reads that as an x86 CPU and emits cpuid and xgetbv, which an ARM64 backend
  # has no encoding for:
  #   miniaudio.h:11758: error: invalid output constraint '=a' in asm
  # The ARM64 test sits in the elif below it and is never reached. Both edits
  # mention __arm64ec__, so they change nothing for any other target.
  local ma="$dest/miniaudio.h"
  if grep -q '^#if defined(__x86_64__) || defined(_M_X64)$' "$ma"; then
    # Three tests, because ma_yield decides the architecture again on its own
    # and would emit "rep; nop". The pointer-size test at the top of the file
    # reads _M_X64 too, but 8 is right for this target, so it stays.
    sed -i \
      -e 's@^#if defined(__arm64) || defined(__arm64__) || defined(__aarch64__) || defined(_M_ARM64)$@#if defined(__arm64) || defined(__arm64__) || defined(__aarch64__) || defined(_M_ARM64) || defined(__arm64ec__)@' \
      -e 's@^#if defined(__x86_64__) || defined(_M_X64)$@#if (defined(__x86_64__) || defined(_M_X64)) \&\& !defined(__arm64ec__)@' \
      -e 's@^#if defined(__i386) || defined(_M_IX86) || defined(__x86_64__) || defined(_M_X64)$@#if (defined(__i386) || defined(_M_IX86) || defined(__x86_64__) || defined(_M_X64)) \&\& !defined(__arm64ec__)@' \
      -e 's@^#elif (defined(__arm__) \&\& defined(__ARM_ARCH) \&\& __ARM_ARCH >= 7) || defined(_M_ARM64)@#elif defined(__arm64ec__) || (defined(__arm__) \&\& defined(__ARM_ARCH) \&\& __ARM_ARCH >= 7) || defined(_M_ARM64)@' \
      "$ma"
    for want in '^#if (defined(__x86_64__) || defined(_M_X64)) && !defined(__arm64ec__)$' \
                '^#if (defined(__i386) || defined(_M_IX86) || defined(__x86_64__) || defined(_M_X64)) && !defined(__arm64ec__)$' \
                '^#elif defined(__arm64ec__) || (defined(__arm__)'; do
      grep -q "$want" "$ma" || {
        echo "failed to keep miniaudio's x86 intrinsics away from arm64ec" >&2; exit 1; }
    done
    log "Detecting arm64ec as ARM64 in miniaudio, not x64"
  fi
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

# No state file is written: build.sh / make-jdk.sh recompute the same SRC and
# BOOT_JDK paths from $ROOTDIR, and take JDK_VERSION straight from the env (the
# same vars CI / `docker run` already pass), so the three scripts stay decoupled.
log "Source ready at $SRC (boot JDK: $BOOT_JDK)"

# --- android: source fixes ---------------------------------------------------
if [ "${PLATFORM:-}" = android ]; then
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

# --- a config.sub that knows android ----------------------------------------
# 8, 11 and 17 ship an autoconf-config.sub from 2008, which predates android and
# rejects every triple built here, configure stops at "checking host system
# type" with "Invalid configuration `x86_64-linux-android': system `android' not
# recognized". 21 and 25 carry a 2022 copy that resolves all of them. Swap the
# stale file for that same known-good one, and only when the tree's own copy
# cannot parse this target, so a release that refreshes it is left alone.
CONFIG_SUB_DIR="$SRC/make/autoconf/build-aux"
[ -d "$CONFIG_SUB_DIR" ] || CONFIG_SUB_DIR="$SRC/common/autoconf/build-aux"
if [ -n "$CONF_TRIPLE" ] && [ -f "$CONFIG_SUB_DIR/config.sub" ] \
   && ! bash "$CONFIG_SUB_DIR/config.sub" "$CONF_TRIPLE" >/dev/null 2>&1; then
  log "Refreshing config.sub (the bundled one predates android)"
  CONFIG_SUB_CACHE="$BUILD_DIR/autoconf-config.sub"
  if [ ! -f "$CONFIG_SUB_CACHE" ]; then
    mkdir -p "$BUILD_DIR"
    fetch --dir="$BUILD_DIR" -o autoconf-config.sub "$CONFIG_SUB_URL"
  fi
  cp "$CONFIG_SUB_CACHE" "$CONFIG_SUB_DIR/autoconf-config.sub"
  bash "$CONFIG_SUB_DIR/config.sub" "$CONF_TRIPLE" >/dev/null 2>&1 || {
    echo "refreshed config.sub still cannot parse '$CONF_TRIPLE'" >&2; exit 1; }
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

# --- jdk8 windows: target-OS decisions that are really build-OS or toolchain -
# Both edits are the pattern this port keeps meeting: a choice keyed on the
# target OS whose real dependency is the machine configure runs on, or the
# toolchain in use. 8 ships a checked-in generated-configure.sh alongside the
# .m4 sources, and only the generated one runs (autogen.sh reruns only when hg
# reports the .m4 dirty, which never happens in this git tree), so patch both.
if [ "${PLATFORM:-}" = windows ] && [ "$JDK_VERSION" = 8 ]; then
  AC8="$SRC/common/autoconf"
  python3 - "$AC8" <<'PY'
import re, sys

ac = sys.argv[1]

# BASIC_SETUP_PATHS picks the PATH separator and goes looking for cygwin or msys
# based on the target OS, so cross-compiling to windows from linux it demands a
# windows shell on the build host and stops:
#   configure: error: Unknown Windows environment. Neither cygwin nor msys was
#   detected.
# Everything in that branch describes the machine configure runs on, so key it
# on OPENJDK_BUILD_OS, which is what 9 and later settled on.
path_sep = (
    ["basics.m4", "generated-configure.sh"],
    re.compile(r'( *)if test "x\$OPENJDK_TARGET_OS" = "xwindows"; then\n( *)PATH_SEP=";"'),
    re.compile(r'if test "x\$OPENJDK_BUILD_OS" = "xwindows"; then\n *PATH_SEP=";"'),
    lambda m: (f'{m.group(1)}if test "x$OPENJDK_BUILD_OS" = "xwindows"; then'
               f'\n{m.group(2)}PATH_SEP=";"'),
    "the PATH separator and windows-shell hunt",
)

# LIB_SETUP_ON_WINDOWS hunts for the Visual Studio runtime DLLs to bundle into
# the image on any windows target, though they are a microsoft-toolchain
# artifact. MSVCR_NAME is only set by the VS detection that never ran, so the
# name comes out blank:
#   configure: error: Could not find . Please specify using --with-msvcr-dll.
# mingw links the system msvcrt and carries its own runtime, which -static folds
# in, so there is nothing to find or ship.
msvcr = (
    ["libraries.m4", "generated-configure.sh"],
    re.compile(r'if test "x\$OPENJDK_TARGET_OS" = "xwindows"; then'
               r'(\n\s*TOOLCHAIN_SETUP_VS_RUNTIME_DLLS'
               r'|\n+# Check whether --with-msvcr-dll was given\.)'),
    re.compile(r'if test "x\$OPENJDK_TARGET_OS" = "xwindows" && '
               r'test "x\$TOOLCHAIN_TYPE" = "xmicrosoft"; then'),
    lambda m: ('if test "x$OPENJDK_TARGET_OS" = "xwindows" && '
               'test "x$TOOLCHAIN_TYPE" = "xmicrosoft"; then' + m.group(1)),
    "the Visual Studio runtime DLL lookup",
)

# spec.gmk.in replaces PATH wholesale with the Visual Studio tools directory on
# any windows target, as its own comment says it does for the VS toolchain. With
# clang that substitution is empty, so make runs with no PATH at all and the
# first recipe dies:
#   /bin/sh: 1: git: not found
#   logger.sh: line 40: mktemp: No such file or directory
# TOOLCHAIN_TYPE is not assigned until much further down the file, so test the
# substitution itself rather than the make variable.
vs_path = (
    ["spec.gmk.in"],
    re.compile(r'ifeq \(\$\(OPENJDK_TARGET_OS\), windows\)\n'
               r'(  # On Windows, the Visual Studio toolchain needs)'),
    re.compile(r'ifeq \(\$\(OPENJDK_TARGET_OS\)-@TOOLCHAIN_TYPE@, windows-microsoft\)'),
    lambda m: ('ifeq ($(OPENJDK_TARGET_OS)-@TOOLCHAIN_TYPE@, windows-microsoft)\n'
               + m.group(1)),
    "the wholesale PATH replacement",
)


# The gcc/clang branch adds -Wl,-z,relro for every target but macosx, and the
# generated script covers clang where the .m4 still says gcc only. It lands in
# LEGACY_TARGET_LDFLAGS, which is hotspot's EXTRA_LDFLAGS, and lld rejects it
# on a PE target:
#   lld: error: unknown argument: -z
# Read-only relocations are an ELF idea; exclude windows the way macosx is.
relro = (
    ["flags.m4", "generated-configure.sh"],
    re.compile(r'if test "x\$OPENJDK_TARGET_OS" != xmacosx; then\n'
               r'(\s*LDFLAGS_JDK="\$LDFLAGS_JDK -Wl,-z,relro")'),
    re.compile(r'if test "x\$OPENJDK_TARGET_OS" != xmacosx && '
               r'test "x\$OPENJDK_TARGET_OS" != xwindows; then'),
    lambda m: ('if test "x$OPENJDK_TARGET_OS" != xmacosx && '
               'test "x$OPENJDK_TARGET_OS" != xwindows; then\n' + m.group(1)),
    "the relro link flag",
)

for files, old, done, repl, what in (path_sep, msvcr, vs_path, relro):
    for name in files:
        p = f"{ac}/{name}"
        s = open(p, encoding='utf-8', errors='surrogateescape').read()
        if done.search(s):
            print(f"{name}: {what} already fixed")
            continue
        s, n = old.subn(repl, s)
        if n != 1:
            sys.exit(f"{name}: {what} matched {n} times, expected 1")
        open(p, 'w', encoding='utf-8', errors='surrogateescape', newline='').write(s)
        print(f"{name}: fixed {what}")
PY
  # Keep the generated script newer than the .m4 it came from, so the staleness
  # check in configure stays quiet on a host that does have hg.
  touch "$AC8/generated-configure.sh"
fi

# --- jdk8 windows: a GNU-make hotspot build for the windows sources ---------
# hotspot 8 builds for windows only through make/windows, which is nmake driven
# by build.bat and needs Visual Studio. Its GNU-make build lives under
# make/linux and is generic apart from a handful of linux assumptions, so this
# points that machinery at the windows sources instead of writing a second
# build system. OSNAME stays linux (it comes from uname on the build host, and
# it is what selects the makefiles); only the platform file, which is what
# selects sources and target defines, becomes windows.
# 8's hotspot has os_cpu/windows_x86 and nothing else: no cpu/arm at all, and
# no windows_aarch64. x86_64 is the only triple this can serve.
if [ "${PLATFORM:-}" = windows ] && [ "$JDK_VERSION" = 8 ] && [ "${TARGET%%-*}" = x86_64 ]; then
  # 8's copy of the header is the same shape as 21's, so the same edits apply.
  fix_globaldefinitions_gcc "$SRC/hotspot/src/share/vm/utilities/globalDefinitions_gcc.hpp"
  # One difference: the branch mingw now shares with linux calls isnanf for the
  # float overload, which is a glibc extension mingw does not have:
  #   globalDefinitions_gcc.hpp:259: error: use of undeclared identifier 'isnanf'
  # isnan is overloaded for float in C++, and is what the later releases settled
  # on here. Address the line under that branch rather than the text, which
  # appears again under SOLARIS.
  GD8="$SRC/hotspot/src/share/vm/utilities/globalDefinitions_gcc.hpp"
  gd_elif=$(grep -n '^#elif defined(LINUX).*__MINGW32__)$' "$GD8" | head -n1 | cut -d: -f1)
  [ -n "$gd_elif" ] || { echo "no mingw g_isnan branch in $GD8" >&2; exit 1; }
  if sed -n "$((gd_elif + 1))p" "$GD8" | grep -q 'isnanf'; then
    sed -i "$((gd_elif + 1))s/isnanf/isnan/" "$GD8"
    sed -n "$((gd_elif + 1))p" "$GD8" | grep -q 'return isnan(f)' || {
      echo "failed to replace isnanf in the mingw g_isnan branch" >&2; exit 1; }
    log "Using isnan rather than glibc's isnanf on mingw"
  fi

  # os/windows and os_cpu/windows_x86 were written for Visual Studio and test
  # _MSC_VER without asking whether it is defined. Under clang it is not, so
  # every such test reads 0 and takes the oldest branch: jvm_windows.h hand-rolls
  # MODULEINFO instead of including <Psapi.h>, and os_windows.hpp turns on
  # JDK6_OR_EARLIER, a VS2008-and-older path. Ask for the macro first, which
  # leaves a real Visual Studio build on exactly the branch it had.
  msc_fixed=0
  for f in "$SRC/hotspot/src/os/windows/vm/"*.hpp "$SRC/hotspot/src/os/windows/vm/"*.h \
           "$SRC/hotspot/src/os/windows/vm/"*.cpp \
           "$SRC/hotspot/src/os_cpu/windows_x86/vm/"*.hpp \
           "$SRC/hotspot/src/os_cpu/windows_x86/vm/"*.cpp; do
    [ -f "$f" ] || continue
    grep -qE '^#if _MSC_VER' "$f" || continue
    perl -pi -e 's/^#if _MSC_VER /#if defined(_MSC_VER) \&\& _MSC_VER /' "$f"
    msc_fixed=$((msc_fixed + 1))
  done
  [ "$msc_fixed" -gt 0 ] || grep -rqE '^#if defined\(_MSC_VER\) && _MSC_VER ' \
    "$SRC/hotspot/src/os/windows/vm" || {
      echo "no bare _MSC_VER version tests found in hotspot's windows sources" >&2; exit 1; }
  [ "$msc_fixed" -gt 0 ] && log "Guarding $msc_fixed windows source files against an undefined _MSC_VER"

  # hotspot's windows sources lean on what <windows.h> pulls in by default, and
  # this build passes WIN32_LEAN_AND_MEAN, which is exactly what suppresses the
  # extra headers. Two groups are missing: winsock, for the LPWSADATA in
  # os_windows.hpp's WinSock2Dll, and the multimedia timers os_windows.cpp calls.
  #   os_windows.hpp:174: error: unknown type name 'LPWSADATA'
  #   os_windows.cpp:131: error: use of undeclared identifier 'timeBeginPeriod'
  # Add them where the rest of the windows include chain starts.
  JVMW="$SRC/hotspot/src/os/windows/vm/jvm_windows.h"
  if ! grep -q '^#include <winsock2.h>$' "$JVMW"; then
    perl -pi -e 's/^#include <windows\.h>$/#include <windows.h>\n\/\/ WIN32_LEAN_AND_MEAN keeps windows.h from reaching these; hotspot needs both.\n#include <winsock2.h>\n#include <mmsystem.h>/' "$JVMW"
    grep -q '^#include <mmsystem.h>$' "$JVMW" || {
      echo "failed to add the winsock and mmsystem includes to jvm_windows.h" >&2; exit 1; }
    log "Including <winsock2.h> and <mmsystem.h> for hotspot's windows sources"
  fi

  HSL="$SRC/hotspot/make/linux"
  python3 - "$HSL" <<'PY'
import re, sys

hsl = sys.argv[1]

# The platform file is the whole of hotspot's port selection: os_family picks
# src/os/<os>/vm and the TARGET_OS_FAMILY_<os> define, os_arch picks
# src/os_cpu/<os>_<cpu>/vm, and sysdefs is what the shared code tests for.
# _WINDOWS is the one the sources actually spell; mingw supplies WIN32/_WIN64.
# _JNI_IMPLEMENTATION_ is what the nmake build passes so jni.h exports rather
# than imports; without it JNIEXPORT is dllimport and every JNI entry point in
# jni.cpp is "dllimport cannot be applied to non-inline function definition".
platform = """os_family = windows

arch = x86

arch_model = x86_64

os_arch = windows_x86

os_arch_model = windows_x86_64

lib_arch = amd64

compiler = gcc

sysdefs = -DWINDOWS -D_WINDOWS -DAMD64 -D_JNI_IMPLEMENTATION_
"""

edits = [
    # vm.make derives the makefiles directory from os_family, which would now
    # send it into the nmake tree. The build machinery stays the linux one.
    ("makefiles/vm.make",
     "MAKEFILES_DIR=$(GAMMADIR)/make/$(Platform_os_family)/makefiles",
     "MAKEFILES_DIR=$(GAMMADIR)/make/linux/makefiles",
     "the makefiles directory"),
    ("makefiles/top.make",
     "$(GAMMADIR)/make/$(Platform_os_family)/makefiles/adjust-mflags.sh",
     "$(GAMMADIR)/make/linux/makefiles/adjust-mflags.sh",
     "the adjust-mflags path"),
    # adlc.make reaches for the same two shared files. Its own OS variable stays
    # windows: that one names the .ad file to read, windows_x86_64.ad, which is
    # a source file and really is per target.
    ("makefiles/adlc.make",
     "include $(GAMMADIR)/make/$(Platform_os_family)/makefiles/rules.make",
     "include $(GAMMADIR)/make/linux/makefiles/rules.make",
     "the adlc rules include"),
    ("makefiles/adlc.make",
     "ADLC_UPDATER_DIRECTORY = $(GAMMADIR)/make/$(OS)",
     "ADLC_UPDATER_DIRECTORY = $(GAMMADIR)/make/linux",
     "the adlc_updater directory"),
    # adlc itself runs on the build host, but is compiled with the target's
    # sysdefs, so on a windows target adlc.hpp takes a branch that defines
    # intptr_t only under _WIN32 and skips <inttypes.h>, which is spelled
    # "#if defined(LINUX)". The host is always linux here:
    #   adlc/archDesc.cpp:548: error: unknown type name 'intptr_t'
    # ADLCFLAGS keeps the target defines, which is right: those describe the
    # machine being generated for and end up in the generated source.
    ("makefiles/adlc.make",
     "CXXFLAGS = $(SYSDEFS) $(INCLUDES)",
     "CXXFLAGS = $(filter-out -DWINDOWS -D_WINDOWS,$(SYSDEFS)) -DLINUX $(INCLUDES)",
     "the adlc host defines"),
    # buildtree.make writes the source and include directory lists, and builds
    # them from OS_FAMILY, which is the build host's. vm.make's own SOURCE_PATHS
    # were corrected above, but these were still linux, so the compile ran with
    # os/linux/vm on -I and could not find hotspot's own header:
    #   prims/jvm.h:36: fatal error: 'jvm_windows.h' file not found
    # Both lists carry the same six lines. OS_FAMILY stays the build host's
    # everywhere else in this file, where it selects makefiles.
    ("makefiles/buildtree.make",
     '\techo "$(call gamma-path,altsrc,os_cpu/$(OS_FAMILY)_$(SRCARCH)/vm) \\\\"; \\\n\techo "$(call gamma-path,commonsrc,os_cpu/$(OS_FAMILY)_$(SRCARCH)/vm) \\\\"; \\\n\techo "$(call gamma-path,altsrc,os/$(OS_FAMILY)/vm) \\\\"; \\\n\techo "$(call gamma-path,commonsrc,os/$(OS_FAMILY)/vm) \\\\"; \\\n\techo "$(call gamma-path,altsrc,os/posix/vm) \\\\"; \\\n\techo "$(call gamma-path,commonsrc,os/posix/vm)"; \\',
     '\techo "$(call gamma-path,altsrc,os_cpu/windows_$(SRCARCH)/vm) \\\\"; \\\n\techo "$(call gamma-path,commonsrc,os_cpu/windows_$(SRCARCH)/vm) \\\\"; \\\n\techo "$(call gamma-path,altsrc,os/windows/vm) \\\\"; \\\n\techo "$(call gamma-path,commonsrc,os/windows/vm)"; \\',
     "the source and include directories", 2),
    # os/posix is added unconditionally, being true of every OS the GNU-make
    # build served. windows is the exception.
    ("makefiles/vm.make",
     "SOURCE_PATHS+=$(HS_COMMON_SRC)/os/posix/vm\n",
     "",
     "the posix source path"),
    # The unix runtime libraries, replaced by what os/windows/vm calls into.
    ("makefiles/vm.make",
     "LIBS += -lm -ldl -lpthread",
     "LIBS += -lkernel32 -ladvapi32 -luser32 -lws2_32 -lpsapi -lversion -lwinmm",
     "the runtime libraries"),
    ("makefiles/vm.make",
     "LIBJVM   = lib$(JVM).so",
     "LIBJVM   = $(JVM).dll",
     "the VM library name"),
    # ELF-only link options: a non-executable stack segment, the symbol version
    # script, and the soname. PE has no equivalent of any of the three.
    ("makefiles/vm.make",
     "LFLAGS += -Xlinker -z -Xlinker noexecstack\n",
     "LDNOMAP = true\n",
     "the ELF stack marking"),
    ("makefiles/gcc.make",
     "SONAMEFLAG = -Xlinker -soname=SONAME",
     "SONAMEFLAG =",
     "the soname flag"),
    # Every PE image is relocatable and clang rejects -fPIC for the target.
    ("makefiles/gcc.make",
     "PICFLAG = -fPIC",
     "PICFLAG =",
     "the PIC flag"),
    # The VM is not the only thing the linux build makes: libjsig chains signal
    # handlers, libjvm_db is dtrace, and libsaproc is the serviceability agent.
    # None has a windows counterpart, and jsig is the one that stops the build:
    #   No rule to make target 'src/os/windows/vm/jsig.c', needed by 'libjsig.so'
    ("makefiles/vm.make",
     "build: $(LIBJVM) $(LAUNCHER) $(LIBJSIG) $(LIBJVM_DB) $(BUILDLIBSAPROC) dtraceCheck",
     "build: $(LIBJVM) $(LAUNCHER)",
     "the unix companion libraries"),
    ("makefiles/vm.make",
     "install: install_jvm install_jsig install_saproc",
     "install: install_jvm",
     "the companion library install"),
    # More ELF-only link options, which lld rejects outright on a PE target:
    #   lld: error: unknown argument: --hash-style=both
    #   lld: error: unknown argument: -z
    # The link recipe is a brace group joined by semicolons, so it reports the
    # failure and carries on; the missing jvm.dll only surfaces at export time.
    ("makefiles/gcc.make",
     "LFLAGS += $(LDFLAGS_HASH_STYLE)",
     "# ELF symbol hash tables: nothing to choose on PE.",
     "the hash-style flag"),
    ("makefiles/gcc.make",
     'LDFLAGS_NO_EXEC_STACK="-Wl,-z,noexecstack"',
     "LDFLAGS_NO_EXEC_STACK=",
     "the noexecstack flag"),
    # llvm-mingw carries libc++, not libstdc++, so the explicit -lstdc++ finds
    # nothing. Link the VM with the C++ driver and let it name its own runtime,
    # which --with-extra-ldflags=-static then folds into the image.
    ("makefiles/gcc.make",
     "STATIC_STDCXX = -Wl,-Bstatic -lstdc++ -Wl,-Bdynamic",
     "STATIC_STDCXX =",
     "the static libstdc++"),
    ("makefiles/vm.make",
     "LINK_VM = $(LINK_LIB.CC)",
     "LINK_VM = $(LINK_LIB.CXX)",
     "the VM link driver"),
    # The export list is what the JDK side collects, and it is still spelled for
    # linux: a .so suffix, the lib prefix windows does not use, and libjsig,
    # which is no longer built.
    #   No rule to make target '.../jre/lib/amd64/libjsig.so', needed by
    #   'generic_export'
    ("makefiles/defs.make",
     "LIBRARY_SUFFIX=so",
     "LIBRARY_SUFFIX=dll",
     "the library suffix"),
    ("makefiles/defs.make",
     "EXPORT_LIST += $(EXPORT_JRE_LIB_ARCH_DIR)/libjsig.$(LIBRARY_SUFFIX)\n",
     "",
     "the libjsig export"),
    ("makefiles/defs.make",
     "libjvm.$(LIBRARY_SUFFIX)",
     "jvm.$(LIBRARY_SUFFIX)",
     "the VM library name in the export list", 3),
    # The serviceability agent's native half is not built either; sa-jdi.jar,
    # which is pure java and which the images stage does look for, stays.
    ("makefiles/defs.make",
     " $(EXPORT_JRE_LIB_ARCH_DIR)/libsaproc.$(LIBRARY_SUFFIX)",
     "",
     "the libsaproc export", 3),
]

p = f"{hsl}/platform_amd64"
if open(p, encoding='utf-8').read() == platform:
    print("platform file: already the windows port")
else:
    open(p, 'w', encoding='utf-8', newline='').write(platform)
    print("platform file: pointed at the windows sources")

for edit in edits:
    name, old, new, what = edit[:4]
    want = edit[4] if len(edit) > 4 else 1
    f = f"{hsl}/{name}"
    s = open(f, encoding='utf-8', errors='surrogateescape').read()
    if s.count(old) == 0 and (new == "" or s.count(new) >= 1):
        print(f"{name}: {what} already fixed")
        continue
    if s.count(old) != want:
        sys.exit(f"{name}: {what} matched {s.count(old)} times, expected {want}")
    open(f, 'w', encoding='utf-8', errors='surrogateescape', newline='').write(
        s.replace(old, new))
    print(f"{name}: fixed {what}")
PY
fi
