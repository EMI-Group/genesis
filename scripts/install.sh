#!/bin/sh
#
# install.sh — one-line installer for the headless Genesis server.
#
# Usage:
#   curl -LsSf https://genesis.evox.group/dl/install.sh | sh
#   curl -LsSf https://genesis.evox.group/dl/install.sh | sh -s -- --dir ~/genesis
#
# Downloads the `genesis_server` release tarball for this machine, installs it
# under ~/.local/share/genesis/server and links ~/.local/bin/genesis to it.
#
# Usage: sh install.sh [--dir <path>] [--force] [--help]
#
# Environment overrides:
#   GENESIS_INSTALL_DIR             install directory
#                                   (default: ~/.local/share/genesis/server)
#   GENESIS_VERSION                 release tag to pin (default: latest)
#   GENESIS_DOWNLOAD_BASE           primary download base
#                                   (default: https://genesis.evox.group/dl)
#   GENESIS_DOWNLOAD_FALLBACK_BASE  fallback download base
#                                   (default: https://github.com/EMI-Group/genesis/releases)
#
# This script never reads stdin, so `curl ... | sh` is safe.
#
set -eu

DEFAULT_INSTALL_DIR="${HOME}/.local/share/genesis/server"
DEFAULT_DOWNLOAD_BASE="https://genesis.evox.group/dl"
DEFAULT_DOWNLOAD_FALLBACK_BASE="https://github.com/EMI-Group/genesis/releases"
# The `genesis` launcher is always linked here (per the install contract).
LINK_DIR="${HOME}/.local/bin"

# ─── Output helpers ──────────────────────────────────────────────────────
info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Install the headless Genesis server.

Usage:
  curl -LsSf https://genesis.evox.group/dl/install.sh | sh
  sh install.sh [options]

Options:
  --dir <path>  Install directory (default: ~/.local/share/genesis/server)
  -f, --force   Reinstall even if this version is already installed, and
                overwrite a non-Genesis directory at the install path
  -h, --help    Show this help and exit

Environment:
  GENESIS_INSTALL_DIR             Install directory (--dir wins)
  GENESIS_VERSION                 Release tag to pin (default: latest)
  GENESIS_DOWNLOAD_BASE           Primary download base
                                  (default: https://genesis.evox.group/dl)
  GENESIS_DOWNLOAD_FALLBACK_BASE  Fallback download base
                                  (default: https://github.com/EMI-Group/genesis/releases)

After installing:
  genesis          Run the server in the foreground
  genesis start    Run the server as a service (systemd-run / launchd)
  genesis status   Show the service state
  genesis logs     Follow the server log
  genesis stop     Stop the service

Supported platforms: Linux x64, Linux arm64, macOS arm64.
Windows is not supported by this installer — use the Genesis desktop app.
EOF
}

# ─── Argument parsing ────────────────────────────────────────────────────
INSTALL_DIR="${GENESIS_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
VERSION="${GENESIS_VERSION:-latest}"
DOWNLOAD_BASE="${GENESIS_DOWNLOAD_BASE:-$DEFAULT_DOWNLOAD_BASE}"
FALLBACK_BASE="${GENESIS_DOWNLOAD_FALLBACK_BASE:-$DEFAULT_DOWNLOAD_FALLBACK_BASE}"
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --dir)
      [ $# -ge 2 ] || die "--dir requires a path"
      INSTALL_DIR="$2"
      shift 2
      ;;
    --dir=*)
      INSTALL_DIR="${1#--dir=}"
      shift
      ;;
    -f | --force)
      FORCE=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1 (try --help)"
      ;;
    *)
      die "unexpected argument: $1 (try --help)"
      ;;
  esac
done

