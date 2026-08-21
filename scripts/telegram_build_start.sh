#!/usr/bin/env bash
# scripts/telegram_build_start.sh
# Sends TWO messages: the "Started" announcement (kept as-is, never
# touched again) and a separate progress placeholder right after it,
# whose id gets edited in place by telegram_progress.sh through
# [1/4]..[4/4]. Keeping them separate means the "Started" message stays
# visible in the chat instead of being overwritten by the first
# progress update a few seconds later.
set -uo pipefail
: "${TELEGRAM_BOT_TOKEN:?}"
: "${TELEGRAM_CHAT_ID:?}"
: "${GITHUB_WORKSPACE:?}"
source "$GITHUB_WORKSPACE/scripts/telegram_lib.sh"

KSU_NAME=$(ksu_friendly_name "${KSU_VARIANT:-none}")
BRANCH="${DEVICE_TREE_BRANCH:-${KERNEL_BRANCH:-unknown}}"

START_TEXT="🤖 Kernel-CI Build Engine Started!

📱 Device: ${DEVICE_NAME:-unknown}
🫆 Codename: ${CODENAME:-unknown}
🌿 Branch: ${BRANCH}
🔑 KSU Engine: ${KSU_NAME}

👤 Start By: ${GITHUB_ACTOR:-unknown}"

tg_send_message "$START_TEXT" > /dev/null

PROGRESS_MSG_ID=$(tg_send_message "⚙️ Progress: [0/4] Preparing build environment... ⏳")
if [ -n "$PROGRESS_MSG_ID" ]; then
  echo "TG_PROGRESS_MSG_ID=$PROGRESS_MSG_ID" >> "$GITHUB_ENV"
  echo "Build-start + progress messages sent (progress id $PROGRESS_MSG_ID)."
else
  echo "::warning::Could not send progress placeholder message — progress updates for this run will be skipped."
fi
