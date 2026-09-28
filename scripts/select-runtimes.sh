#!/usr/bin/env bash
# Resolve the release workflow's `runtimes` input into one `<id>=true|false`
# line per runtime plus `list=<canonical comma list>`, appended to
# $GITHUB_OUTPUT (stdout when unset). Refuses an unknown id, an empty
# selection, and a selected runtime whose pinned SHA-256 input is missing, so
# the failure lands here instead of on a macOS runner.
#
#   RUNTIMES      comma list, or "all" (default)
#   REDIS_SHA256  required when redis is selected
#   MYSQL_SHA256  required when mysql is selected
set -euo pipefail

ALL="php node ollama postgres redis mysql nginx httpd"

sel="${RUNTIMES:-all}"
sel="${sel//[[:space:]]/}"
[[ "$sel" == all ]] && sel="${ALL// /,}"

IFS=, read -r -a wanted <<< "$sel"
for w in ${wanted[@]+"${wanted[@]}"}; do
  [[ -n "$w" ]] || continue
  case " $ALL " in
    *" $w "*) ;;
    *) echo "::error::unknown runtime '$w' in runtimes input (known: ${ALL// /, })" >&2; exit 2 ;;
  esac
done

is_selected() { case ",$sel," in *",$1,"*) return 0 ;; esac; return 1; }

need_sha() { # runtime input-name value
  is_selected "$1" || return 0
  if [[ ! "$3" =~ ^[0-9a-f]{64}$ ]]; then
    echo "::error::$1 is selected, so $2 must be its 64-character lowercase SHA-256 (got '${3}')" >&2
    return 1
  fi
}
bad=0
need_sha redis redis_sha256 "${REDIS_SHA256:-}" || bad=1
need_sha mysql mysql_sha256_aarch64 "${MYSQL_SHA256:-}" || bad=1
[[ $bad == 0 ]] || exit 2

list=""
lines=""
for r in $ALL; do
  if is_selected "$r"; then
    lines+="$r=true"$'\n'
    list+="${list:+,}$r"
  else
    lines+="$r=false"$'\n'
  fi
done
if [[ -z "$list" ]]; then
  echo "::error::runtimes input selects nothing" >&2
  exit 2
fi

printf '%slist=%s\n' "$lines" "$list" >> "${GITHUB_OUTPUT:-/dev/stdout}"
