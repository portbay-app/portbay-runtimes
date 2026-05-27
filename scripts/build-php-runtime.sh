#!/usr/bin/env bash
set -euo pipefail

PHP_VERSION="${PHP_VERSION:-${1:-8.4.21}}"
OUT_DIR="${OUT_DIR:-${2:-dist}}"
ARCH="${ARCH:-$(uname -m)}"

case "$ARCH" in
  arm64|aarch64) MANIFEST_ARCH="aarch64" ;;
  x86_64|amd64) MANIFEST_ARCH="x86_64" ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.work/php-$PHP_VERSION-$MANIFEST_ARCH"
SPC="$WORK/static-php-cli"
BUILD="$WORK/buildroot"
PKG="$OUT_DIR/php/$PHP_VERSION"
EXTENSIONS="${PHP_EXTENSIONS:-bcmath,bz2,calendar,ctype,curl,dom,exif,fileinfo,filter,gd,iconv,intl,mbstring,mysqli,mysqlnd,opcache,openssl,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,phar,posix,session,simplexml,soap,sockets,sodium,sqlite,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zip,zlib}"

rm -rf "$WORK" "$PKG"
mkdir -p "$WORK" "$PKG/bin" "$PKG/sbin" "$PKG/etc" "$PKG/lib" "$PKG/extensions" "$OUT_DIR"

git clone --depth 1 https://github.com/crazywhalecc/static-php-cli.git "$SPC"
cd "$SPC"
composer install --no-dev --no-interaction --prefer-dist

php bin/spc doctor || true
php bin/spc build:php "$EXTENSIONS" \
  --build-cli \
  --build-fpm \
  --debug=no \
  --dl-with-php="$PHP_VERSION" \
  --dl-prefer-binary \
  --dl-parallel="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

PHP_BIN="$(find "$SPC" -path '*/bin/php' -type f -perm -111 | head -n 1)"
FPM_BIN="$(find "$SPC" -path '*/bin/php-fpm' -type f -perm -111 | head -n 1)"
if [[ -z "$PHP_BIN" || -z "$FPM_BIN" ]]; then
  echo "static-php-cli did not produce php and php-fpm" >&2
  find "$SPC" -maxdepth 4 -type f -perm -111 >&2
  exit 1
fi

cp "$PHP_BIN" "$PKG/bin/php"
cp "$FPM_BIN" "$PKG/sbin/php-fpm"
chmod 0755 "$PKG/bin/php" "$PKG/sbin/php-fpm"

cat > "$PKG/etc/php.ini" <<'INI'
; PortBay managed PHP runtime defaults.
date.timezone = UTC
memory_limit = 512M
upload_max_filesize = 64M
post_max_size = 64M
display_errors = On
log_errors = On
opcache.enable = 1
opcache.enable_cli = 1
INI

"$PKG/bin/php" --version
"$PKG/sbin/php-fpm" --version

ARCHIVE="$OUT_DIR/php-fpm-$PHP_VERSION-$MANIFEST_ARCH.tar.zst"
tar -C "$PKG" --zstd -cf "$ARCHIVE" .
shasum -a 256 "$ARCHIVE" | awk '{print $1}' > "$ARCHIVE.sha256"
wc -c < "$ARCHIVE" | tr -d ' ' > "$ARCHIVE.size"

echo "$ARCHIVE"
