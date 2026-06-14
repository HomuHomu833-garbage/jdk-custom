#!/usr/bin/env bash
# Package the cross-built JDK image into one archive. Driven by env vars so it
# runs identically in CI and in `docker run`, right after build.sh produces
# install/$JDK_VERSION-$TARGET.
#
#   PLATFORM      linux | bsd | windows | macos | android  (selects archive format)
#   TARGET        target triple (names the artifact, locates the install tree)
#   JDK_VERSION   feature version (8|11|17|21|25); top-level dir name in the archive
#   ROOTDIR       checkout root (default: cwd)
#   DEST          where the archive is written (default: $ROOTDIR)
#                 windows -> .7z, everything else -> .tar.xz
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${PLATFORM:?set PLATFORM}" "${TARGET:?set TARGET}" "${JDK_VERSION:?set JDK_VERSION}"
INSTALL_DIR="${INSTALL_DIR:-$ROOTDIR/install}"
DEST="${DEST:-$ROOTDIR}"
cd "$ROOTDIR"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

SRC="$INSTALL_DIR/$JDK_VERSION-$TARGET"
[ -d "$SRC" ] || { echo "install tree not found at $SRC" >&2; exit 1; }

# Stage the tree under "jdk-$JDK_VERSION" so that's the top-level path inside the
# archive (a predictable extract dir, like the official JDK tarballs ship).
STAGE="$ROOTDIR/jdk-$JDK_VERSION"
rm -rf "$STAGE"
cp -R "$SRC" "$STAGE"

mkdir -p "$DEST"
if [ "$PLATFORM" = windows ]; then
  ARCHIVE="$DEST/jdk-$TARGET.7z"
  log "Archiving -> $ARCHIVE"
  rm -f "$ARCHIVE"
  ( cd "$ROOTDIR"
    7z a -snl -t7z -mx=9 -m0=LZMA2 -md=256m -mfb=273 -mtc=on -mmt=on "$ARCHIVE" "jdk-$JDK_VERSION" >/dev/null )
else
  ARCHIVE="$DEST/jdk-$TARGET.tar.xz"
  log "Archiving -> $ARCHIVE"
  tar -cf - -C "$ROOTDIR" "jdk-$JDK_VERSION" | xz -T0 -9e --lzma2=dict=256MiB > "$ARCHIVE"
fi
log "Done -> $ARCHIVE"
