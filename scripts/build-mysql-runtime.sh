#!/usr/bin/env bash
set -euo pipefail

# Build a PortBay-managed MySQL runtime archive from the official macOS tarball.
#
# Produces  dist/mysql-<version>-<arch>.tar.zst  unpacking to:
#   bin/mysqld     ← daemon   (DatabaseEngine::Mysql → expected `bin/mysqld`)
#   bin/mysql      ← client       (per-database schema management, P4b)
#   bin/mysqldump  ← backup       (backups, P4d)
#   lib/ + share/  ← plugins + errmsg/system-schema (mysqld --initialize needs these)
#
# Download-and-repackage (like node): the official MySQL community tarball is
# already relocatable (bundled libs use @loader_path; mysqld derives basedir
# from its own path), so no install_name_tool surgery is needed — verify with
# `bin/mysqld --version` from a copied-out dir on CI.
#
# Filename caveat: MySQL bakes the build's macOS major into the name
# (e.g. `mysql-8.4.4-macos14-arm64.tar.gz`). It's per-release, not per-arch, so
# MYSQL_MACOS_TAG must match the chosen version. Integrity is a caller-pinned
# SHA-256 (no checksum sidecar on the CDN).

MYSQL_VERSION="${MYSQL_VERSION:-${1:-8.4.4}}"
OUT_DIR="${OUT_DIR:-${2:-dist}}"
MYSQL_SHA256="${MYSQL_SHA256:-${3:-}}"
MYSQL_MACOS_TAG="${MYSQL_MACOS_TAG:-macos14}"
ARCH="${ARCH:-$(uname -m)}"

case "$ARCH" in
  arm64|aarch64) MANIFEST_ARCH="aarch64"; MYSQL_ARCH="arm64" ;;
  x86_64|amd64)  MANIFEST_ARCH="x86_64";  MYSQL_ARCH="x86_64" ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 2 ;;
esac

if [[ -z "$MYSQL_SHA256" ]]; then
  echo "MYSQL_SHA256 is required (pin the hash for mysql $MYSQL_VERSION $MYSQL_ARCH)." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.work/mysql-$MYSQL_VERSION-$MANIFEST_ARCH"
PKG="$OUT_DIR/mysql/$MYSQL_VERSION"

rm -rf "$WORK" "$PKG"
mkdir -p "$WORK" "$OUT_DIR"

MAJOR_MINOR="${MYSQL_VERSION%.*}"   # 8.4.4 → 8.4
TARBALL="mysql-${MYSQL_VERSION}-${MYSQL_MACOS_TAG}-${MYSQL_ARCH}.tar.gz"
URL="https://cdn.mysql.com/Downloads/MySQL-${MAJOR_MINOR}/${TARBALL}"

echo "Downloading $TARBALL …"
curl -fsSL "$URL" -o "$WORK/$TARBALL"

echo "Verifying SHA-256 …"
ACTUAL=$(shasum -a 256 "$WORK/$TARBALL" | awk '{print $1}')
if [[ "$ACTUAL" != "$MYSQL_SHA256" ]]; then
  echo "SHA-256 mismatch for $TARBALL" >&2
  echo "  expected: $MYSQL_SHA256" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi
echo "SHA-256 OK: $ACTUAL"

echo "Extracting …"
EXTRACT="$WORK/extract"
mkdir -p "$EXTRACT"
tar -C "$EXTRACT" -xzf "$WORK/$TARBALL"
INNER="$EXTRACT/mysql-${MYSQL_VERSION}-${MYSQL_MACOS_TAG}-${MYSQL_ARCH}"
if [[ ! -d "$INNER" ]]; then
  echo "Unexpected tarball layout — expected $INNER" >&2
  ls "$EXTRACT" >&2
  exit 1
fi

# Ship bin/ + lib/ + share/. mysqld locates share/ (errmsg, system schema) and
# lib/plugin relative to basedir (the parent of bin/), so the relative layout
# must be preserved — we copy whole trees rather than cherry-pick binaries.
mkdir -p "$PKG"
cp -a "$INNER/bin"   "$PKG/bin"
cp -a "$INNER/lib"   "$PKG/lib"
cp -a "$INNER/share" "$PKG/share"

echo "Smoke-testing installed binaries …"
"$PKG/bin/mysqld" --version
"$PKG/bin/mysql" --version
"$PKG/bin/mysqldump" --version

ARCHIVE="$OUT_DIR/mysql-$MYSQL_VERSION-$MANIFEST_ARCH.tar.zst"
echo "Repacking to $ARCHIVE …"
tar -C "$PKG" --zstd -cf "$ARCHIVE" .
shasum -a 256 "$ARCHIVE" | awk '{print $1}' > "$ARCHIVE.sha256"
wc -c < "$ARCHIVE" | tr -d ' ' > "$ARCHIVE.size"

echo "$ARCHIVE"
