#!/usr/bin/env bash
# Creates a fresh Laravel app with the packaged PHP and serves one request
# through the packaged php-fpm. Usage: smoke-laravel.sh <pkg dir>
# Needs composer and cgi-fcgi (Homebrew `fcgi`) on PATH.
set -euo pipefail

PKG="${1:?usage: smoke-laravel.sh <pkg dir>}"
case "$PKG" in /*) ;; *) PKG="$PWD/$PKG" ;; esac
PHP="$PKG/bin/php"
FPM="$PKG/sbin/php-fpm"
COMPOSER="$(command -v composer)"
PORT="${SMOKE_FPM_PORT:-9187}"

TMP="$(mktemp -d)"
FPM_PID=""
cleanup() {
  [[ -n "$FPM_PID" ]] && kill "$FPM_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Run composer under the packaged PHP so its scripts (@php artisan ...) and the
# platform check see this runtime, not the host's.
composer_pkg() { "$PHP" -c "$PKG/etc/php.ini" "$COMPOSER" --no-interaction "$@"; }

composer_pkg create-project --prefer-dist laravel/laravel "$TMP/app"
cd "$TMP/app"
"$PHP" -c "$PKG/etc/php.ini" artisan about
composer_pkg check-platform-reqs

cat > "$TMP/fpm.conf" <<CONF
[global]
error_log = $TMP/fpm.log
daemonize = no

[www]
listen = 127.0.0.1:$PORT
pm = static
pm.max_children = 2
catch_workers_output = yes
CONF

"$FPM" -c "$PKG/etc/php.ini" -y "$TMP/fpm.conf" &
FPM_PID=$!

request() {
  SCRIPT_FILENAME="$TMP/app/public/index.php" \
  SCRIPT_NAME=/index.php \
  DOCUMENT_ROOT="$TMP/app/public" \
  REQUEST_METHOD=GET \
  REQUEST_URI=/ \
  QUERY_STRING='' \
  SERVER_NAME=localhost \
  SERVER_PORT=80 \
  SERVER_PROTOCOL=HTTP/1.1 \
  GATEWAY_INTERFACE=CGI/1.1 \
  REMOTE_ADDR=127.0.0.1 \
  cgi-fcgi -bind -connect "127.0.0.1:$PORT"
}

resp=""
for _ in $(seq 1 20); do
  if resp="$(request 2>&1)" && [[ -n "$resp" ]]; then break; fi
  kill -0 "$FPM_PID" 2>/dev/null || { cat "$TMP/fpm.log" >&2; echo "php-fpm exited" >&2; exit 1; }
  sleep 1
done

# FPM sends a Status header only for non-200 responses.
head="$(sed -n '1,/^\r\{0,1\}$/p' <<<"$resp")"
if [[ -z "$resp" ]] || grep -qi '^Status:' <<<"$head" || ! grep -q 'Laravel' <<<"$resp"; then
  echo "php-fpm request failed:" >&2
  printf '%s\n' "$head" >&2
  cat "$TMP/fpm.log" >&2 || true
  cat storage/logs/laravel.log >&2 2>/dev/null || true
  exit 1
fi
echo "smoke-laravel: php-fpm served the Laravel welcome page"
