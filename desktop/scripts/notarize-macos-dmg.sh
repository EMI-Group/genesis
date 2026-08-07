#!/usr/bin/env bash
# Submit a signed DMG to Apple's notary service and staple its ticket.
# Supports App Store Connect API key or Apple ID authentication.

set -euo pipefail

DMG_PATH="${1:-}"

[[ -f "${DMG_PATH}" ]] || {
  echo "DMG not found: ${DMG_PATH}" >&2
  exit 1
}

notary_args=()
if [[ -n "${APPLE_API_ISSUER:-}" && -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_KEY_PATH:-}" ]]; then
  [[ -f "${APPLE_API_KEY_PATH}" ]] || {
    echo "App Store Connect API key not found: ${APPLE_API_KEY_PATH}" >&2
    exit 1
  }
  notary_args=(
    --issuer "${APPLE_API_ISSUER}"
    --key-id "${APPLE_API_KEY}"
    --key "${APPLE_API_KEY_PATH}"
  )
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  notary_args=(
    --apple-id "${APPLE_ID}"
    --password "${APPLE_PASSWORD}"
    --team-id "${APPLE_TEAM_ID}"
  )
else
  echo "notarization credentials are incomplete" >&2
  echo "set APPLE_API_ISSUER, APPLE_API_KEY, and APPLE_API_KEY_PATH" >&2
  echo "or set APPLE_ID, APPLE_PASSWORD, and APPLE_TEAM_ID" >&2
  exit 1
fi

echo "submitting ${DMG_PATH} for notarization"
xcrun notarytool submit "${DMG_PATH}" "${notary_args[@]}" --wait

echo "stapling notarization ticket to ${DMG_PATH}"
xcrun stapler staple "${DMG_PATH}"