[ $# -eq 0 ] || die "unexpected argument: $1 (try --help)"
[ -n "$INSTALL_DIR" ] || die "install directory must not be empty"
# Normalize a trailing slash, but never turn "/" into "".
INSTALL_DIR="${INSTALL_DIR%/}"
[ -n "$INSTALL_DIR" ] || INSTALL_DIR="/"
# Bases are joined with "/" below, so drop any trailing slash from user input.
DOWNLOAD_BASE="${DOWNLOAD_BASE%/}"
FALLBACK_BASE="${FALLBACK_BASE%/}"

# ─── Platform detection ──────────────────────────────────────────────────
detect_platform() {
  _os="$(uname -s 2>/dev/null || printf 'unknown')"
  case "$_os" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT | windows*)
      die "Windows is not supported by this installer.
The headless Genesis server ships POSIX builds only (Linux x64, Linux arm64,
macOS arm64). On Windows, use the Genesis desktop app instead:
https://genesis.evox.group"
      ;;
    Linux) OS="linux" ;;
    Darwin) OS="darwin" ;;
    *)
      die "unsupported operating system: ${_os}
Available builds: linux_x64, linux_arm64, darwin_arm64.
Windows: use the Genesis desktop app instead."
      ;;
  esac

  _arch="$(uname -m 2>/dev/null || printf 'unknown')"
  case "$_arch" in
    x86_64 | amd64) ARCH="x64" ;;
    aarch64 | arm64) ARCH="arm64" ;;
    *)
      die "unsupported architecture: ${_arch}
Available builds: linux_x64, linux_arm64, darwin_arm64."
      ;;
  esac

  PLATFORM="${OS}_${ARCH}"
  case "$PLATFORM" in
    linux_x64 | linux_arm64 | darwin_arm64) : ;;
    darwin_x64)
      die "no macOS x64 (Intel) build is available.
Available builds: linux_x64, linux_arm64, darwin_arm64.
If this is an Apple Silicon Mac with a Rosetta shell, re-run the installer from
a native arm64 shell: arch -arm64 /bin/sh"
      ;;
    *)
      die "no build available for ${PLATFORM}.
Available builds: linux_x64, linux_arm64, darwin_arm64."
      ;;
  esac

  ASSET="genesis_server_${PLATFORM}.tar.xz"
}

# Two URL builders — one per download source — so the tag/"latest" mapping
# lives in exactly one place each.
proxy_url() { # <asset> -> URL on the genesis.evox.group release proxy
  if [ "$VERSION" = "latest" ]; then
    printf '%s/%s' "$DOWNLOAD_BASE" "$1"
  else
    printf '%s/%s/%s' "$DOWNLOAD_BASE" "$VERSION" "$1"
  fi
}

github_url() { # <asset> -> URL on GitHub Releases
  if [ "$VERSION" = "latest" ]; then
    printf '%s/latest/download/%s' "$FALLBACK_BASE" "$1"
  else
    printf '%s/download/%s/%s' "$FALLBACK_BASE" "$VERSION" "$1"
  fi
}

detect_platform

