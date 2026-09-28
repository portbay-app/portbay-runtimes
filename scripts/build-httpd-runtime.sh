#!/usr/bin/env bash
set -euo pipefail

# Build a relocatable, PortBay-managed Apache httpd 2.4 runtime archive.
#
# Produces  dist/httpd-<version>-<arch>.tar.zst  (manifest lang "apache")
# unpacking to:
#
#   bin/httpd                   ← the binary the app runs (`expected_binary_rel("apache")`)
#   modules/mod_*.so            ← found by the app as <bin>/../modules (`apache_module_dir`)
#   lib/libapr-1.0.dylib, lib/libaprutil-1.0.dylib
#   conf/mime.types
#   share/licenses/{httpd,apr,apr-util,pcre2}/…
#
# Modules are exactly the set PortBay's generated httpd.conf LoadModules
# (`render_apache_config` in portbay/src-tauri/src/webservers.rs), plus
# mod_headers for directives users add: every one is built SHARED so a
# LoadModule line for it always has a file to load. Everything else is left
# out; no TLS — PortBay's Caddy edge terminates it.
#
# Relocation: httpd hardcodes absolute paths in two places.
#   1. dylib load paths — rewritten here to @rpath with an @loader_path rpath,
#      so httpd, its tools and every module find lib/ from wherever the archive
#      is unpacked.
#   2. HTTPD_ROOT (`httpd -V`) — the compiled-in ServerRoot. PortBay's config
#      sets ServerRoot, every log/pid/mutex path and every LoadModule path
#      absolutely, and resolves modules from the binary's own location before it
#      ever consults HTTPD_ROOT, so the stale value is never used. The smoke test
#      below deletes the build prefix before running to prove it.
#
# PCRE2 is linked statically; APR/APR-util are built from the bundled srclib.
# expat and iconv come from macOS itself.
#
# Arch: a native build when ARCH matches the host. A cross-arch build compiles
# universal (`-arch arm64 -arch x86_64`) so APR's configure-time run tests
# execute the host slice (both are LP64 little-endian, so every probed size and
# byte order is identical), then thins every Mach-O to the requested arch. A
# cross-arch build cannot be smoke-tested on a host without Rosetta; the script
# says so rather than pretending.

HTTPD_VERSION="${HTTPD_VERSION:-${1:-2.4.68}}"
OUT_DIR="${OUT_DIR:-${2:-dist}}"
ARCH="${ARCH:-$(uname -m)}"
APR_VERSION="${APR_VERSION:-1.7.6}"
APR_UTIL_VERSION="${APR_UTIL_VERSION:-1.6.5}"
# pcre2 publishes no sha256 sidecar; this matches the Homebrew formula checksum.
PCRE2_VERSION="${PCRE2_VERSION:-10.48}"
PCRE2_SHA256="${PCRE2_SHA256:-b6c68fdf6f3ac31388b50aa89ff0fc49c00c987c16e7b5146491d12003f2c8ed}"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

MODULES="mpm_event unixd authz_core authz_host dir mime rewrite setenvif log_config proxy proxy_fcgi headers"

case "$ARCH" in
  arm64|aarch64) MANIFEST_ARCH="aarch64"; LIPO_ARCH="arm64" ;;
  x86_64|amd64)  MANIFEST_ARCH="x86_64";  LIPO_ARCH="x86_64" ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 2 ;;
esac
case "$(uname -m)" in
  arm64) HOST_ARCH="arm64" ;;
  *)     HOST_ARCH="x86_64" ;;
esac
if [[ "$LIPO_ARCH" == "$HOST_ARCH" ]]; then
  ARCH_FLAGS="-arch $LIPO_ARCH"
  CROSS=0
else
  ARCH_FLAGS="-arch arm64 -arch x86_64"
  CROSS=1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$OUT_DIR" = /* ]] || OUT_DIR="$ROOT/$OUT_DIR"
WORK="$ROOT/.work/httpd-$HTTPD_VERSION-$MANIFEST_ARCH"
# Compiled-in prefix: neutral, and never present on a user's machine. The build
# installs into $STAGE via DESTDIR, so nothing is written to /opt.
PREFIX=/opt/portbay/httpd
STAGE="$WORK/stage"
INSTALL="$STAGE$PREFIX"
DEPS="$WORK/deps"
PKG="$OUT_DIR/httpd/$HTTPD_VERSION"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
# Keep the build directory out of __FILE__ strings in the shipped binaries.
MAP="-ffile-prefix-map=$WORK/=portbay-build/"

rm -rf "$WORK" "$PKG"
mkdir -p "$WORK" "$OUT_DIR"

