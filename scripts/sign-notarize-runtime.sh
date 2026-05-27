#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="${1:?runtime dir required}"
IDENTITY="${APPLE_SIGNING_IDENTITY:--}"

if [[ "$IDENTITY" == "-" ]]; then
  echo "APPLE_SIGNING_IDENTITY is not set; using ad-hoc signing" >&2
fi

find "$RUNTIME_DIR" -type f -perm -111 -print0 | while IFS= read -r -d '' bin; do
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$bin"
  codesign --verify --strict --verbose=2 "$bin"
done
