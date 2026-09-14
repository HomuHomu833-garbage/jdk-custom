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

# Shared with build.sh, which recomputes the same paths from $ROOTDIR.
BUILD_DIR="${BUILD_DIR:-$ROOTDIR/build}"
# OpenJDK's own name for the target OS, which is what the source layout and the
# makefiles key on. build.sh derives the same value from the same two inputs.
case "${PLATFORM:-}" in
  linux|android) TARGET_OS=linux ;;
  bsd)           TARGET_OS=bsd ;;
  windows)       TARGET_OS=windows ;;
  macos)         TARGET_OS=macosx ;;
  *)             TARGET_OS="" ;;
esac
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

# No state file is written: build.sh / make-jdk.sh recompute the same SRC and
# BOOT_JDK paths from $ROOTDIR, and take JDK_VERSION straight from the env (the
# same vars CI / `docker run` already pass), so the three scripts stay decoupled.
log "Source ready at $SRC (boot JDK: $BOOT_JDK)"
