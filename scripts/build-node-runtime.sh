#!/usr/bin/env bash
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-${1:-22.14.0}}"
OUT_DIR="${OUT_DIR:-${2:-dist}}"
ARCH="${ARCH:-$(uname -m)}"

case "$ARCH" in
  arm64|aarch64) MANIFEST_ARCH="aarch64"; NODE_ARCH="darwin-arm64" ;;
  x86_64|amd64)  MANIFEST_ARCH="x86_64";  NODE_ARCH="darwin-x64"  ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.work/node-$NODE_VERSION-$MANIFEST_ARCH"
PKG="$OUT_DIR/node/$NODE_VERSION"

rm -rf "$WORK" "$PKG"
mkdir -p "$WORK" "$OUT_DIR"

TARBALL_NAME="node-v${NODE_VERSION}-${NODE_ARCH}.tar.xz"
DIST_BASE="https://nodejs.org/dist/v${NODE_VERSION}"

echo "Downloading $TARBALL_NAME from $DIST_BASE …"
curl -fsSL "$DIST_BASE/$TARBALL_NAME"        -o "$WORK/$TARBALL_NAME"
curl -fsSL "$DIST_BASE/SHASUMS256.txt"       -o "$WORK/SHASUMS256.txt"

echo "Verifying SHA-256 …"
# Extract just the line for this tarball and verify it.
EXPECTED=$(grep " $TARBALL_NAME$" "$WORK/SHASUMS256.txt" | awk '{print $1}')
if [[ -z "$EXPECTED" ]]; then
  echo "SHASUMS256.txt does not contain an entry for $TARBALL_NAME" >&2
  exit 1
fi
ACTUAL=$(shasum -a 256 "$WORK/$TARBALL_NAME" | awk '{print $1}')
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "SHA-256 mismatch for $TARBALL_NAME" >&2
  echo "  expected: $EXPECTED" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi
echo "SHA-256 OK: $ACTUAL"

echo "Extracting $TARBALL_NAME …"
EXTRACT="$WORK/extract"
mkdir -p "$EXTRACT"
tar -C "$EXTRACT" -xJf "$WORK/$TARBALL_NAME"

# The tarball root is node-v<ver>-<nodearch>/
INNER="$EXTRACT/node-v${NODE_VERSION}-${NODE_ARCH}"
if [[ ! -d "$INNER" ]]; then
  echo "Unexpected tarball layout — expected top-level dir: $INNER" >&2
  ls "$EXTRACT" >&2
  exit 1
fi

# Lay out the package: bin/{node,npm,npx,corepack} + lib/node_modules/{npm,corepack}
mkdir -p "$PKG/bin" "$PKG/lib/node_modules"

cp -a "$INNER/bin/node"     "$PKG/bin/node"
chmod 0755 "$PKG/bin/node"

# Copy lib/node_modules subtrees (npm and corepack). The official Node tarball
# ships these here; the bin/{npm,npx,corepack} shims resolve via these dirs.
for MOD in npm corepack; do
  SRC_MOD="$INNER/lib/node_modules/$MOD"
  if [[ ! -d "$SRC_MOD" ]]; then
    echo "lib/node_modules/$MOD not found in extracted tarball" >&2
    ls "$INNER/lib/node_modules/" >&2
    exit 1
  fi
  cp -a "$SRC_MOD" "$PKG/lib/node_modules/$MOD"
done

# npm, npx, and corepack in the official tarball are symlinks into lib/node_modules.
# The bin scripts use require('./lib/...') relative to their symlink target's
# directory. Recreating the same symlink structure preserves those relative paths
# so the modules resolve correctly at runtime.
for BIN in npm npx corepack; do
  SRC="$INNER/bin/$BIN"
  if [[ ! -e "$SRC" && ! -L "$SRC" ]]; then
    echo "bin/$BIN not found in tarball" >&2
    ls "$INNER/bin/" >&2
    exit 1
  fi
  if [[ -L "$SRC" ]]; then
    # Mirror the tarball symlink (e.g. ../lib/node_modules/npm/bin/npm-cli.js).
    ln -sf "$(readlink "$SRC")" "$PKG/bin/$BIN"
  else
    cp "$SRC" "$PKG/bin/$BIN"
    chmod 0755 "$PKG/bin/$BIN"
  fi
done

echo "Smoke-testing installed binaries …"
"$PKG/bin/node" --version
"$PKG/bin/corepack" --version

ARCHIVE="$OUT_DIR/node-$NODE_VERSION-$MANIFEST_ARCH.tar.zst"
echo "Repacking to $ARCHIVE …"
tar -C "$PKG" --zstd -cf "$ARCHIVE" .
shasum -a 256 "$ARCHIVE" | awk '{print $1}' > "$ARCHIVE.sha256"
wc -c < "$ARCHIVE" | tr -d ' ' > "$ARCHIVE.size"

echo "$ARCHIVE"
