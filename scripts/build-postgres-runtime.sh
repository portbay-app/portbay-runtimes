#!/usr/bin/env bash
set -euo pipefail

# Build a relocatable, PortBay-managed PostgreSQL runtime archive.
#
# Produces  dist/postgres-<version>-<arch>.tar.zst  whose root unpacks to the
# layout the PortBay app expects (mirrors the php/node builds):
#
#   bin/postgres      ← daemon  (DatabaseEngine::Postgres → expected `bin/postgres`)
#   bin/psql          ← client      (used by per-database schema management, P4b)
#   bin/initdb        ← data-dir init (used at instance create, P4c)
#   bin/pg_dumpall    ← backup       (used by backups, P4d)
#   bin/pg_dump, bin/pg_restore, bin/pg_ctl, …
#   lib/libpq.5.dylib + share/postgresql/…   (located relative to bin/ at runtime)
#
# Source build (no official relocatable macOS tarball exists). Deps are
# minimised so the archive only carries its own libpq: --without-icu/readline/
# zlib, no openssl (PortBay binds loopback only).
#
# ⚠️ Relocation: the install hardcodes absolute dylib paths under the build
# prefix; macOS won't find them once the archive is unpacked elsewhere. The
# `relocate_macho` step rewrites libpq's id + each client's load path to
# @rpath/@loader_path and ad-hoc re-signs (install_name_tool invalidates the
# signature). This step is the one part that must be validated on a real CI
# runner — compile + `bin/psql --version` from a copied-out dir — before relying
# on it; everything above it is standard ./configure && make.

POSTGRES_VERSION="${POSTGRES_VERSION:-${1:-16.4}}"
OUT_DIR="${OUT_DIR:-${2:-dist}}"
ARCH="${ARCH:-$(uname -m)}"

case "$ARCH" in
  arm64|aarch64) MANIFEST_ARCH="aarch64" ;;
  x86_64|amd64)  MANIFEST_ARCH="x86_64" ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.work/postgres-$POSTGRES_VERSION-$MANIFEST_ARCH"
INSTALL="$WORK/install"
PKG="$OUT_DIR/postgres/$POSTGRES_VERSION"

rm -rf "$WORK" "$PKG"
mkdir -p "$WORK" "$INSTALL" "$OUT_DIR"

TARBALL="postgresql-${POSTGRES_VERSION}.tar.bz2"
SRC_BASE="https://ftp.postgresql.org/pub/source/v${POSTGRES_VERSION}"

echo "Downloading $TARBALL from $SRC_BASE …"
curl -fsSL "$SRC_BASE/$TARBALL"        -o "$WORK/$TARBALL"
curl -fsSL "$SRC_BASE/$TARBALL.sha256" -o "$WORK/$TARBALL.sha256"

echo "Verifying SHA-256 …"
# The upstream .sha256 file is "<hash>  <filename>".
EXPECTED=$(awk '{print $1}' "$WORK/$TARBALL.sha256")
ACTUAL=$(shasum -a 256 "$WORK/$TARBALL" | awk '{print $1}')
if [[ -z "$EXPECTED" || "$ACTUAL" != "$EXPECTED" ]]; then
  echo "SHA-256 mismatch for $TARBALL" >&2
  echo "  expected: $EXPECTED" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi
echo "SHA-256 OK: $ACTUAL"

echo "Extracting …"
SRC="$WORK/postgresql-${POSTGRES_VERSION}"
tar -C "$WORK" -xjf "$WORK/$TARBALL"
if [[ ! -d "$SRC" ]]; then
  echo "Unexpected source layout — expected $SRC" >&2
  ls "$WORK" >&2
  exit 1
fi

echo "Configuring + building (this compiles Postgres — needs a C toolchain) …"
(
  cd "$SRC"
  ./configure \
    --prefix="$INSTALL" \
    --without-icu \
    --without-readline \
    --without-zlib
  make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  make install
)

# --- macOS relocation (validate on CI) -------------------------------------
# Make libpq + the client tools loadable from any unpack location: give libpq
# an @rpath id, repoint each linker to it, and add an @loader_path rpath so the
# tools resolve lib/ relative to bin/. Re-sign ad-hoc afterwards.
relocate_macho() {
  local libpq
  libpq="$(/usr/bin/find "$INSTALL/lib" -maxdepth 1 -name 'libpq.*.dylib' | head -n1)"
  [[ -n "$libpq" ]] || { echo "libpq dylib not found under $INSTALL/lib" >&2; exit 1; }
  local libpq_name; libpq_name="$(basename "$libpq")"

  install_name_tool -id "@rpath/$libpq_name" "$libpq"
  codesign -s - -f "$libpq" 2>/dev/null || true

  # Rewrite every Mach-O in bin/ that links the build-prefix libpq.
  for bin in "$INSTALL"/bin/*; do
    [[ -f "$bin" ]] || continue
    if otool -L "$bin" 2>/dev/null | grep -q "$INSTALL/lib/$libpq_name"; then
      install_name_tool -change "$INSTALL/lib/$libpq_name" "@rpath/$libpq_name" "$bin"
      install_name_tool -add_rpath "@loader_path/../lib" "$bin" 2>/dev/null || true
      codesign -s - -f "$bin" 2>/dev/null || true
    fi
  done
}
relocate_macho

# --- lay out the package ----------------------------------------------------
# Ship bin/ + lib/ + share/ (postgres locates share/ relative to the executable).
mkdir -p "$PKG"
cp -a "$INSTALL/bin"   "$PKG/bin"
cp -a "$INSTALL/lib"   "$PKG/lib"
cp -a "$INSTALL/share" "$PKG/share"

echo "Smoke-testing installed binaries …"
"$PKG/bin/postgres" --version
"$PKG/bin/psql" --version
"$PKG/bin/pg_dumpall" --version
"$PKG/bin/initdb" --version

ARCHIVE="$OUT_DIR/postgres-$POSTGRES_VERSION-$MANIFEST_ARCH.tar.zst"
echo "Repacking to $ARCHIVE …"
tar -C "$PKG" --zstd -cf "$ARCHIVE" .
shasum -a 256 "$ARCHIVE" | awk '{print $1}' > "$ARCHIVE.sha256"
wc -c < "$ARCHIVE" | tr -d ' ' > "$ARCHIVE.size"

echo "$ARCHIVE"
