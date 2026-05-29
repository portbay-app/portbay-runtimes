#!/usr/bin/env bash
set -euo pipefail

# Build a PortBay-managed Redis runtime archive.
#
# Produces  dist/redis-<version>-<arch>.tar.zst  unpacking to:
#   bin/redis-server   ← daemon  (DatabaseEngine::Redis → expected `bin/redis-server`)
#   bin/redis-cli      ← client
#
# Source build (`make`), TLS off, so the binaries link only against system
# libraries — no bundled dylibs, so the archive is relocation-safe with no
# install_name_tool surgery (unlike postgres/mysql).
#
# Integrity: download.redis.io publishes no checksum sidecar, so the expected
# SHA-256 must be pinned by the caller (REDIS_SHA256 / 3rd arg). The release
# workflow passes it as a required input.

REDIS_VERSION="${REDIS_VERSION:-${1:-7.4.1}}"
OUT_DIR="${OUT_DIR:-${2:-dist}}"
REDIS_SHA256="${REDIS_SHA256:-${3:-}}"
ARCH="${ARCH:-$(uname -m)}"

case "$ARCH" in
  arm64|aarch64) MANIFEST_ARCH="aarch64" ;;
  x86_64|amd64)  MANIFEST_ARCH="x86_64" ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 2 ;;
esac

if [[ -z "$REDIS_SHA256" ]]; then
  echo "REDIS_SHA256 is required (pin the expected hash for redis $REDIS_VERSION)." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.work/redis-$REDIS_VERSION-$MANIFEST_ARCH"
PKG="$OUT_DIR/redis/$REDIS_VERSION"

rm -rf "$WORK" "$PKG"
mkdir -p "$WORK" "$PKG/bin" "$OUT_DIR"

TARBALL="redis-${REDIS_VERSION}.tar.gz"
echo "Downloading $TARBALL …"
curl -fsSL "https://download.redis.io/releases/$TARBALL" -o "$WORK/$TARBALL"

echo "Verifying SHA-256 …"
ACTUAL=$(shasum -a 256 "$WORK/$TARBALL" | awk '{print $1}')
if [[ "$ACTUAL" != "$REDIS_SHA256" ]]; then
  echo "SHA-256 mismatch for $TARBALL" >&2
  echo "  expected: $REDIS_SHA256" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi
echo "SHA-256 OK: $ACTUAL"

echo "Extracting + building (make) …"
SRC="$WORK/redis-${REDIS_VERSION}"
tar -C "$WORK" -xzf "$WORK/$TARBALL"
if [[ ! -d "$SRC" ]]; then
  echo "Unexpected source layout — expected $SRC" >&2
  ls "$WORK" >&2
  exit 1
fi
# BUILD_TLS=no keeps redis off OpenSSL; MALLOC=libc avoids jemalloc (Linux-only
# here anyway). The server/cli then depend only on the system libraries.
make -C "$SRC" -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" BUILD_TLS=no MALLOC=libc

cp "$SRC/src/redis-server" "$PKG/bin/redis-server"
cp "$SRC/src/redis-cli"    "$PKG/bin/redis-cli"
chmod 0755 "$PKG/bin/redis-server" "$PKG/bin/redis-cli"

echo "Smoke-testing installed binaries …"
"$PKG/bin/redis-server" --version
"$PKG/bin/redis-cli" --version

ARCHIVE="$OUT_DIR/redis-$REDIS_VERSION-$MANIFEST_ARCH.tar.zst"
echo "Repacking to $ARCHIVE …"
tar -C "$PKG" --zstd -cf "$ARCHIVE" .
shasum -a 256 "$ARCHIVE" | awk '{print $1}' > "$ARCHIVE.sha256"
wc -c < "$ARCHIVE" | tr -d ' ' > "$ARCHIVE.size"

echo "$ARCHIVE"
