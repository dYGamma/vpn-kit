#!/usr/bin/env bash
# Инфра-поллер (systemd-таймер avs-inbox-poll, раз в 15 секунд; НЕ инструмент Версы):
# 1) сообщения босса боту → очередь .chat-queue → мини-сессия Версы (haiku)
#    отвечает по-человечески и сама кладёт задачи в inbox.md (shifts/chat.md);
# 2) добавление бота в канал → авто-прописать TG_CHANNEL в office.env.
# Оффсет подтверждаем через getUpdates?offset — каждое обновление один раз.
set -u
export LC_ALL=C.UTF-8
ENV=/etc/AVS/office.env
[ -f "$ENV" ] && . "$ENV"
[ -n "${TG_BOT_TOKEN:-}" ] || exit 0

# Самолок: таймер раз в 15 секунд, а скачивание фото может занять дольше — второй
# экземпляр читал бы ТОТ ЖЕ offset и задваивал сообщения/фото.
exec 7>/root/AVS-office/.poll.lock
flock -n 7 || exit 0

OFF_FILE=/root/AVS-office/.tg-offset
OFFSET=$(cat "$OFF_FILE" 2>/dev/null || echo 0)
OUT_FILE=/root/AVS-office/.tg-poll-out
QUEUE=/root/AVS-office/.chat-queue
PROCESSING=/root/AVS-office/.chat-processing

# allowed_updates ЛИПКИЙ на стороне TG (один отладочный вызов с фильтром 2026-07-15
# отрубил личку на полдня) — всегда передаём полный список явно
AU='%5B%22message%22%2C%22edited_message%22%2C%22channel_post%22%2C%22my_chat_member%22%5D'
curl -s -m 20 "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates?offset=$((OFFSET+1))&timeout=0&allowed_updates=$AU" \
  -o "$OUT_FILE.raw" || { rm -f "$OUT_FILE.raw"; exit 0; }

python3 - "$OUT_FILE.raw" "${TG_BOSS_CHAT_ID:-0}" > "$OUT_FILE" 2>/dev/null <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
boss = str(sys.argv[2])
maxid, msgs, channel, strangers, photos, vpn = 0, [], None, [], [], []
for u in d.get("result", []):
    maxid = max(maxid, u.get("update_id", 0))
    edited = "edited_message" in u
    m = u.get("message") or u.get("edited_message") or {}
    cm = u.get("my_chat_member") or {}
    if str(m.get("chat", {}).get("id")) == boss and not m.get("forward_origin") and m:
        t = (m.get("text") or m.get("caption") or "").replace("\n", " ").strip()
        if edited and t:
            t = "(босс поправил своё сообщение) " + t
        doc = m.get("document") or {}
        if m.get("photo"):
            # фото босса скачиваем (largest size) — file_id отдаём шеллу
            fid = m["photo"][-1].get("file_id", "")
            photos.append({"file_id": fid, "caption": t})
        elif str(doc.get("mime_type", "")).startswith("image/"):
            # картинка «файлом» (без сжатия) — тоже скачиваем
            photos.append({"file_id": doc.get("file_id", ""), "caption": t})
        elif t:
            msgs.append(t)
        elif any(k in m for k in ("sticker", "voice", "video", "document", "animation", "video_note", "audio")):
            kind = next(k for k in ("sticker", "voice", "video", "document", "animation", "video_note", "audio") if k in m)
            msgs.append(f"[босс прислал {kind} без текста — такое ты не видишь, попроси продублировать текстом или фото]")
    elif m.get("chat", {}).get("type") == "private" and str(m.get("chat", {}).get("id")) != boss:
        # чужак пишет боту: игнор (не отвечаем), но фиксируем в лог
        f = m.get("from", {})
        strangers.append(f"{f.get('id')} @{f.get('username','?')}: {str(m.get('text',''))[:60]}")
        # ...и отдельно — для моста выдачи VPN (Версе это не показывается)
        # Человек может нажать /start шесть раз подряд — в одной порции
        # обновлений это шесть сообщений. Отвечаем один раз: держим по одной
        # записи на человека и берём последний текст.
        vid = f.get("id")
        vpn[:] = [v for v in vpn if v.get("id") != vid]
        vpn.append({"id": vid, "username": f.get("username") or "",
                    "text": str(m.get("text") or m.get("caption") or "")[:200]})
    if cm and cm.get("chat", {}).get("type") == "channel":
        if cm.get("new_chat_member", {}).get("status") in ("administrator", "member"):
            channel = cm["chat"]["id"]
    cp = u.get("channel_post") or {}
    if cp.get("chat", {}).get("type") == "channel":
        channel = cp["chat"]["id"]
    fo = m.get("forward_origin") or {}
    if fo.get("type") == "channel" and fo.get("chat", {}).get("id"):
        channel = fo["chat"]["id"]
print(json.dumps({"maxid": maxid, "msgs": msgs, "channel": channel, "strangers": strangers, "photos": photos, "vpn": vpn}, ensure_ascii=False))
PY

MAXID=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("maxid",0))' "$OUT_FILE" 2>/dev/null || echo 0)
[ "$MAXID" -gt 0 ] 2>/dev/null && echo "$MAXID" > "$OFF_FILE"

CHANNEL=$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1])).get("channel");print(c if c else "")' "$OUT_FILE" 2>/dev/null)
if [ -n "$CHANNEL" ] && [ -z "${TG_CHANNEL:-}" ]; then
  sed -i "s|^TG_CHANNEL=.*|TG_CHANNEL=$CHANNEL|" "$ENV"
  curl -s -m 20 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TG_BOSS_CHAT_ID}" \
    --data-urlencode text="Верса: бота добавили в канал (id $CHANNEL) — публикации готовы ♡" >/dev/null
  echo "$(date -Is) TG_CHANNEL=$CHANNEL записан" >> /root/AVS-office/logs/inbox-poll.log
