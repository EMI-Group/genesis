#!/usr/bin/env bash
#
# bundle-vendor.sh — Download/place vendor binaries for the EvoGit desktop release.
#
# This replicates the "Bundle vendor binaries" step from the GitHub Actions
# workflow (.github/workflows/build-desktop.yml), adapted for local NixOS use.
#
# Usage:
#   ./nix/bundle-vendor.sh [--target <rust-triple>] [--vendor-platform <platform>]
#
# Defaults (auto-detected from the current machine):
#   --target           x86_64-unknown-linux-gnu  (or aarch64-unknown-linux-gnu on ARM64)
#   --vendor-platform  linux-x86_64               (or linux-arm64 on ARM64)
#
# The script downloads ripgrep and copies the system git into
#   apps/evo_git/priv/vendor/<vendor-platform>/
#
set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────
RIPGREP_VERSION="15.1.0"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  TARGET="x86_64-unknown-linux-gnu" ; VENDOR_PLATFORM="linux-x86_64" ;;
  aarch64) TARGET="aarch64-unknown-linux-gnu"; VENDOR_PLATFORM="linux-arm64"   ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

# ─── Parse flags ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)           TARGET="$2";           shift 2 ;;
    --vendor-platform)  VENDOR_PLATFORM="$2";  shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ripgrep uses a musl target for Linux to get a fully-static binary.
RG_TARGET="$TARGET"
case "$RG_TARGET" in
  *linux-gnu) RG_TARGET="${RG_TARGET/linux-gnu/linux-musl}" ;;
esac

# ─── Place binaries ──────────────────────────────────────────────────────
VENDOR_DIR="apps/evo_git/priv/vendor/${VENDOR_PLATFORM}"
mkdir -p "$VENDOR_DIR"

echo "==> Target:           $TARGET"
echo "==> Vendor platform:  $VENDOR_PLATFORM"
echo "==> ripgrep target:   $RG_TARGET"
echo "==> Vendor dir:       $VENDOR_DIR"
echo ""

# ─── Download ripgrep ────────────────────────────────────────────────────
RG_ARCHIVE="ripgrep-${RIPGREP_VERSION}-${RG_TARGET}.tar.gz"
RG_URL="https://github.com/BurntSushi/ripgrep/releases/download/${RIPGREP_VERSION}/${RG_ARCHIVE}"
echo "Downloading $RG_URL ..."
curl -fsSL "$RG_URL" -o "/tmp/${RG_ARCHIVE}"
tar -xzf "/tmp/${RG_ARCHIVE}" -C /tmp
cp "/tmp/ripgrep-${RIPGREP_VERSION}-${RG_TARGET}/rg" "$VENDOR_DIR/rg"
echo "  ✓ ripgrep ${RIPGREP_VERSION}"

# ─── Copy system git ─────────────────────────────────────────────────────
GIT_BIN="$(command -v git || true)"
if [[ -z "$GIT_BIN" ]]; then
  echo "  ⚠ git not found in PATH — skipping (ensure it is available at runtime)" >&2
else
  cp "$GIT_BIN" "$VENDOR_DIR/git"
  echo "  ✓ git (from $GIT_BIN)"
fi

chmod +x "$VENDOR_DIR"/*
echo ""
echo "Vendor binaries installed to $VENDOR_DIR"
ls -la "$VENDOR_DIR/"
