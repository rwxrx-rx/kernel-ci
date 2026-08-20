#!/usr/bin/env bash
# scripts/load_manifest.sh <file1> [file2 ...]
#
# $GITHUB_ENV is NOT a bash file — GitHub Actions just takes everything
# after the first `=` on each line as the literal value. That means
# naively grepping a bash-syntax manifest (manifest/*.env) straight into
# $GITHUB_ENV keeps the quote characters and any trailing `# comment`
# as part of the value — e.g. PROTON_CLANG_REPO ends up literally
# containing a leading `"` and everything after `# ...` on that line.
#
# This script sources each file as real bash instead (which handles
# quoting and comments correctly), then re-exports the resulting
# variables into $GITHUB_ENV using the <<DELIM heredoc form, which is
# safe for both single- and multi-line values regardless of what
# characters they contain.
set -euo pipefail
: "${GITHUB_ENV:?}"

for f in "$@"; do
  # shellcheck disable=SC1090
  source "$f"
  # Top-level `KEY=` assignments in this file, in order, deduplicated.
  mapfile -t KEYS < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$f" | sed 's/=$//' | sort -u)

  # Fail loud, not silent: if a manifest file yields zero KEY=value
  # matches, something is genuinely wrong with that file (empty,
  # corrupted, indented differently than expected, wrong line endings,
  # ...) — continuing quietly here is exactly what let device.env go
  # missing without a trace last time, surfacing only much later as a
  # confusing "empty string is not a valid path" from git.
  if [ "${#KEYS[@]}" -eq 0 ]; then
    echo "::error::$f matched zero KEY=value lines — refusing to continue silently. Check this file's content (empty file? unexpected indentation? wrong line endings?)."
    exit 1
  fi

  for key in "${KEYS[@]}"; do
    value="${!key:-}"
    delim="MANIFEST_EOF_$$_${key}"
    {
      echo "${key}<<${delim}"
      echo "${value}"
      echo "${delim}"
    } >> "$GITHUB_ENV"
  done
done
