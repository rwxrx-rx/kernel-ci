#!/usr/bin/env bash
# scripts/telegram_progress.sh <stage 1-4> <label>
set -uo pipefail
: "${TELEGRAM_BOT_TOKEN:?}"
: "${TELEGRAM_CHAT_ID:?}"
: "${GITHUB_WORKSPACE:?}"
source "$GITHUB_WORKSPACE/scripts/telegram_lib.sh"

STAGE="${1:?usage: telegram_progress.sh <stage> <label>}"
LABEL="${2:?usage: telegram_progress.sh <stage> <label>}"

if [ -z "${TG_PROGRESS_MSG_ID:-}" ]; then
  echo "No progress message on record — skipping progress update."
  exit 0
fi

tg_edit_message "$TG_PROGRESS_MSG_ID" "⚙️ Progress: [${STAGE}/4] ${LABEL} ⏳"
