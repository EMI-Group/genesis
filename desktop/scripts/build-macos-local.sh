#!/usr/bin/env bash
# Local macOS desktop build — Elixir release → Tauri bundle
#
#   cp desktop/scripts/.env.macos.example desktop/scripts/.env.macos
#   ./desktop/scripts/build-macos-local.sh
#   ./desktop/scripts/build-macos-local.sh --bundles dmg
#   ./desktop/scripts/build-macos-local.sh --bundles app,dmg
#
# Default (no args): --bundles app
# Output under: desktop/src-tauri/target/release/bundle/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TAURI_DIR="${REPO_ROOT}/desktop/src-tauri"
ENV_FILE="${SCRIPT_DIR}/.env.macos"

cd "${REPO_ROOT}"

[[ -f "${ENV_FILE}" ]] || {
  echo "missing ${ENV_FILE} — copy desktop/scripts/.env.macos.example first" >&2
  exit 1
}

cargo tauri --version >/dev/null 2>&1 || {
  echo "cargo tauri not found — run: cargo install tauri-cli --version \"^2.0\" --locked" >&2
  exit 1
}

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

[[ -n "${APPLE_SIGNING_IDENTITY:-}" ]] || {
  echo "APPLE_SIGNING_IDENTITY missing in ${ENV_FILE}" >&2
  exit 1
}

if [[ -n "${APPLE_API_ISSUER:-}" || -n "${APPLE_API_KEY:-}" || -n "${APPLE_API_KEY_PATH:-}" ]]; then
  [[ -n "${APPLE_API_ISSUER:-}" && -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_KEY_PATH:-}" ]] || {
    echo "App Store Connect API credentials are incomplete in ${ENV_FILE}" >&2
    exit 1
  }
  [[ -f "${APPLE_API_KEY_PATH}" ]] || {
    echo "App Store Connect API key not found: ${APPLE_API_KEY_PATH}" >&2
    exit 1
  }
  unset APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID
elif [[ -n "${APPLE_ID:-}" || -n "${APPLE_PASSWORD:-}" || -n "${APPLE_TEAM_ID:-}" ]]; then
  [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]] || {
    echo "Apple ID notarization credentials are incomplete in ${ENV_FILE}" >&2
    exit 1
  }
  unset APPLE_API_ISSUER APPLE_API_KEY APPLE_API_KEY_PATH
else
  echo "notarization credentials missing in ${ENV_FILE}" >&2
  exit 1
fi

mix deps.get
mix assets.setup
mix assets.deploy

MIX_ENV=prod mix release genesis_desktop --overwrite

rm -rf "${TAURI_DIR}/resources/genesis-backend"
cp -a _build/prod/rel/genesis_desktop "${TAURI_DIR}/resources/genesis-backend"

# Pre-sign Elixir/ERTS Mach-O files so notarization accepts nested Resources.
# tauri-cli only auto-signs MacOS/Frameworks/… — not deep bundle.resources.
"${SCRIPT_DIR}/sign-macos-nested.sh" "${TAURI_DIR}/resources/genesis-backend"

cd "${TAURI_DIR}"
(( $# == 0 )) && set -- --bundles app

bundle_selection=""
expect_bundle_selection=false
for arg in "$@"; do
  if [[ "${expect_bundle_selection}" == true ]]; then
    bundle_selection="${arg}"
    expect_bundle_selection=false
  elif [[ "${arg}" == "--bundles" ]]; then
    expect_bundle_selection=true
  elif [[ "${arg}" == --bundles=* ]]; then
    bundle_selection="${arg#--bundles=}"
  fi
done

[[ "${expect_bundle_selection}" == false ]] || {
  echo "--bundles requires a value" >&2
  exit 1
}

# Without an explicit filter, Tauri uses the bundle targets from tauri.conf.json.
[[ -n "${bundle_selection}" ]] || bundle_selection="app,dmg"
case ",${bundle_selection}," in
  *,dmg,*) build_dmg=true ;;
  *) build_dmg=false ;;
esac

cargo tauri build "$@"

shopt -s nullglob
APP_BUNDLES=("${TAURI_DIR}/target/release/bundle/macos/"*.app)
[[ "${#APP_BUNDLES[@]}" -eq 1 ]] || {
  echo "expected one application bundle, found ${#APP_BUNDLES[@]}" >&2
  exit 1
}

if [[ "${build_dmg}" == true ]]; then
  DMG_BUNDLES=("${TAURI_DIR}/target/release/bundle/dmg/"*.dmg)
  [[ "${#DMG_BUNDLES[@]}" -eq 1 ]] || {
    echo "expected one DMG, found ${#DMG_BUNDLES[@]}" >&2
    exit 1
  }
  "${SCRIPT_DIR}/notarize-macos-dmg.sh" "${DMG_BUNDLES[0]}"
  "${SCRIPT_DIR}/verify-macos-artifacts.sh" \
    "${APP_BUNDLES[0]}" "${DMG_BUNDLES[0]}"
else
  "${SCRIPT_DIR}/verify-macos-artifacts.sh" "${APP_BUNDLES[0]}"
fi
