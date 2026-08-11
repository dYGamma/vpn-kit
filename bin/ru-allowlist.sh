#!/bin/bash
# Защита открытых наружу портов VPN-сервера.
#
#   Панель (13109) — только российские сети плюс явный список: это ключи от
#   всего хозяйства. Из-за границы — через SSH-туннель.
#
#   Страница выдачи (2053) и подписка (2096) — открыты миру с потолком по
#   частоте. География тут была ошибкой: человек в поездке с белыми списками
#   сидит на чужом VPN и не мог попасть на СВОЮ страницу.
#
#   ВАЖНО: запросы, пришедшие ЧЕРЕЗ наш же тоннель, для nginx выглядят как
#   запросы от самого сервера. Без исключения все люди под VPN делили бы одно
#   ведро лимита и выбивали друг друга — именно поэтому страница «не
#   открывалась под VPN». Свои адреса пропускаем без счёта.
#
#   SSH (22) и входы Reality/Hysteria2 не фильтруются никогда.
set -u

PANEL_PORTS="13109"
OPEN_PORTS="2096,2053"
SET=ru_nets
TMP=/tmp/ru.zone
EXTRA="89.124.124.149 94.142.20.6 SERVER_IP OLD_IP"

if curl -sf --max-time 60 -o "$TMP" https://www.ipdeny.com/ipblocks/data/countries/ru.zone \
   && [ "$(wc -l < "$TMP")" -gt 5000 ]; then
    ipset create ${SET}_new hash:net -exist maxelem 262144
    ipset flush ${SET}_new
    while read -r n; do [ -n "$n" ] && ipset add ${SET}_new "$n" -exist; done < "$TMP"
    for e in $EXTRA; do ipset add ${SET}_new "$e" -exist; done
    if ipset list -n | grep -qx "$SET"; then
        ipset swap ${SET}_new "$SET" && ipset destroy ${SET}_new
    else
        ipset rename ${SET}_new "$SET"
    fi
    echo "ru_nets: $(ipset list "$SET" | grep -c '^[0-9]') записей"
else
    echo "список RU-сетей не скачался, набор оставлен прежним" >&2
    ipset list -n | grep -qx "$SET" || exit 1
fi
rm -f "$TMP"

# ── панель: география ──
iptables -N SUBGUARD 2>/dev/null || true
iptables -F SUBGUARD
iptables -A SUBGUARD -i lo -j RETURN
iptables -A SUBGUARD -s 127.0.0.0/8 -j RETURN
iptables -A SUBGUARD -m set --match-set "$SET" src -j RETURN
iptables -A SUBGUARD -j DROP

# ── страница и подписка: потолок по частоте, свои адреса вне счёта ──
iptables -N SUBRATE 2>/dev/null || true
iptables -F SUBRATE
iptables -A SUBRATE -i lo -j RETURN
iptables -A SUBRATE -s 127.0.0.0/8 -j RETURN
for own in $EXTRA; do
    iptables -A SUBRATE -s "$own" -j RETURN
done
iptables -A SUBRATE -m hashlimit \
    --hashlimit-name subrate --hashlimit-mode srcip \
    --hashlimit-above 60/minute --hashlimit-burst 120 \
    --hashlimit-htable-expire 60000 -j DROP
iptables -A SUBRATE -j RETURN

# ── навешиваем, старые варианты снимаем ──
for old in "2096,13109,2053" "$OPEN_PORTS"; do
    while iptables -C INPUT -p tcp -m multiport --dports "$old" -j SUBGUARD 2>/dev/null; do
        iptables -D INPUT -p tcp -m multiport --dports "$old" -j SUBGUARD
    done
done
while iptables -C INPUT -p tcp -m multiport --dports "$OPEN_PORTS" -j SUBRATE 2>/dev/null; do
    iptables -D INPUT -p tcp -m multiport --dports "$OPEN_PORTS" -j SUBRATE
done
while iptables -C INPUT -p tcp -m multiport --dports "$PANEL_PORTS" -j SUBGUARD 2>/dev/null; do
    iptables -D INPUT -p tcp -m multiport --dports "$PANEL_PORTS" -j SUBGUARD
done
iptables -I INPUT 1 -p tcp -m multiport --dports "$PANEL_PORTS" -j SUBGUARD
iptables -I INPUT 1 -p tcp -m multiport --dports "$OPEN_PORTS" -j SUBRATE

echo "панель $PANEL_PORTS — по географии; открыто с потолком частоты: $OPEN_PORTS"
