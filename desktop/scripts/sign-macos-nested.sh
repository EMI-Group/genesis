#!/usr/bin/env bash
# Sign every Mach-O under a directory (Developer ID + timestamp + hardened runtime).
# Required before Apple notarization when embedding an Elixir release in Resources —
# tauri-cli does not recurse into bundle.resources for codesign.
#
# Usage:
#   APPLE_SIGNING_IDENTITY='...' ./desktop/scripts/sign-macos-nested.sh
#   APPLE_SIGNING_IDENTITY='...' ./desktop/scripts/sign-macos-nested.sh path/to/genesis-backend
#
# Requires APPLE_SIGNING_IDENTITY in the environment (build-macos-local.sh exports it).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-${SCRIPT_DIR}/../src-tauri/resources/genesis-backend}"

[[ -d "${ROOT}" ]] || {
  echo "directory not found: ${ROOT}" >&2
  exit 1
}

[[ -n "${APPLE_SIGNING_IDENTITY:-}" ]] || {
  echo "APPLE_SIGNING_IDENTITY is not set" >&2
  exit 1
}

xattr -cr "${ROOT}"

signed=0
while IFS= read -r -d '' path; do
  case "$(file -b "${path}")" in
    Mach-O*)
      echo "signing ${path}"
      codesign --force --options runtime --timestamp \
        --sign "${APPLE_SIGNING_IDENTITY}" \
        "${path}"
      signed=$((signed + 1))
      ;;
  esac
done < <(find "${ROOT}" -type f -print0)

[[ "${signed}" -gt 0 ]] || {
  echo "no Mach-O files found under ${ROOT}" >&2
  exit 1
}

echo "signed ${signed} Mach-O file(s) under ${ROOT}"
