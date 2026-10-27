#!/usr/bin/env bash
# Fails unless a packaged PHP runtime carries what Laravel apps need, naming
# every missing item. Usage: verify-php-runtime.sh <pkg dir>
set -euo pipefail

PKG="${1:?usage: verify-php-runtime.sh <pkg dir>}"
PHP="$PKG/bin/php"
FPM="$PKG/sbin/php-fpm"

# Laravel 13's required extensions, plus what the managed runtime promises.
REQUIRED="ctype curl dom fileinfo filter hash mbstring openssl pcre pdo redis session tokenizer xml"

missing=()

check_modules() {
  local label="$1" bin="$2" mods ext
  shift 2
  # -n: judge the compiled-in set, not whatever a host php.ini loads.
  if ! mods="$("$bin" -n -m 2>&1)"; then
    missing+=("$label: '-m' failed: $mods")
    return
  fi
  mods="$(tr '[:upper:]' '[:lower:]' <<<"$mods")"
  for ext in "$@"; do
    # Here-string, not a pipe: with pipefail, grep -q exiting early can
    # SIGPIPE the writer and report a present module as missing.
    grep -qx "$ext" <<<"$mods" || missing+=("$label: $ext")
  done
}

for bin in "$PHP" "$FPM"; do
  [[ -x "$bin" ]] || { echo "verify-php-runtime: $bin is not executable" >&2; exit 1; }
done

# readline is a CLI-only extension in php-src (it never builds into php-fpm),
# so it is required of bin/php alone.
# shellcheck disable=SC2086
check_modules "php" "$PHP" $REQUIRED readline
# shellcheck disable=SC2086
check_modules "php-fpm" "$FPM" $REQUIRED

# Presence of mbstring does not imply mbregex; check the functions apps call.
# shellcheck disable=SC2016 # PHP source, not shell
if ! out="$("$PHP" -n -r '
  $checks = [
    "mb_split (mbregex)" => function_exists("mb_split"),
    "Redis class (redis)" => class_exists("Redis"),
    "readline()" => function_exists("readline"),
  ];
  foreach ($checks as $name => $ok) { if (!$ok) { echo $name, "\n"; } }
' 2>&1)"; then
  missing+=("php: -r probe failed: $out")
else
  while IFS= read -r line; do
    [[ -n "$line" ]] && missing+=("php: $line")
  done <<<"$out"
fi

if ((${#missing[@]})); then
  echo "verify-php-runtime: $PKG is missing:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi
echo "verify-php-runtime: ok ($PKG)"
