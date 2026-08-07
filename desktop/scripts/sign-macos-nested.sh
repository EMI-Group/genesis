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
BEAM_ENTITLEMENTS="${SCRIPT_DIR}/macos-beam.entitlements.plist"

[[ -d "${ROOT}" ]] || {
  echo "directory not found: ${ROOT}" >&2
  exit 1
}

[[ -n "${APPLE_SIGNING_IDENTITY:-}" ]] || {
  echo "APPLE_SIGNING_IDENTITY is not set" >&2
  exit 1
}

[[ -f "${BEAM_ENTITLEMENTS}" ]] || {
  echo "entitlements file not found: ${BEAM_ENTITLEMENTS}" >&2
  exit 1
}

plutil -lint "${BEAM_ENTITLEMENTS}"

xattr -cr "${ROOT}"

signed=0
while IFS= read -r -d '' path; do
  case "$(file -b "${path}")" in
    Mach-O*)
      echo "signing ${path}"
      sign_args=(--force --options runtime --timestamp)
      if [[ "$(basename "${path}")" == "beam.smp" ]]; then
        sign_args+=(--entitlements "${BEAM_ENTITLEMENTS}")
      fi
      codesign "${sign_args[@]}" --sign "${APPLE_SIGNING_IDENTITY}" "${path}"
      codesign --verify --strict --verbose=2 "${path}"
      signed=$((signed + 1))
      ;;
  esac
done < <(find "${ROOT}" -type f -print0)

[[ "${signed}" -gt 0 ]] || {
  echo "no Mach-O files found under ${ROOT}" >&2
  exit 1
}

echo "signed ${signed} Mach-O file(s) under ${ROOT}"