verify() { # file sha256
  local actual; actual=$(shasum -a 256 "$1" | awk '{print $1}')
  if [[ -z "$2" || "$actual" != "$2" ]]; then
    echo "SHA-256 mismatch for $(basename "$1")" >&2
    echo "  expected: $2" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
  echo "SHA-256 OK: $(basename "$1") $actual"
}

# Apache publishes a .sha256 sidecar for each tarball; verify against it.
fetch_apache() { # path-under-dist name
  local url="https://downloads.apache.org/$1/$2"
  echo "Downloading $url …"
  curl -fsSL "$url" -o "$WORK/$2"
  curl -fsSL "$url.sha256" -o "$WORK/$2.sha256"
  verify "$WORK/$2" "$(awk '{print $1}' "$WORK/$2.sha256")"
}

fetch_apache httpd "httpd-$HTTPD_VERSION.tar.bz2"
fetch_apache apr "apr-$APR_VERSION.tar.bz2"
fetch_apache apr "apr-util-$APR_UTIL_VERSION.tar.bz2"
echo "Downloading pcre2 $PCRE2_VERSION …"
curl -fsSL "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.bz2" \
  -o "$WORK/pcre2.tar.bz2"
verify "$WORK/pcre2.tar.bz2" "$PCRE2_SHA256"

tar -C "$WORK" -xjf "$WORK/httpd-$HTTPD_VERSION.tar.bz2"
tar -C "$WORK" -xjf "$WORK/apr-$APR_VERSION.tar.bz2"
tar -C "$WORK" -xjf "$WORK/apr-util-$APR_UTIL_VERSION.tar.bz2"
tar -C "$WORK" -xjf "$WORK/pcre2.tar.bz2"
SRC="$WORK/httpd-$HTTPD_VERSION"
PCRE2_SRC="$WORK/pcre2-$PCRE2_VERSION"
mv "$WORK/apr-$APR_VERSION" "$SRC/srclib/apr"
mv "$WORK/apr-util-$APR_UTIL_VERSION" "$SRC/srclib/apr-util"

echo "Building static pcre2 …"
(
  cd "$PCRE2_SRC"
  CFLAGS="-O2 $ARCH_FLAGS $MAP" ./configure --prefix="$DEPS" \
    --disable-dependency-tracking --disable-shared --enable-static --enable-jit
  make -j"$JOBS"
  make install
)

SDK="$(xcrun --show-sdk-path)"
echo "Configuring + building httpd $HTTPD_VERSION ($MANIFEST_ARCH) …"
(
  cd "$SRC"
  CFLAGS="-O2 $ARCH_FLAGS $MAP" LDFLAGS="$ARCH_FLAGS" ./configure \
    --prefix="$PREFIX" \
    --with-included-apr \
    --with-expat="$SDK/usr" \
    --with-pcre="$DEPS/bin/pcre2-config" \
    --without-crypto \
    --without-ldap \
    --without-sqlite3 \
    --without-pgsql \
    --without-mysql \
    --without-berkeley-db \
    --without-gdbm \
    --enable-so \
    --with-mpm=event \
    --enable-mpms-shared=event \
    --enable-modules=none \
    --enable-mods-shared="$MODULES" \
    --disable-ssl \
    --disable-http2 \
    --disable-brotli
  make -j"$JOBS"
  make install DESTDIR="$STAGE"
)

