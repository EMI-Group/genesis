#!/usr/bin/env bash
# Verify the signatures, notarization tickets, and Gatekeeper assessments of
# the final macOS application and optional DMG artifacts.

set -euo pipefail

APP_PATH="${1:-}"
DMG_PATH="${2:-}"

[[ -d "${APP_PATH}" ]] || {
  echo "application bundle not found: ${APP_PATH}" >&2
  exit 1
}

echo "verifying application signature"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

echo "validating application notarization ticket"
xcrun stapler validate "${APP_PATH}"

echo "assessing application with Gatekeeper"
spctl --assess --type execute --verbose=4 "${APP_PATH}"

if [[ -n "${DMG_PATH}" ]]; then
  [[ -f "${DMG_PATH}" ]] || {
    echo "DMG not found: ${DMG_PATH}" >&2
    exit 1
  }

  echo "verifying DMG signature"
  codesign --verify --strict --verbose=2 "${DMG_PATH}"

  echo "validating DMG notarization ticket"
  xcrun stapler validate "${DMG_PATH}"

  echo "assessing DMG with Gatekeeper"
  spctl --assess --type open --context context:primary-signature \
    --verbose=4 "${DMG_PATH}"
fi
