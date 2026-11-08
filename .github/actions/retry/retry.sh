#!/usr/bin/env bash
# Bounded exponential-backoff retry wrapper for transient network failures
# (5xx responses, connection resets) on GitHub-hosted runners.
#
# Usage:
#   bash retry.sh <command> [args...]        # run once, retrying on failure
#   source retry.sh; retry <command> [...]   # reuse the retry() function
#
# Environment: RETRY_ATTEMPTS (default 5), RETRY_DELAY (default 10 s,
# doubled per attempt), RETRY_MAX_DELAY (default 60 s).
# Baseline-bash compatible (macOS ships bash 3.2) and works in Git Bash on
# Windows — no arrays, no associative arrays.
retry() {
  if [ "$#" -eq 0 ]; then
    echo "retry: no command given" >&2
    return 2
  fi
  local attempts="${RETRY_ATTEMPTS:-5}"
  local delay="${RETRY_DELAY:-10}"
  local max_delay="${RETRY_MAX_DELAY:-60}"
  local attempt=1
  local status=0
  while :; do
    if "$@"; then
      return 0
    else
      status=$?
    fi
    if [ "${attempt}" -ge "${attempts}" ]; then
      echo "::error::retry: command failed after ${attempt} attempt(s) (exit ${status}): $*" >&2
      return "${status}"
    fi
    echo "::warning::retry: attempt ${attempt}/${attempts} failed (exit ${status}): $* — retrying in ${delay}s" >&2
    sleep "${delay}"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    if [ "${delay}" -gt "${max_delay}" ]; then
      delay="${max_delay}"
    fi
  done
}

# Only auto-run when executed, never when sourced (the macOS notarization step
# sources this file to reuse retry()).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  retry "$@"
fi