if [[ "$CROSS" == 1 ]]; then
  echo "Thinning the universal build to $LIPO_ARCH …"
  for f in "$INSTALL/bin/httpd" "$INSTALL"/lib/*.dylib "$INSTALL"/modules/*.so; do
    [[ -L "$f" ]] && continue
    lipo "$f" -thin "$LIPO_ARCH" -output "$f.thin"
    mv "$f.thin" "$f"
  done
fi

# --- relocation ---------------------------------------------------------------
echo "Relocating dylib load paths …"
for lib in "$INSTALL"/lib/libapr-1.0.dylib "$INSTALL"/lib/libaprutil-1.0.dylib; do
  [[ -f "$lib" ]] || { echo "missing $lib" >&2; exit 1; }
done
rewrite_refs() { # mach-o
  local f="$1" dep
  while read -r dep; do
    case "$dep" in
      "$PREFIX"/lib/*|"$INSTALL"/lib/*) install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" ;;
    esac
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
}
for lib in "$INSTALL"/lib/*.dylib; do
  [[ -L "$lib" ]] && continue
  install_name_tool -id "@rpath/$(basename "$lib")" "$lib"
  rewrite_refs "$lib"
  install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
done
for f in "$INSTALL/bin/httpd" "$INSTALL"/modules/*.so; do
  rewrite_refs "$f"
  install_name_tool -add_rpath "@loader_path/../lib" "$f" 2>/dev/null || true
done

echo "Asserting nothing still points into the build tree …"
leaks=0
for f in "$INSTALL/bin/httpd" "$INSTALL"/modules/*.so "$INSTALL"/lib/*.dylib; do
  [[ -L "$f" ]] && continue
  if otool -L "$f" | tail -n +2 | grep -F -e "$WORK" -e "$PREFIX"; then
    echo "  ^ in $f" >&2
    leaks=1
  fi
done
[[ "$leaks" == 0 ]] || { echo "absolute build paths remain" >&2; exit 1; }

# --- lay out the package ----------------------------------------------------
mkdir -p "$PKG/bin" "$PKG/lib" "$PKG/modules" "$PKG/conf" \
  "$PKG/share/licenses/httpd" "$PKG/share/licenses/apr" \
  "$PKG/share/licenses/apr-util" "$PKG/share/licenses/pcre2"
cp "$INSTALL/bin/httpd" "$PKG/bin/httpd"
cp -a "$INSTALL"/lib/libapr-1.0.dylib "$INSTALL"/lib/libaprutil-1.0.dylib "$PKG/lib/"
for m in $MODULES; do
  cp "$INSTALL/modules/mod_$m.so" "$PKG/modules/mod_$m.so"
done
cp "$INSTALL/conf/mime.types" "$PKG/conf/mime.types"
cp "$SRC/LICENSE" "$SRC/NOTICE" "$PKG/share/licenses/httpd/"
cp "$SRC/srclib/apr/LICENSE" "$SRC/srclib/apr/NOTICE" "$PKG/share/licenses/apr/"
cp "$SRC/srclib/apr-util/LICENSE" "$SRC/srclib/apr-util/NOTICE" "$PKG/share/licenses/apr-util/"
cp "$PCRE2_SRC/LICENCE.md" "$PKG/share/licenses/pcre2/" 2>/dev/null \
  || cp "$PCRE2_SRC/LICENCE" "$PKG/share/licenses/pcre2/"
chmod 0755 "$PKG/bin/httpd"
lipo -archs "$PKG/bin/httpd"
# install_name_tool invalidated the signatures; arm64 refuses to run unsigned code.
for f in "$PKG/bin/httpd" "$PKG"/lib/*.dylib "$PKG"/modules/*.so; do
  codesign --force --sign - "$f"
done

if [[ "$CROSS" == 1 ]]; then
  echo "NOT smoke-tested: $MANIFEST_ARCH build on a $HOST_ARCH host."
else
echo "Smoke-testing from a copy outside the build prefix …"
SMOKE="$(mktemp -d)"
cp -R "$PKG" "$SMOKE/unpacked"
rm -rf "$STAGE" "$DEPS" # the build tree must not be what makes it work
U="$SMOKE/unpacked"
"$U/bin/httpd" -v
mkdir -p "$SMOKE/run/docroot"
{
  echo "ServerRoot \"$SMOKE/run\""
  echo "PidFile \"$SMOKE/run/httpd.pid\""
  echo "Mutex \"file:$SMOKE/run\" default"
  echo "Listen 127.0.0.1:18081"
  echo "ServerName smoke.test"
  for m in $MODULES; do
    echo "LoadModule ${m}_module \"$U/modules/mod_$m.so\""
  done
  echo "DocumentRoot \"$SMOKE/run/docroot\""
  echo "ErrorLog \"$SMOKE/run/error.log\""
  echo "CustomLog \"$SMOKE/run/access.log\" common"
  echo "TypesConfig \"$U/conf/mime.types\""
  echo "RewriteEngine On"
  echo "SetEnvIfNoCase X-Forwarded-Proto \"^https\$\" HTTPS=on"
  echo "<FilesMatch \"\\.php\$\">"
  echo "    SetHandler \"proxy:fcgi://127.0.0.1:9\""
  echo "</FilesMatch>"
} > "$SMOKE/run/httpd.conf"
"$U/bin/httpd" -f "$SMOKE/run/httpd.conf" -t
rm -rf "$SMOKE"
fi

ARCHIVE="$OUT_DIR/httpd-$HTTPD_VERSION-$MANIFEST_ARCH.tar.zst"
echo "Repacking to $ARCHIVE …"
tar -C "$PKG" --zstd -cf "$ARCHIVE" .
shasum -a 256 "$ARCHIVE" | awk '{print $1}' > "$ARCHIVE.sha256"
wc -c < "$ARCHIVE" | tr -d ' ' > "$ARCHIVE.size"

if strings -a "$PKG/bin/httpd" "$PKG"/lib/*.dylib "$PKG"/modules/*.so | grep -F "$ROOT"; then
  echo "a binary embeds a build-machine path (above)" >&2
  exit 1
fi

echo "$ARCHIVE"
