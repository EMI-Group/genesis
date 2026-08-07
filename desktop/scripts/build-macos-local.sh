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
cargo tauri build "$@"
