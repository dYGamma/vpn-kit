#!/usr/bin/env bash
# Мост между ботом и сервисом выдачи VPN, который живёт на другом сервере.
#
# НЕ инструмент Версы: в allowlist run-shift.sh его нет, запускает только
# инфра-поллер tg-inbox-poll.sh. Верса про существование файла не знает и
# ничего в нём не решает — выдачей доступов распоряжается только босс.
#
#   vpn-gate.sh request <tg_id> <username> <текст>  — чужой написал боту
#   vpn-gate.sh command "<текст>"            — босс прислал команду /vpn ...
#
# Настройки VPN_API_URL и VPN_API_SECRET лежат в /etc/AVS/office.env.
set -u
export LC_ALL=C.UTF-8

ENV=/etc/AVS/office.env
[ -f "$ENV" ] && . "$ENV"
[ -n "${TG_BOT_TOKEN:-}" ] || exit 0
[ -n "${VPN_API_URL:-}" ] || exit 0
[ -n "${VPN_API_SECRET:-}" ] || exit 0

LOG=/root/AVS-office/logs/vpn-gate.log
BOSS="${TG_BOSS_CHAT_ID:-0}"

log() { echo "$(date -Is) $*" >> "$LOG"; }

# api <путь> <json> — ответ сервиса в stdout, пусто при недоступности.
# Сертификат проверяем: в заголовке уходит секрет, дающий право выдавать и
# отзывать доступы. Сертификат на той стороне — обычный Let's Encrypt на IP,
# так что проверка проходит штатно; сорвётся продление — вызов честно упадёт.
api() {
  curl -s -m 15 -H "X-Auth: $VPN_API_SECRET" -H 'Content-Type: application/json' \
       -X POST -d "$2" "${VPN_API_URL%/}/$1"
}

# send <chat_id> <текст>
send() {
  curl -s -m 15 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
       -d chat_id="$1" --data-urlencode text="$2" \
       -d disable_web_page_preview=true >/dev/null 2>&1
}

# jget <json> <ключ> — значение поля верхнего уровня
jget() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get(sys.argv[1], "") or "")
except Exception:
    print("")
' "$2" 2>/dev/null
}

case "${1:-}" in

  request)
    TG_ID="${2:-}"; UNAME="${3:-}"; TEXT="${4:-}"
    [ -n "$TG_ID" ] || exit 0
    # Заявку создаёт сервис и только когда человек сам сказал, что хочет
    # доступ. На первое «привет» бот сначала спрашивает — Диму не дёргаем.
    R=$(api touch "$(python3 -c '
import json, sys
print(json.dumps({"tg_id": int(sys.argv[1]), "username": sys.argv[2], "text": sys.argv[3]}))
' "$TG_ID" "$UNAME" "$TEXT")")
    if [ -z "$R" ]; then
      log "сервис выдачи не ответил, обращение от $TG_ID"
      send "$TG_ID" "Записала, но сервер сейчас не отвечает. Вернусь, как только починим — не теряйся."
      send "$BOSS" "VPN: @${UNAME:-?} ($TG_ID) писал боту, но сервис выдачи молчит — заявку создать не смогла."
      exit 0
    fi
    case "$(jget "$R" action)" in
      exists)
        send "$TG_ID" "Доступ у тебя уже есть, я проверила ♡ Вот твоя страница — там приложение под твою систему и кнопка подключения:
$(jget "$R" link)"
        log "повторное обращение $TG_ID — отдали существующую ссылку"
        ;;
      new)
        RID=$(jget "$R" req_id)
        send "$TG_ID" "Передала заявку Диме — такие вещи он подтверждает сам. Как ответит, пришлю ссылку сюда же ♡"
        send "$BOSS" "VPN: к нам стучится @${UNAME:-?} ($TG_ID).

Выдать:   /vpn ok $RID
Отказать: /vpn no $RID"
        log "заявка $RID от $TG_ID (@$UNAME): «${TEXT:0:60}»"
        ;;
      pending)
        send "$TG_ID" "Твоя заявка уже у Димы, я про тебя не забыла. Ответ придёт сюда."
        ;;
      greet)
        send "$TG_ID" "Привет! Я Верса ♡ Через меня просят доступ к VPN — открывает его Дима, а я передаю заявку.

