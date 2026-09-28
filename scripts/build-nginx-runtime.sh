#!/usr/bin/env bash
set -euo pipefail

# Build a relocatable, PortBay-managed nginx runtime archive.
#
# Produces  dist/nginx-<version>-<arch>.tar.zst  unpacking to:
#
#   sbin/nginx                  ← the binary the app runs (`expected_binary_rel("nginx")`)
#   conf/mime.types, conf/fastcgi_params, …   (stock files, for reference)
#   share/licenses/{nginx,pcre2,zlib}/…
#
# The app always starts nginx as `nginx -p <conf_dir> -c <conf> -g 'daemon off;'`
# with absolute log paths in the generated config, so the compiled-in prefix is
# never consulted for config. The remaining compiled-in paths (pid, temp dirs)
# are configured RELATIVE here, which nginx resolves against `-p` at runtime,
# and the pre-config error log is stderr — so the binary works from wherever it
# is unpacked.
#
# The compiled-in strings (`nginx -V`, the `-p` default) name a neutral
# /opt/portbay prefix and relative source paths, never the build machine's
# directories: nothing is installed there, the binary is copied out of objs/.
#
# PCRE2 (rewrite / regex locations) and zlib (gzip) are compiled statically into
# the binary from pinned sources, so the only dynamic dependency is libSystem:
# nothing to relocate. No TLS — PortBay's Caddy edge terminates it.
#
# Arch: a native build when ARCH matches the host. A cross-arch build compiles
# universal (`-arch arm64 -arch x86_64`) so nginx's configure-time run tests
# execute the host slice (both are LP64 little-endian, so every probed size and
# byte order is identical), then thins to the requested arch with lipo. A
# cross-arch binary cannot be smoke-tested on a host without Rosetta; the script
# says so rather than pretending.

NGINX_VERSION="${NGINX_VERSION:-${1:-1.31.6}}"
OUT_DIR="${OUT_DIR:-${2:-dist}}"
ARCH="${ARCH:-$(uname -m)}"

# Pinned upstream checksums. nginx.org and zlib.net publish only PGP
# signatures; these values match the independently published Homebrew formula
# checksums for the same tarballs. Override all three together when bumping.
NGINX_SHA256="${NGINX_SHA256:-974ed5298a5e398e008704ed5db284e655fc270c596493dbccada452448fc9f1}"
PCRE2_VERSION="${PCRE2_VERSION:-10.48}"
PCRE2_SHA256="${PCRE2_SHA256:-b6c68fdf6f3ac31388b50aa89ff0fc49c00c987c16e7b5146491d12003f2c8ed}"
ZLIB_VERSION="${ZLIB_VERSION:-1.3.2}"
ZLIB_SHA256="${ZLIB_SHA256:-bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16}"

# The app's own floor (tauri.conf.json > bundle.macOS.minimumSystemVersion).
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

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
WORK="$ROOT/.work/nginx-$NGINX_VERSION-$MANIFEST_ARCH"
PKG="$OUT_DIR/nginx/$NGINX_VERSION"

rm -rf "$WORK" "$PKG"
mkdir -p "$WORK" "$OUT_DIR"

fetch() { # url dest sha256
  echo "Downloading $1 …"
  curl -fsSL "$1" -o "$2"
  local actual; actual=$(shasum -a 256 "$2" | awk '{print $1}')
  if [[ "$actual" != "$3" ]]; then
    echo "SHA-256 mismatch for $(basename "$2")" >&2
    echo "  expected: $3" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
  echo "SHA-256 OK: $(basename "$2") $actual"
}

fetch "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
  "$WORK/nginx.tar.gz" "$NGINX_SHA256"
fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.bz2" \
  "$WORK/pcre2.tar.bz2" "$PCRE2_SHA256"
fetch "https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz" \
  "$WORK/zlib.tar.gz" "$ZLIB_SHA256"

tar -C "$WORK" -xzf "$WORK/nginx.tar.gz"
tar -C "$WORK" -xjf "$WORK/pcre2.tar.bz2"
tar -C "$WORK" -xzf "$WORK/zlib.tar.gz"
SRC="$WORK/nginx-$NGINX_VERSION"
PCRE2_SRC="$WORK/pcre2-$PCRE2_VERSION"
ZLIB_SRC="$WORK/zlib-$ZLIB_VERSION"
for d in "$SRC" "$PCRE2_SRC" "$ZLIB_SRC"; do
  [[ -d "$d" ]] || { echo "Unexpected source layout — expected $d" >&2; ls "$WORK" >&2; exit 1; }
done

