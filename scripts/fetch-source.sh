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

# No state file is written: build.sh / make-jdk.sh recompute the same SRC and
# BOOT_JDK paths from $ROOTDIR, and take JDK_VERSION straight from the env (the
# same vars CI / `docker run` already pass), so the three scripts stay decoupled.
log "Source ready at $SRC (boot JDK: $BOOT_JDK)"