Нужен доступ? Напиши «нужен доступ», и я ему скажу."
        log "поздоровались с $TG_ID (@$UNAME), заявку не создавали"
        ;;
      nudge)
        send "$TG_ID" "Если нужен доступ к VPN — просто напиши «нужен доступ», я передам Диме ♡"
        ;;
      silent)
        log "молчим для $TG_ID (@$UNAME): много сообщений без внятной просьбы"
        ;;
      *)
        log "непонятный ответ сервиса: $R"
        ;;
    esac
    ;;

  command)
    TEXT="${2:-}"
    ACT=$(printf '%s' "$TEXT" | awk '{print $2}')
    ARG=$(printf '%s' "$TEXT" | awk '{print $3}')
    case "$ACT" in

      ok)
        [ -n "$ARG" ] || { send "$BOSS" "VPN: нужен номер заявки, вот так — /vpn ok 5"; exit 0; }
        R=$(api approve "{\"req_id\":$ARG}")
        if [ "$(jget "$R" ok)" != "True" ] && [ "$(jget "$R" ok)" != "true" ]; then
          send "$BOSS" "VPN: не получилось — $(jget "$R" error)"; exit 0
        fi
        UID_=$(jget "$R" tg_id); LINK=$(jget "$R" link)
        UNAME=$(jget "$R" username); NAME=$(jget "$R" name)
        send "$UID_" "Готово, доступ открыт (≧▽≦) Заходи сюда — там приложение под твою систему и кнопка подключения:
$LINK

Российские сайты, банки и Госуслуги идут мимо VPN — так и задумано, пугаться не надо."
        send "$BOSS" "VPN: выдала доступ @${UNAME:-?} (в панели — $NAME), ссылку ему отправила ♡"
        log "заявка $ARG одобрена, клиент $NAME"
        ;;

      no)
        [ -n "$ARG" ] || { send "$BOSS" "VPN: нужен номер заявки, вот так — /vpn no 5"; exit 0; }
        R=$(api deny "{\"req_id\":$ARG}")
        if [ "$(jget "$R" ok)" != "True" ] && [ "$(jget "$R" ok)" != "true" ]; then
          send "$BOSS" "VPN: не получилось — $(jget "$R" error)"; exit 0
        fi
        UID_=$(jget "$R" tg_id)
        send "$UID_" "Дима сейчас доступ не открывает. Спасибо, что написал."
        send "$BOSS" "VPN: отказала по заявке $ARG, человеку написала по-доброму."
        log "заявка $ARG отклонена"
        ;;

      off)
        [ -n "$ARG" ] || { send "$BOSS" "VPN: нужен Telegram-ID, вот так — /vpn off 12345"; exit 0; }
        R=$(api revoke "{\"tg_id\":$ARG}")
        if [ "$(jget "$R" ok)" = "True" ] || [ "$(jget "$R" ok)" = "true" ]; then
          send "$BOSS" "VPN: доступ у $ARG отозвала."
          log "доступ $ARG отозван"
        else
          send "$BOSS" "VPN: клиента с таким ID не нашла."
        fi
        ;;

      list|"")
        R=$(api list '{}')
        OUT=$(printf '%s' "$R" | python3 -c '
import json, sys
try:
    items = json.load(sys.stdin).get("pending", [])
except Exception:
    items = []
if not items:
    print("Заявок нет.")
else:
    for i in items:
        print("%s — @%s (%s)" % (i["req_id"], i.get("username") or "?", i["tg_id"]))
' 2>/dev/null)
        TOT=$(printf '%s' "$R" | python3 -c '
import json, sys
try: print(json.load(sys.stdin).get("clients", "?"))
except Exception: print("?")
' 2>/dev/null)
        send "$BOSS" "VPN, заявки в очереди:
${OUT:-не удалось получить список}

Сейчас с доступом: ${TOT:-?} человек.
Команды: /vpn ok N — выдать, /vpn no N — отказать, /vpn off <id> — отозвать."
        ;;

      *)
        send "$BOSS" "VPN: не поняла команду. Есть /vpn list, /vpn ok N, /vpn no N, /vpn off <id>."
        ;;
    esac
    ;;

  *)
    echo "использование: vpn-gate.sh request <tg_id> <username> <текст> | command \"<текст>\"" >&2
    exit 2
    ;;
esac
exit 0