echo "Configuring + building nginx $NGINX_VERSION ($MANIFEST_ARCH, cross=$CROSS) …"
(
  cd "$SRC"
  # Every runtime path is RELATIVE, so nginx resolves it against `-p`:
  #   --pid-path, --http-*-temp-path, --lock-path, --http-log-path
  # --conf-path stays relative too; the app always passes -c.
  # --error-log-path=stderr: the log nginx opens BEFORE it has read any config.
  # A relative path there resolves to <-p>/logs/error.log, which does not
  # exist in PortBay's per-project conf dir, and every start then prints
  # `[alert] could not open error log file`. stderr is what the supervisor
  # captures anyway.
  ./configure \
    --prefix=/opt/portbay/nginx/ \
    --sbin-path=sbin/nginx \
    --conf-path=conf/nginx.conf \
    --error-log-path=stderr \
    --http-log-path=logs/access.log \
    --pid-path=nginx.pid \
    --lock-path=nginx.lock \
    --http-client-body-temp-path=client_body_temp \
    --http-proxy-temp-path=proxy_temp \
    --http-fastcgi-temp-path=fastcgi_temp \
    --http-uwsgi-temp-path=uwsgi_temp \
    --http-scgi-temp-path=scgi_temp \
    --with-cc-opt="$ARCH_FLAGS" \
    --with-ld-opt="$ARCH_FLAGS" \
    --with-pcre="../pcre2-$PCRE2_VERSION" \
    --with-pcre-opt="$ARCH_FLAGS" \
    --with-pcre-jit \
    --with-zlib="../zlib-$ZLIB_VERSION" \
    --with-zlib-opt="$ARCH_FLAGS" \
    --with-http_realip_module \
    --with-threads
  make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
)

BIN="$SRC/objs/nginx"
if [[ "$CROSS" == 1 ]]; then
  lipo "$BIN" -thin "$LIPO_ARCH" -output "$BIN.thin"
  mv "$BIN.thin" "$BIN"
fi
lipo -archs "$BIN"

echo "Checking dynamic dependencies (only libSystem is allowed) …"
otool -L "$BIN"
if otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -v '^/usr/lib/libSystem\.B\.dylib$' | grep -q .; then
  echo "nginx links something other than libSystem — not relocatable" >&2
  exit 1
fi

# --- lay out the package ----------------------------------------------------
mkdir -p "$PKG/sbin" "$PKG/conf" \
  "$PKG/share/licenses/nginx" "$PKG/share/licenses/pcre2" "$PKG/share/licenses/zlib"
cp "$BIN" "$PKG/sbin/nginx"
chmod 0755 "$PKG/sbin/nginx"
for f in mime.types fastcgi_params fastcgi.conf; do
  cp "$SRC/conf/$f" "$PKG/conf/$f"
done
cp "$SRC/LICENSE" "$PKG/share/licenses/nginx/LICENSE"
cp "$PCRE2_SRC/LICENCE.md" "$PKG/share/licenses/pcre2/LICENCE.md" 2>/dev/null \
  || cp "$PCRE2_SRC/LICENCE" "$PKG/share/licenses/pcre2/LICENCE"
cp "$ZLIB_SRC/LICENSE" "$PKG/share/licenses/zlib/LICENSE" 2>/dev/null \
  || sed -n '/Copyright/,/madler@alumni.caltech.edu/p' "$ZLIB_SRC/README" > "$PKG/share/licenses/zlib/LICENSE"
codesign --force --sign - "$PKG/sbin/nginx"

if [[ "$CROSS" == 0 ]]; then
  echo "Smoke-testing from a copy outside the build prefix …"
  SMOKE="$(mktemp -d)"
  cp -R "$PKG" "$SMOKE/unpacked"
  "$SMOKE/unpacked/sbin/nginx" -V
  mkdir -p "$SMOKE/run"
  cat > "$SMOKE/run/nginx.conf" <<EOF
worker_processes 1;
error_log "$SMOKE/run/error.log" warn;
pid nginx.pid;
events { worker_connections 16; }
http {
  access_log "$SMOKE/run/access.log";
  server {
    listen 127.0.0.1:18080;
    location / { rewrite ^/a(.*)\$ /b\$1 last; return 204; }
    gzip on;
    set_real_ip_from 127.0.0.1;
    real_ip_header X-Forwarded-For;
    location ~ \.php\$ { fastcgi_pass 127.0.0.1:9; }
  }
}
EOF
  "$SMOKE/unpacked/sbin/nginx" -p "$SMOKE/run" -c "$SMOKE/run/nginx.conf" -t 2>&1 | tee "$SMOKE/t.out"
  if grep -q 'alert\|emerg' "$SMOKE/t.out"; then
    echo "nginx -t reported an alert from a relocated path" >&2
    exit 1
  fi
  rm -rf "$SMOKE"
else
  echo "NOT smoke-tested: $MANIFEST_ARCH binary built on a $HOST_ARCH host."
fi

ARCHIVE="$OUT_DIR/nginx-$NGINX_VERSION-$MANIFEST_ARCH.tar.zst"
echo "Repacking to $ARCHIVE …"
tar -C "$PKG" --zstd -cf "$ARCHIVE" .
shasum -a 256 "$ARCHIVE" | awk '{print $1}' > "$ARCHIVE.sha256"
wc -c < "$ARCHIVE" | tr -d ' ' > "$ARCHIVE.size"

if strings -a "$PKG/sbin/nginx" | grep -F "$ROOT"; then
  echo "the binary embeds a build-machine path (above)" >&2
  exit 1
fi

echo "$ARCHIVE"
