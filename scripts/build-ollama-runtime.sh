#!/usr/bin/env bash
set -euo pipefail

# Repack the official Ollama macOS CLI tarball (ollama-darwin.tgz) — not
# compiled, like Node. The SHA-256 is verified against the `sha256sum.txt`
# Ollama publishes alongside each release.
#
# Layout: everything goes under bin/ — the tarball is flat (`ollama`,
# `llama-server`, `llama-quantize`, libggml-*.so) and Ollama discovers its
# runner libraries relative to the executable, so the siblings must stay
# next to bin/ollama.

OLLAMA_VERSION="${OLLAMA_VERSION:-${1:-0.30.6}}"
OUT_DIR="${OUT_DIR:-${2:-dist}}"
ARCH="${ARCH:-$(uname -m)}"

case "$ARCH" in
  arm64|aarch64) MANIFEST_ARCH="aarch64" ;;
  x86_64|amd64)  MANIFEST_ARCH="x86_64"  ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.work/ollama-$OLLAMA_VERSION-$MANIFEST_ARCH"
PKG="$OUT_DIR/ollama/$OLLAMA_VERSION"

rm -rf "$WORK" "$PKG"
mkdir -p "$WORK" "$OUT_DIR"

TARBALL_NAME="ollama-darwin.tgz"
DIST_BASE="https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}"

echo "Downloading $TARBALL_NAME from $DIST_BASE …"
curl -fsSL "$DIST_BASE/$TARBALL_NAME"   -o "$WORK/$TARBALL_NAME"
curl -fsSL "$DIST_BASE/sha256sum.txt"   -o "$WORK/sha256sum.txt"

echo "Verifying SHA-256 …"
# sha256sum.txt lines look like: `<sha>  ./ollama-darwin.tgz`
EXPECTED=$(grep -E " \./?$TARBALL_NAME$" "$WORK/sha256sum.txt" | awk '{print $1}')
if [[ -z "$EXPECTED" ]]; then
  echo "sha256sum.txt does not contain an entry for $TARBALL_NAME" >&2
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
mkdir -p "$PKG/bin"
tar -C "$PKG/bin" -xzf "$WORK/$TARBALL_NAME"

if [[ ! -f "$PKG/bin/ollama" ]]; then
  echo "Unexpected tarball layout — bin/ollama missing after extract" >&2
  ls "$PKG/bin" >&2
  exit 1
fi
chmod 0755 "$PKG/bin/ollama"

echo "Smoke-testing installed binary …"
# Prints the client version (plus a "could not connect" warning when no
# server is running — that's fine).
"$PKG/bin/ollama" --version

ARCHIVE="$OUT_DIR/ollama-$OLLAMA_VERSION-$MANIFEST_ARCH.tar.zst"
echo "Repacking to $ARCHIVE …"
tar -C "$PKG" --zstd -cf "$ARCHIVE" .
shasum -a 256 "$ARCHIVE" | awk '{print $1}' > "$ARCHIVE.sha256"
wc -c < "$ARCHIVE" | tr -d ' ' > "$ARCHIVE.size"

echo "$ARCHIVE"
