#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="${1:?runtime dir required}"
IDENTITY="${APPLE_SIGNING_IDENTITY:--}"

# With a real Developer ID, sign with a secure timestamp + hardened runtime so
# the archive can be notarized. Without one (`-`), fall back to plain ad-hoc
# signing: arm64 macOS requires every binary be signed to run at all, but
# ad-hoc signing does NOT support `--timestamp`/`--options runtime` (those need
# a real identity + the timestamp service and would fail the build). The app
# verifies the minisign signature and strips the download quarantine itself, so
# ad-hoc-signed managed runtimes still launch.
if [[ "$IDENTITY" == "-" ]]; then
  echo "APPLE_SIGNING_IDENTITY is not set; using plain ad-hoc signing" >&2
fi

find "$RUNTIME_DIR" -type f -perm -111 -print0 | while IFS= read -r -d '' bin; do
  if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$bin"
  else
    codesign --force --timestamp --options runtime --sign "$IDENTITY" "$bin"
  fi
  codesign --verify --strict --verbose=2 "$bin"
done
