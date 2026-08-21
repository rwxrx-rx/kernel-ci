#!/usr/bin/env bash
# scripts/telegram_notify.sh
# Sends the changelog as a message, then uploads each given file as a
# document. Requires TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in env.
#
# Plain text, no parse_mode: MarkdownV2 requires escaping ~20 special
# characters and one missed character silently kills the whole message
# (Telegram returns ok:false, "can't parse entities") with no visible
# workflow failure. Not worth the risk for a CI notifier — reliability
# over formatting.
set -uo pipefail   # NOT -e: one failed request shouldn't abort the rest

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN secret not set — check it's spelled exactly that in repo Settings > Secrets}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID secret not set — check it's spelled exactly that in repo Settings > Secrets}"

API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
MSG_FILE="${1:?usage: telegram_notify.sh <message-file> <file1> [file2 ...]}"
shift

echo "Sending Telegram message (chat_id=${TELEGRAM_CHAT_ID})..."
HTTP_CODE=$(curl -sS -o /tmp/tg_msg_response.json -w '%{http_code}' -X POST "$API/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=$(cat "$MSG_FILE")")

if [ "$HTTP_CODE" != "200" ] || ! grep -q '"ok":true' /tmp/tg_msg_response.json; then
  echo "::error::Telegram sendMessage failed (HTTP $HTTP_CODE). Full response:"
  cat /tmp/tg_msg_response.json
  echo ""
  echo "Common causes: bot not added to the chat/channel, wrong chat_id sign (groups are negative, e.g. -100xxxxxxxxxx), or bot not admin in a channel."
else
  echo "Message sent OK."
fi

for f in "$@"; do
  [ -f "$f" ] || { echo "::warning::skipping missing file $f"; continue; }
  echo "Uploading $f to Telegram..."
  DOC_HTTP_CODE=$(curl -sS -o /tmp/tg_doc_response.json -w '%{http_code}' -X POST "$API/sendDocument" \
    -F "chat_id=${TELEGRAM_CHAT_ID}" \
    -F "document=@${f}")
  if [ "$DOC_HTTP_CODE" != "200" ] || ! grep -q '"ok":true' /tmp/tg_doc_response.json; then
    echo "::error::Telegram sendDocument failed for $f (HTTP $DOC_HTTP_CODE):"
    cat /tmp/tg_doc_response.json
  fi
done
