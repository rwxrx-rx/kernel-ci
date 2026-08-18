#!/usr/bin/env bash
# scripts/gen_changelog.sh
# Writes changelog.md (long, for the GitHub Release) and
# changelog_telegram.txt (short, MarkdownV2-escaped, for the bot message).
set -euo pipefail

: "${GITHUB_WORKSPACE:?}"
KERNEL_DIR="${KERNEL_DIR:-$GITHUB_WORKSPACE/kernel}"

KSU_VARIANT="${KSU_VARIANT:-none}"
CLANG_FLAVOR="${CLANG_FLAVOR:-unknown}"
SUSFS_ENABLED="${SUSFS_ENABLED:-false}"
OVERLAYFS_ENABLED="${OVERLAYFS_ENABLED:-false}"
RUN_URL="${RUN_URL:-}"

cd "$KERNEL_DIR"
LAST_COMMITS="$(git log -10 --pretty=format:'- %s (%h)' 2>/dev/null || echo '- (no git history available)')"
HEAD_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

cat > "$GITHUB_WORKSPACE/changelog.md" <<EOF
## ${KERNEL_NAME:-Kernel} for ${CODENAME:-device}

**Build info**
- KernelSU variant: \`${KSU_VARIANT}\`
- susfs4ksu: \`${SUSFS_ENABLED}\` (${SUSFS_TAG:-n/a}, ${SUSFS_BRANCH:-n/a})
- OverlayFS / Mountify: \`${OVERLAYFS_ENABLED}\`
- Toolchain: \`${CLANG_FLAVOR}\`
- Kernel source HEAD: \`${HEAD_SHA}\`

**Recent kernel source commits**
${LAST_COMMITS}

**Workflow run:** ${RUN_URL}
EOF

# Plain text — telegram_notify.sh sends without parse_mode, so no
# escaping needed (and none of this can silently break message delivery).
{
  echo "${KERNEL_NAME:-Kernel} — ${CODENAME:-device}"
  echo ""
  echo "KSU: ${KSU_VARIANT}  susfs: ${SUSFS_ENABLED}  overlayfs: ${OVERLAYFS_ENABLED}"
  echo "Clang: ${CLANG_FLAVOR}  HEAD: ${HEAD_SHA}"
  echo ""
  echo "${LAST_COMMITS}" | head -c 800
} > "$GITHUB_WORKSPACE/changelog_telegram.txt"

echo "Wrote changelog.md and changelog_telegram.txt"