fi

# Чужие сообщения боту — в лог (Верса не видит, ответа нет)
python3 -c '
import json, sys
for s in json.load(open(sys.argv[1])).get("strangers", []):
    print(s)
' "$OUT_FILE" 2>/dev/null | while IFS= read -r S; do
  [ -n "$S" ] && echo "$(date -Is) STRANGER $S" >> /root/AVS-office/logs/inbox-poll.log
done

# Обращения чужих людей → мост выдачи VPN. Заводит доступы не он, а босс:
# мост лишь создаёт заявку и присылает боссу команды для ответа.
# Разделитель \x1f, а НЕ табуляция: табуляция для read — пробельный символ,
# поэтому пустое поле схлопывается и поля съезжают. Так у человека без
# username текст сообщения попал в поле имени, сервис получил пустой текст и
# не увидел просьбы — заявка не создалась, человек ждал зря.
python3 -c '
import json, sys
for v in json.load(open(sys.argv[1])).get("vpn", []):
    print("%s\x1f%s\x1f%s" % (v.get("id") or "", v.get("username") or "",
                                (v.get("text") or "").replace("\n", " ")))
' "$OUT_FILE" 2>/dev/null | while IFS=$'\x1f' read -r VID VUN VTX; do
  [ -n "$VID" ] && /root/AVS-office/bin/vpn-gate.sh request "$VID" "$VUN" "$VTX" >/dev/null 2>&1
done

# Фото босса → скачать в drafts/img/ и сообщить Версе имя файла
python3 -c '
import json, sys
for p in json.load(open(sys.argv[1])).get("photos", []):
    print(p.get("file_id","") + "\t" + p.get("caption",""))
' "$OUT_FILE" 2>/dev/null | while IFS=$'\t' read -r FID CAP; do
  [ -n "$FID" ] || continue
  FP=$(curl -s -m 20 "https://api.telegram.org/bot${TG_BOT_TOKEN}/getFile?file_id=$FID" \
    | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["result"]["file_path"] if d.get("ok") else "")' 2>/dev/null)
  if [ -n "$FP" ]; then
    NAME="boss-$(date +%H%M%S)-$RANDOM.jpg"
    mkdir -p /root/AVS-office/drafts/img
    curl -s -m 40 -o "/root/AVS-office/drafts/img/$NAME" "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/$FP" \
      && printf '%s\n' "[босс прислал фото — сохранено как $NAME в drafts/img, работай с ним через img-tool] $CAP" >> "$QUEUE" \
      && echo "$(date -Is) фото босса → $NAME" >> /root/AVS-office/logs/inbox-poll.log
  else
    printf '%s\n' "[фото босса скачать не удалось — попроси прислать ещё раз] $CAP" >> "$QUEUE"
  fi
done

# Сообщения босса → очередь живого чата
python3 -c '
import json, sys
for t in json.load(open(sys.argv[1])).get("msgs", []):
    print(t)
' "$OUT_FILE" 2>/dev/null | while IFS= read -r MSG; do
  [ -n "$MSG" ] || continue
  # Команды выдачи VPN обрабатывает мост, Версе они не нужны и в чат не идут.
  case "$MSG" in
    /vpn|/vpn\ *) /root/AVS-office/bin/vpn-gate.sh command "$MSG" >/dev/null 2>&1; continue ;;
  esac
  printf '%s\n' "$MSG" >> "$QUEUE"
  echo "$(date -Is) chat-queue += ${MSG:0:80}" >> /root/AVS-office/logs/inbox-poll.log
done
rm -f "$OUT_FILE" "$OUT_FILE.raw"

# Бэкофф: если чат падает (кончилась квота), не долбим каждые 15 секунд — пауза 10 мин
FAIL=/root/AVS-office/.chat-fail
if [ -f "$FAIL" ] && [ $(( $(date +%s) - $(stat -c %Y "$FAIL") )) -lt 600 ]; then
  exit 0
fi

# Есть что отвечать и чат-сессия не занята → передаём очередь в обработку и запускаем
if [ -s "$QUEUE" ] || [ -s "$PROCESSING" ]; then
  exec 8>/root/AVS-office/.chat.lock
  if flock -n 8; then
    flock -u 8
    [ -s "$QUEUE" ] && { cat "$QUEUE" >> "$PROCESSING"; rm -f "$QUEUE"; }
    # мгновенный «печатает…» — юзер видит, что Верса думает (сессия продлит сама)
    curl -s -m 10 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendChatAction" \
      -d chat_id="${TG_BOSS_CHAT_ID:-0}" -d action=typing >/dev/null 2>&1 || true
    # 7>&- 8>&- — закрыть НАШИ замки у ребёнка, и это не косметика.
    # flock живёт на открытом файле, а не на процессе: фоновая чат-сессия
    # наследовала дескриптор 7 (.poll.lock) и держала его все свои минуты.
    # Пока она работала, каждый следующий тик поллера молча выходил на
    # `flock -n 7` — не забирались новые сообщения и не работал мост выдачи
    # доступов. Наружу это выглядит как «бот молчит», без единой ошибки в логе.
    /root/AVS-office/run-shift.sh chat sonnet >/dev/null 2>&1 7>&- 8>&- &
  fi
fi
exit 0
