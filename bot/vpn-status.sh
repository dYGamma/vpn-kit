#!/usr/bin/env bash
# Заявки на VPN, которые ждут ответа босса, и сколько людей уже с доступом.
#
# ТОЛЬКО чтение. Выдать или отозвать доступ этим скриптом нельзя — решает
# такое босс сам, командами /vpn в личке боту.
set -u
export LC_ALL=C.UTF-8

ENV=/etc/AVS/office.env
[ -f "$ENV" ] && . "$ENV"
if [ -z "${VPN_API_URL:-}" ] || [ -z "${VPN_API_SECRET:-}" ]; then
  echo "выдача VPN не настроена (нет VPN_API_URL/VPN_API_SECRET)"
  exit 0
fi

# Сертификат проверяем: в заголовке уходит секрет, дающий право выдавать доступы,
# и без проверки его мог бы перехватить кто-то на пути.
R=$(curl -s -m 15 -H "X-Auth: $VPN_API_SECRET" -H 'Content-Type: application/json' \
       -X POST -d '{}' "${VPN_API_URL%/}/list" 2>/dev/null)

if [ -z "$R" ]; then
  echo "⚠️ сервис выдачи VPN не отвечает"
  exit 0
fi

printf '%s' "$R" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("⚠️ сервис выдачи VPN ответил неразборчиво")
    sys.exit(0)

pend = d.get("pending", [])
print("Людей с доступом: %s" % d.get("clients", "?"))
if not pend:
    print("Заявок в очереди нет ✓")
else:
    print("⚠️ Ждут ответа босса: %d" % len(pend))
    for i in pend:
        print("   заявка %s — @%s (%s)" % (i.get("req_id"), i.get("username") or "?", i.get("tg_id")))
    print("   ответить: /vpn ok <номер> или /vpn no <номер> в личке боту")
'
