#!/usr/bin/env bash
# scripts/telegram_lib.sh — sourced by telegram_build_*.sh / telegram_progress.sh.
# Not meant to be run directly.

API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN:-}"

ksu_friendly_name() {
  case "$1" in
    none) echo "Vanilla (No Root)" ;;
    kernelsu-next-legacy) echo "KernelSU-Next (Legacy)" ;;
    resukisu) echo "ReSuKISU" ;;
    xxksu) echo "xxKSU" ;;
    sukisu-ultra) echo "SukiSU Ultra" ;;
    wildksu) echo "Wild KSU" ;;
    *) echo "$1" ;;
  esac
}

icon() { [ "${1:-false}" = "true" ] && echo "✅" || echo "❌"; }

# Prints the new message_id on stdout (empty on failure).
tg_send_message() {
  curl -sS -X POST "$API/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$1" \
    -o /tmp/tg_send.json
  if grep -q '"ok":true' /tmp/tg_send.json; then
    grep -o '"message_id":[0-9]*' /tmp/tg_send.json | head -n1 | grep -o '[0-9]*'
  else
    echo "::warning::Telegram sendMessage failed:" >&2
    cat /tmp/tg_send.json >&2
    echo ""
  fi
}

tg_edit_message() {
  # $1 = message_id, $2 = new text
  curl -sS -X POST "$API/editMessageText" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "message_id=$1" \
    --data-urlencode "text=$2" \
    -o /tmp/tg_edit.json
  grep -q '"ok":true' /tmp/tg_edit.json || {
    echo "::warning::Telegram editMessageText failed (message may have been deleted, or >48h old):" >&2
    cat /tmp/tg_edit.json >&2
  }
}
