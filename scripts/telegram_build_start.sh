#!/usr/bin/env bash
# scripts/telegram_build_start.sh
set -uo pipefail
: "${TELEGRAM_BOT_TOKEN:?}"
: "${TELEGRAM_CHAT_ID:?}"
: "${GITHUB_WORKSPACE:?}"
source "$GITHUB_WORKSPACE/scripts/telegram_lib.sh"

KSU_NAME=$(ksu_friendly_name "${KSU_VARIANT:-none}")
BRANCH="${DEVICE_TREE_BRANCH:-${KERNEL_BRANCH:-unknown}}"

TEXT="🤖 Kernel-CI Build Engine Started!

📱 Device: ${DEVICE_NAME:-unknown}
🫆 Codename: ${CODENAME:-unknown}
🌿 Branch: ${BRANCH}
🔑 KSU Engine: ${KSU_NAME}

👤 Start By: ${GITHUB_ACTOR:-unknown}"

MSG_ID=$(tg_send_message "$TEXT")
if [ -n "$MSG_ID" ]; then
  echo "TG_MSG_ID=$MSG_ID" >> "$GITHUB_ENV"
  echo "Build-start message sent (id $MSG_ID)."
else
  echo "::warning::Could not send build-start message — progress updates for this run will be skipped."
fi
