#!/usr/bin/env bash
# Thin wrapper: resolve the GA build tag for a Temurin feature release, fetch
# that source from the matching adoptium/jdk<N>u repo, download the Temurin JDK we
# use as the boot + interim build JDK, and apply the global (+ per-patchset)
# patches. No state file is written — build.sh recomputes the same paths from
# $ROOTDIR and reads JDK_VERSION from the env, like the sibling repos.
#
#   JDK_VERSION   required feature version: 8 | 11 | 17 | 21 | 25
#   JDK_TAG       optional exact source tag (e.g. jdk-21.0.5+11, jdk8u432-b06);
#                 when unset it is resolved from the Adoptium GA feed
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

# Download with retries: re-run aria2c on any failure so transient GitHub/Adoptium
# 501/504 (and the like) recover, without relying on aria2's --retry-on-unknown
# (older aria2 builds lack it). Pass aria2c args, e.g. --dir=/tmp -o f.zip URL.
fetch() {
  local i=0
  until aria2c --console-log-level=error --check-certificate=false \
               --max-tries=5 --retry-wait=2 --connect-timeout=15 "$@"; do
    i=$((i + 1)); [ "$i" -ge 5 ] && { echo "fetch: giving up after $i attempts" >&2; return 1; }
    echo "fetch: aria2c failed, retry $i/5 in 2s..." >&2; sleep 2
  done
}

# Source = the Temurin tree: adoptium/jdk<N>u mirrors the matching OpenJDK update
# line and carries the same upstream tags plus Adoptium's own commits, so what we
# build here is Temurin's source rather than vanilla OpenJDK. 8 keeps the legacy
# "jdk8u" naming and the old build system. Override JDK_REPO to build elsewhere.
JDK_REPO="${JDK_REPO:-https://github.com/adoptium/jdk${JDK_VERSION}u}"

# Resolve the exact GA build tag from the Adoptium feed unless one was pinned.
# release_name is the upstream git tag (jdk-21.0.5+11 / jdk8u432-b06), so we can
# clone it directly. python3 is in the builder image; parse JSON with it rather
# than depending on jq.
if [ -z "${JDK_TAG:-}" ]; then
  log "Resolving latest GA tag for JDK $JDK_VERSION"
  feed="https://api.adoptium.net/v3/assets/feature_releases/${JDK_VERSION}/ga?image_type=jdk&os=linux&architecture=x64&jvm_impl=hotspot&page_size=1&sort_order=DESC"
  fetch --dir=/tmp -o adoptium-feed.json "$feed"
  JDK_TAG="$(python3 -c 'import json,sys; print(json.load(open("/tmp/adoptium-feed.json"))[0]["release_name"])' < /dev/null)"
  rm -f /tmp/adoptium-feed.json
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

# --- boot / build JDK (Temurin) ---------------------------------------------
# One Temurin x64 JDK serves as both the boot JDK and, for cross builds, the
# --with-build-jdk that runs the interim Java tools on the build host.
if [ ! -x "$BOOT_JDK/bin/javac" ]; then
  log "Downloading Temurin $BOOT_JDK_VERSION (boot + build JDK, linux x64)"
  boot_url="https://api.adoptium.net/v3/binary/latest/${BOOT_JDK_VERSION}/ga/linux/x64/jdk/hotspot/normal/eclipse"
  fetch --dir="$ROOTDIR" -o boot-jdk.tar.gz "$boot_url"
  rm -rf "$BOOT_JDK"; mkdir -p "$BOOT_JDK"
  # Temurin archives nest everything under one jdk-* dir; strip it.
  tar -xzf "$ROOTDIR/boot-jdk.tar.gz" -C "$BOOT_JDK" --strip-components=1
  rm -f "$ROOTDIR/boot-jdk.tar.gz"
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
