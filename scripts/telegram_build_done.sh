#!/usr/bin/env bash
# scripts/telegram_build_done.sh
# Requires ZIP_PATH / ZIP_NAME in env (from package-anykernel's outputs)
# plus everything build-kernel.yml already exports (DEVICE_NAME, CODENAME,
# KERNEL_NAME, KSU_VARIANT, KERNEL_DIR, KERNEL_REPO, SUSFS_ENABLED,
# OVERLAYFS_ENABLED, FEATURE_*).
set -uo pipefail
: "${TELEGRAM_BOT_TOKEN:?}"
: "${TELEGRAM_CHAT_ID:?}"
: "${ZIP_PATH:?}"
: "${ZIP_NAME:?}"
: "${GITHUB_WORKSPACE:?}"
source "$GITHUB_WORKSPACE/scripts/telegram_lib.sh"

KSU_NAME=$(ksu_friendly_name "${KSU_VARIANT:-none}")
KERNEL_DIR="${KERNEL_DIR:-$GITHUB_WORKSPACE/kernel}"

COMMITS=$( (cd "$KERNEL_DIR" && git log -5 --abbrev=12 --pretty=format:"• %h - %s (%cr) <%an>") 2>/dev/null)
[ -z "$COMMITS" ] && COMMITS="• (no git history available)"

HEAD_SHA=$(cd "$KERNEL_DIR" && git rev-parse HEAD 2>/dev/null || echo "")
COMMIT_LINK="${KERNEL_REPO:-}/commit/${HEAD_SHA}"

SIZE=$(du -h "$ZIP_PATH" 2>/dev/null | cut -f1)
SHA256=$(sha256sum "$ZIP_PATH" 2>/dev/null | cut -d' ' -f1)

TEXT="⚡ ${KERNEL_NAME:-Kernel}-${KSU_NAME} Kernel Ready!

📱 Device: ${DEVICE_NAME:-unknown} (${CODENAME:-unknown})
⚙️ KSU Engine: ${KSU_NAME}

🛠️ Active Features:
• KernelSU Engine: ${KSU_NAME}
• SUSFS Anti-Detection: $(icon "${SUSFS_ENABLED:-false}")
• OverlayFS + Mountify: $(icon "${OVERLAYFS_ENABLED:-false}")
• Baseband-Guard: $(icon "${FEATURE_BASEBAND_GUARD:-false}")
• ThinLTO & -O3: $(icon "${FEATURE_THINLTO_O3:-false}")
• WireGuard: $(icon "${FEATURE_WIREGUARD:-false}")
• F2FS Optimizations: $(icon "${FEATURE_F2FS_OPT:-false}")
• ZRAM ZSTD: $(icon "${FEATURE_ZRAM_ZSTD:-false}")
• TCP BBR: $(icon "${FEATURE_TCP_BBR:-false}")
• TCP Westwood: $(icon "${FEATURE_TCP_WESTWOOD:-false}")
• TTL Spoofing: $(icon "${FEATURE_TTL_SPOOF:-false}")
• DroidSpace Prereqs: $(icon "${FEATURE_DROIDSPACE:-false}")

📋 Recent Commits:
${COMMITS}
🔗 Full Commit History: ${COMMIT_LINK}

📦 File: ${ZIP_NAME}
📊 Size: ${SIZE}
🔑 SHA256: \`${SHA256}\`"

tg_send_message "$TEXT" > /dev/null

echo "Uploading ${ZIP_NAME} to Telegram..."
DOC_HTTP_CODE=$(curl -sS -o /tmp/tg_doc.json -w '%{http_code}' -X POST "$API/sendDocument" \
  -F "chat_id=${TELEGRAM_CHAT_ID}" \
  -F "document=@${ZIP_PATH}" \
  -F "caption=📦 ${ZIP_NAME}")

if [ "$DOC_HTTP_CODE" != "200" ] || ! grep -q '"ok":true' /tmp/tg_doc.json; then
  echo "::error::Telegram sendDocument failed for ${ZIP_NAME} (HTTP $DOC_HTTP_CODE):"
  cat /tmp/tg_doc.json
fi

if [ -n "${TG_PROGRESS_MSG_ID:-}" ]; then
  tg_edit_message "$TG_PROGRESS_MSG_ID" "✅ Build complete — ${ZIP_NAME}"
fi