# ─── Temp workspace ──────────────────────────────────────────────────────
TMP_DIR=""
STAGING_DIR=""
cleanup() {
  if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ─── Existing install checks ─────────────────────────────────────────────
is_genesis_install() { [ -f "${INSTALL_DIR}/bin/genesis_server" ]; }

# Refuse to swap out a directory we did not create (e.g. `--dir ~` by mistake).
if [ "$FORCE" -eq 0 ] && [ -d "$INSTALL_DIR" ] && ! is_genesis_install; then
  if [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null || true)" ]; then
    die "${INSTALL_DIR} already exists and does not look like a Genesis install
(no bin/genesis_server in it). Refusing to replace it.
Pass --force to overwrite it, or choose a different --dir."
  fi
fi

# Reads the release version from the installed release's start_erl.data
# ("<erts_vsn> <rel_vsn>"), falling back to the requested version.
installed_version() {
  _data="${INSTALL_DIR}/releases/start_erl.data"
  if [ -f "$_data" ]; then
    _vsn="$(awk 'NR == 1 && NF >= 2 { print $2 }' "$_data" 2>/dev/null || true)"
    if [ -n "$_vsn" ]; then
      printf '%s' "$_vsn"
      return 0
    fi
  fi
  printf '%s' "$VERSION"
}

# A re-run upgrades in place, but an already-present *pinned* version is a
# no-op unless --force was given.
if [ "$FORCE" -eq 0 ] && [ "$VERSION" != "latest" ] && is_genesis_install; then
  _current="$(installed_version)"
  if [ "$_current" = "$VERSION" ]; then
    info "Genesis ${VERSION} is already installed at ${INSTALL_DIR}."
    info "Re-run with --force to reinstall."
    SKIP_DOWNLOAD=1
  fi
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/genesis-install.XXXXXX")"
ARCHIVE="${TMP_DIR}/${ASSET}"

# ─── Download ────────────────────────────────────────────────────────────
download() { # <url> <dest>
  if have curl; then
    # -f: fail on HTTP >= 400 (so a 404 is not saved as an HTML error page).
    curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 20 \
      -o "$2" "$1" </dev/null
  elif have wget; then
    wget -q -O "$2" "$1" </dev/null
  else
    die "neither curl nor wget is available; install one of them and re-run."
  fi
}

if [ "${SKIP_DOWNLOAD:-0}" -eq 0 ]; then
  PRIMARY_URL="$(proxy_url "$ASSET")"
  FALLBACK_URL="$(github_url "$ASSET")"

  info "Installing Genesis (${PLATFORM}, ${VERSION})"
  info "Downloading ${ASSET}"

  ASSET_URL=""
  _previous=""
  for _url in "$PRIMARY_URL" "$FALLBACK_URL"; do
    # Skip a duplicated attempt when both bases resolve to the same URL.
    [ "$_url" != "$_previous" ] || continue
    _previous="$_url"
    info "  from ${_url}"
    if download "$_url" "$ARCHIVE"; then
      ASSET_URL="$_url"
      break
    fi
    warn "download failed: ${_url}"
  done

  [ -n "$ASSET_URL" ] || die "could not download ${ASSET}.
Tried:
  ${PRIMARY_URL}
  ${FALLBACK_URL}
The release may not be published yet, or this platform/version may not have an
asset. Check https://github.com/EMI-Group/genesis/releases and your network."

  [ -s "$ARCHIVE" ] || die "downloaded ${ASSET} is empty; the release may not be published yet."

  # ─── Optional checksum verification ────────────────────────────────────
  # A missing .sha256 is not an error: older releases simply do not publish one.
  CHECKSUM_FILE="${TMP_DIR}/${ASSET}.sha256"
  if download "${ASSET_URL}.sha256" "$CHECKSUM_FILE" >/dev/null 2>&1; then
    _expected="$(awk 'NR == 1 { print $1 }' "$CHECKSUM_FILE" 2>/dev/null || true)"
    if [ "${#_expected}" -eq 64 ]; then
      if have sha256sum; then
        _actual="$(sha256sum "$ARCHIVE" | awk '{ print $1 }')"
      elif have shasum; then
        _actual="$(shasum -a 256 "$ARCHIVE" | awk '{ print $1 }')"
      else
        _actual=""
        info "No sha256sum/shasum found; skipping checksum verification."
      fi
      if [ -n "$_actual" ] && [ "$_actual" != "$_expected" ]; then
        die "checksum mismatch for ${ASSET}.
  expected: ${_expected}
  actual:   ${_actual}
The download may be corrupt or tampered with. Delete the cache and retry."
      fi
      if [ -n "$_actual" ]; then
        info "Checksum verified."
      fi
    else
      info "Published checksum file is malformed; skipping verification."
    fi
  else
    info "No published checksum for ${ASSET}; skipping verification."
  fi

  # ─── Extract ───────────────────────────────────────────────────────────
  have tar || die "tar is required but was not found in PATH."
  info "Extracting ${ASSET}"
  if ! tar -xJf "$ARCHIVE" -C "$TMP_DIR" 2>"${TMP_DIR}/tar.err"; then
    sed 's/^/  /' "${TMP_DIR}/tar.err" >&2 || true
    die "failed to extract ${ASSET}.
The download may be corrupt (re-run the installer to fetch it again), or this
tar lacks .tar.xz support:
  Debian/Ubuntu: sudo apt-get install -y xz-utils
  Fedora/RHEL:   sudo dnf install -y xz
  macOS:         brew install xz"
  fi

  # The tarball root directory is `genesis_server/`; tolerate a flat archive too.
  if [ -f "${TMP_DIR}/genesis_server/bin/genesis_server" ]; then
    SRC_DIR="${TMP_DIR}/genesis_server"
  elif [ -f "${TMP_DIR}/bin/genesis_server" ]; then
    SRC_DIR="${TMP_DIR}"
  else
    die "the extracted archive does not contain bin/genesis_server — ${ASSET} looks wrong."
  fi

  # ─── Install (stage next to the target, then swap) ─────────────────────
  INSTALL_PARENT="$(dirname "$INSTALL_DIR")"
  [ -n "$INSTALL_PARENT" ] || INSTALL_PARENT="/"
  mkdir -p "$INSTALL_PARENT"
  STAGING_DIR="$(mktemp -d "${INSTALL_PARENT%/}/.genesis-install.XXXXXX")"
  cp -R "${SRC_DIR}/." "${STAGING_DIR}/"
  [ -f "${STAGING_DIR}/bin/genesis_server" ] ||
    die "staged install is incomplete (bin/genesis_server missing)."

  info "Installing to ${INSTALL_DIR}"
  OLD_DIR=""
  if [ -e "$INSTALL_DIR" ] || [ -L "$INSTALL_DIR" ]; then
    # Move the old tree aside first; it is only deleted once the new one is in.
    OLD_DIR="${INSTALL_DIR}.old.$$"
    rm -rf "$OLD_DIR"
    mv "$INSTALL_DIR" "$OLD_DIR"
  fi
  if ! mv "$STAGING_DIR" "$INSTALL_DIR"; then
    if [ -n "$OLD_DIR" ]; then
      mv "$OLD_DIR" "$INSTALL_DIR" || warn "could not restore the previous install from ${OLD_DIR}"
    fi
    die "failed to move the new install into ${INSTALL_DIR}"
  fi
  # Consumed by the swap: stop the exit trap from deleting the live install.
  STAGING_DIR=""
  if [ -n "$OLD_DIR" ]; then
    rm -rf "$OLD_DIR"
  fi

  # Make sure the launchers are executable even if the tarball lost the bits.
  for _file in "${INSTALL_DIR}"/bin/*; do
    if [ -f "$_file" ]; then
      chmod +x "$_file"
    fi
  done
fi

# ─── Link `genesis` onto the user's PATH ─────────────────────────────────
LINK_PATH="${LINK_DIR}/genesis"
mkdir -p "$LINK_DIR"
# Only ever replace a symlink; a regular file of the user's own is left alone.
if [ -L "$LINK_PATH" ]; then
  rm -f "$LINK_PATH"
  ln -s "${INSTALL_DIR}/bin/genesis" "$LINK_PATH"
elif [ -e "$LINK_PATH" ]; then
  warn "${LINK_PATH} exists and is not a symlink; leaving it untouched."
  warn "Remove it (or put ${LINK_DIR} ahead of it in PATH) to use the installed genesis."
else
  ln -s "${INSTALL_DIR}/bin/genesis" "$LINK_PATH"
fi

# ─── Summary ─────────────────────────────────────────────────────────────
printf '\n'
printf 'Genesis %s installed\n' "$(installed_version)"
printf '  Server:  %s\n' "$INSTALL_DIR"
if [ -L "$LINK_PATH" ]; then
  printf '  Command: %s\n' "$LINK_PATH"
else
  printf '  Command: %s\n' "${INSTALL_DIR}/bin/genesis"
fi

case ":${PATH:-}:" in
  *":${LINK_DIR}:"*) ;;
  *)
    printf '\n'
    printf '%s is not on your PATH. Add it:\n' "$LINK_DIR"
    printf '  export PATH="$HOME/.local/bin:$PATH"\n'
    printf 'Then restart your shell (or re-run the export) to use the genesis command.\n'
    ;;
esac

printf '\nNext steps:\n'
printf '  genesis          # run the server in the foreground\n'
printf '  genesis start    # run it as a service (systemd-run / launchd)\n'
printf '  genesis status   # show the service state\n'
printf '  genesis logs     # follow the server log\n'
printf '  genesis stop     # stop the service\n'
printf '\nThen open the dashboard URL printed on boot (default http://127.0.0.1:9999).\n'
