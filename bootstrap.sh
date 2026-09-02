#!/usr/bin/env bash
# Основание узла с нуля: 3x-ui, Xray, два входа VLESS+Reality, Hysteria2,
# сертификат на IP и nginx. Обвязку (подписки, выдачу доступов, сторож утечек)
# ставит install.sh — его запускают ПОСЛЕ этого скрипта.
#
#   bootstrap.sh [--dry-run]
#
# Скрипт идемпотентный и трусливый: всё, что уже стоит и настроено, он не
# трогает, а сообщает и идёт дальше. Это не вежливость — на боевом узле
# перезапись конфига Hysteria или таблицы inbounds означает обрыв сессий у
# всех разом и потерю ключей Reality, после которой ни один клиент не
# подключится. Поэтому: существующее не переписываем НИКОГДА, только
# дополняем недостающее.
set -u
export LC_ALL=C.UTF-8
cd "$(dirname "$0")"

CFG=/etc/vpn-issue/config
CERT_DIR=/root/cert/ip
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say()  { printf '  %s\n' "$*"; }
skip() { printf '  · %s\n' "$*"; }
head_(){ printf '\n== %s ==\n' "$*"; }
die()  { printf '\nОСТАНОВ: %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '  [сухой прогон] %s\n' "$*"; else eval "$@"; fi; }

# --- 1. проверки до любых действий ----------------------------------------
head_ "проверка окружения"
[ "$(id -u)" = 0 ] || die "нужны права root"
command -v apt-get >/dev/null || die "скрипт рассчитан на Debian/Ubuntu (нужен apt-get)"
[ "$(uname -m)" = x86_64 ] || die "поддерживается только x86_64, у вас $(uname -m)"

IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
[ -n "$IFACE" ] || die "не удалось определить внешний интерфейс (ip route show default пуст)"
LOCAL_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
[ -n "$LOCAL_IP" ] || die "не удалось определить адрес на интерфейсе $IFACE"

# Адрес интерфейса и адрес, по которому узел видно из интернета, — разные вещи.
# На VPS они совпадают, а на домашней машине за NAT интерфейс отдаёт что-то
# вроде 192.168.x.x. Взять его — значит собрать все ссылки, сертификат и
# share_addr на адрес, который снаружи не существует, и обнаружить это уже на
# клиенте, по таймауту без единой записи в логе.
is_private() {
  case "$1" in
    10.*|127.*|192.168.*|169.254.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    *) return 1 ;;
  esac
}
IP4="$LOCAL_IP"
if is_private "$LOCAL_IP"; then
  for U in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    PUB=$(curl -s -4 --max-time 8 "$U" 2>/dev/null | tr -d '[:space:]')
    case "$PUB" in
      [0-9]*.[0-9]*.[0-9]*.[0-9]*) is_private "$PUB" || { IP4="$PUB"; break; } ;;
    esac
    PUB=""
  done
  if [ "$IP4" = "$LOCAL_IP" ]; then
    die "адрес интерфейса $LOCAL_IP частный, а внешний определить не вышло.
       Задайте его руками: SERVER_IP=<ваш белый адрес> в $CFG и запустите снова."
  fi
  say "интерфейс $IFACE, локальный адрес $LOCAL_IP, внешний $IP4"
  say ""
  say "ВНИМАНИЕ: машина за NAT. Снаружи она доступна только через проброс портов"
  say "на роутере — без него не заработает ни один вход и не выпустится сертификат:"
  say "  TCP 443, TCP 8443, TCP 2053, TCP 80 (на время выпуска), UDP 36712 и 20000-50000"
  say ""
else
  say "интерфейс $IFACE, адрес $IP4"
fi

# Порты, которые займём. Если что-то из этого уже слушает ЧУЖОЙ процесс —
# лучше остановиться сейчас, чем получить наполовину поднятый узел.
for P in 443 8443 2053; do
  if ss -lntH "sport = :$P" 2>/dev/null | grep -q .; then
    OWNER=$(ss -lntpH "sport = :$P" 2>/dev/null | grep -oE 'users:\(\("[^"]+' | head -1 | cut -d'"' -f2)
    case "$OWNER" in
      xray*|nginx|x-ui|"") skip "порт $P занят (${OWNER:-неизвестно}) — считаю, что это наш" ;;
      *) if [ "$DRY" = 1 ]; then
           say "ВНИМАНИЕ: порт $P занят процессом $OWNER — на живой установке это остановит скрипт"
         else
           die "порт $P занят процессом $OWNER — освободите его или поменяйте порты"
         fi ;;
    esac
  fi
done

# --- 2. пакеты -------------------------------------------------------------
head_ "пакеты"
NEED=""
for c in curl sqlite3 python3 nginx socat openssl; do
  command -v "$c" >/dev/null || NEED="$NEED $c"
done
# iptables нужен для прыжков по портам Hysteria
command -v iptables >/dev/null || NEED="$NEED iptables"
if [ -n "$NEED" ]; then
  say "ставлю:$NEED"
  run "DEBIAN_FRONTEND=noninteractive apt-get update -qq"
  run "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq$NEED"
else
  skip "всё уже стоит"
fi

# --- 3. конфиг с секретами -------------------------------------------------
head_ "настройки узла"
rand() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c "1-$1"; }
if [ -f "$CFG" ]; then
  skip "$CFG уже есть, значения оттуда и берём"
else
  SECRET=$(rand 48); API_PATH=$(rand 17); PAGE_PATH=$(rand 12)
  if [ "$DRY" = 1 ]; then
    say "[сухой прогон] создал бы $CFG с новыми SECRET/API_PATH/PAGE_PATH"
  else
    install -d -m 700 /etc/vpn-issue
    cat > "$CFG" <<EOF
# Создано bootstrap.sh $(date -Is). Секреты: файл не показывать никому.
SECRET=$SECRET
API_PATH=/$API_PATH/
PAGE_BASE=https://$IP4:2053/$PAGE_PATH
SERVER_IP=$IP4
SUPPORT_URL=https://t.me/YourBotName
EOF
    chmod 600 "$CFG"
    say "создан $CFG (страница /$PAGE_PATH, API /$API_PATH)"
  fi
fi
get() { grep -oE "^$1=.*" "$CFG" 2>/dev/null | head -1 | cut -d= -f2-; }
PAGE_PATH=$(basename "$(get PAGE_BASE | sed 's#/*$##')")
[ -n "$PAGE_PATH" ] || PAGE_PATH=vpn

# Адрес мог быть записан неверно на прошлом запуске (например, взялся адрес
# интерфейса за NAT). Чиним при повторном прогоне: это наш собственный файл и
# поле share_addr, ключей и клиентов правка не касается.
OLD_IP=$(get SERVER_IP)
if [ -n "$OLD_IP" ] && [ "$OLD_IP" != "$IP4" ]; then
  if [ "$DRY" = 1 ]; then
    say "[сухой прогон] заменил бы адрес $OLD_IP на $IP4 в $CFG и в ссылках панели"
  else
    sed -i -e "s#^SERVER_IP=.*#SERVER_IP=$IP4#" -e "s#$OLD_IP#$IP4#g" "$CFG"
    say "адрес исправлен: было $OLD_IP, стало $IP4"
  fi
fi

# --- 4. панель 3x-ui -------------------------------------------------------
head_ "панель 3x-ui"
XUI_BIN=/usr/local/x-ui/x-ui
XUI_DB=/etc/x-ui/x-ui.db
if [ -x "$XUI_BIN" ]; then
  skip "панель уже стоит — не трогаю ни её, ни базу"
else
  say "ставлю 3x-ui официальным установщиком"
  # </dev/null: установщик в некоторых версиях спрашивает логин/пароль/порт.
  # Пустые ответы = он придумает случайные, а мы ниже зададим свои.
  run "bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) </dev/null"
  [ "$DRY" = 1 ] || [ -x "$XUI_BIN" ] || die "установщик 3x-ui отработал, а бинаря $XUI_BIN нет"
fi

PANEL_PORT=$(get PANEL_PORT); [ -n "$PANEL_PORT" ] || PANEL_PORT=13109
if [ -x "$XUI_BIN" ] && [ ! -f /etc/vpn-issue/.panel-configured ]; then
  PU=$(get PANEL_USER); [ -n "$PU" ] || PU=admin
  PP=$(get PANEL_PASS); [ -n "$PP" ] || PP=$(rand 24)
  say "задаю порт панели $PANEL_PORT и учётку"
  if [ "$DRY" = 1 ]; then
    say "[сухой прогон] $XUI_BIN setting -port $PANEL_PORT -username … -password …"
  else
    "$XUI_BIN" setting -port "$PANEL_PORT" -username "$PU" -password "$PP" >/dev/null 2>&1 \
      || say "флаги setting не приняты этой версией — задайте порт и учётку сами через «x-ui»"
    grep -q '^PANEL_USER=' "$CFG" || printf 'PANEL_USER=%s\nPANEL_PASS=%s\nPANEL_PORT=%s\n' "$PU" "$PP" "$PANEL_PORT" >> "$CFG"
    # Установщик 3x-ui придумывает свой секретный путь панели и пишет его в
    # install-result.env. Без этой строки человек знает порт и учётку, но не
    # знает, по какому пути открывать панель, и ищет её в логах установки.
    WBP=$(grep -oE '^WebBasePath=.*' /etc/x-ui/install-result.env 2>/dev/null | cut -d= -f2- | tr -d '"')
    [ -n "$WBP" ] && ! grep -q '^PANEL_PATH=' "$CFG" && printf 'PANEL_PATH=%s\n' "$WBP" >> "$CFG"
    : > /etc/vpn-issue/.panel-configured
    systemctl restart x-ui >/dev/null 2>&1 || true
  fi
elif [ -f /etc/vpn-issue/.panel-configured ]; then
  skip "панель уже настроена"
else
  skip "панели нет — порт и учётку задам после установки"
fi

# --- 5. два входа VLESS+Reality -------------------------------------------
head_ "входы VLESS+Reality"
XRAY=/usr/local/x-ui/bin/xray-linux-amd64
HAVE_IN=0
[ -f "$XUI_DB" ] && HAVE_IN=$(sqlite3 "$XUI_DB" 'select count(*) from inbounds;' 2>/dev/null || echo 0)
if [ "$HAVE_IN" != 0 ]; then
  skip "в панели уже $HAVE_IN вход(ов) — не трогаю, ключи Reality менять нельзя"
elif [ "$DRY" = 1 ]; then
  say "[сухой прогон] создал бы два входа: 443 (www.kinopoisk.ru) и 8443 (www.samsung.com)"
else
  [ -x "$XRAY" ] || die "нет бинаря Xray $XRAY — панель встала неполностью"
  # Домен прикрытия обязан быть на большом CDN и принимать наш отпечаток.
  # Проверенно рабочие с fp=edge: www.kinopoisk.ru (CDN Яндекса),
  # www.samsung.com (Akamai). www.microsoft.com НЕ годится — антибот Akamai
  # рвёт рукопожатие, вход умирает даже на петле с самого сервера.
  systemctl stop x-ui >/dev/null 2>&1
  python3 - "$XUI_DB" "$XRAY" "$IP4" <<'PYEOF'
import json, os, random, string, subprocess, sqlite3, sys, time
db, xray, ip = sys.argv[1], sys.argv[2], sys.argv[3]

def keys():
    out = subprocess.run([xray, "x25519"], capture_output=True, text=True).stdout
    priv = pub = ""
    for line in out.splitlines():
        low = line.lower()
        val = line.split(":", 1)[-1].strip()
        if "private" in low: priv = val
        elif "public" in low or "password" in low: pub = val
    if not priv or not pub:
        raise SystemExit("xray x25519 вернул неожиданный вывод: %r" % out)
    return priv, pub

def short_id():
    return "".join(random.choice("0123456789abcdef") for _ in range(8))

now = int(time.time() * 1000)
con = sqlite3.connect(db); cur = con.cursor()
for port, dest, remark in ((443, "www.kinopoisk.ru", "Основной 443"),
                           (8443, "www.samsung.com", "Резерв 8443")):
    priv, pub = keys()
    settings = {"clients": [], "decryption": "none", "fallbacks": []}
    stream = {
        "network": "tcp", "security": "reality", "externalProxy": [],
        "realitySettings": {
            "show": False, "xver": 0,
            "target": "%s:443" % dest, "serverNames": [dest],
            "privateKey": priv,
            # minClientVer задан явно: Xray 26.7+ иначе подставляет свой
            # дефолт, и все клиенты на mihomo (там версия зашита 1.8.2)
            # отваливаются молча.
            "minClientVer": "1.8.0", "maxClientVer": "", "maxTimediff": 0,
            "shortIds": [short_id()], "mldsa65Seed": "",
            "settings": {"publicKey": pub,
                         # fp=edge обязателен: у chrome приветствие 1760 байт,
                         # мобильный оператор режет его на два сегмента и
                         # выкидывает второй — тот, где SNI. edge даёт 517.
                         "fingerprint": "edge", "serverName": "",
                         "spiderX": "/", "mldsa65Verify": ""}},
        "tcpSettings": {"acceptProxyProtocol": False, "header": {"type": "none"}}}
    sniff = {"enabled": True,
             "destOverride": ["http", "tls", "quic", "fakedns"],
             "metadataOnly": False, "routeOnly": False}
    cur.execute(
        "insert into inbounds(user_id,up,down,total,remark,enable,expiry_time,"
        "listen,port,protocol,settings,stream_settings,tag,sniffing,"
        "sub_sort_index,share_addr_strategy,share_addr) "
        "values(1,0,0,0,?,1,0,'',?,'vless',?,?,?,?,1,'custom',?)",
        (remark, port, json.dumps(settings), json.dumps(stream),
         "inbound-%d" % port, json.dumps(sniff), ip))
    print("  вход %d готов (%s)" % (port, dest))
con.commit(); con.close()
PYEOF
  systemctl start x-ui >/dev/null 2>&1
  sleep 3
  systemctl is-active --quiet x-ui && say "панель поднялась с новыми входами" \
    || die "панель не поднялась — смотрите journalctl -u x-ui"
fi

# Адрес в ссылках. 3x-ui подставляет тот адрес, по которому открыли панель:
# если её открыть по старому/чужому имени, все скопированные ссылки поведут
# не туда, а клиент отвалится по таймауту без единой записи в логе.
if [ -f "$XUI_DB" ] && [ "$DRY" = 0 ]; then
  sqlite3 "$XUI_DB" "update inbounds set share_addr_strategy='custom', share_addr='$IP4' where share_addr is null or share_addr<>'$IP4';" 2>/dev/null || true
fi

# --- 6. сертификат на IP ---------------------------------------------------
head_ "сертификат"
if [ -s "$CERT_DIR/fullchain.pem" ]; then
  skip "сертификат уже лежит в $CERT_DIR"
elif [ "$DRY" = 1 ]; then
  say "[сухой прогон] выпустил бы сертификат Let's Encrypt на адрес $IP4"
else
  [ -d /root/.acme.sh ] || run "curl -s https://get.acme.sh | sh -s email=admin@$IP4"
  install -d -m 700 "$CERT_DIR"
  # standalone: порт 80 на время выпуска должен быть свободен
  systemctl stop nginx >/dev/null 2>&1 || true
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
  if /root/.acme.sh/acme.sh --issue --standalone -d "$IP4" --keylength ec-256 >/dev/null 2>&1; then
    /root/.acme.sh/acme.sh --install-cert -d "$IP4" --ecc \
      --key-file "$CERT_DIR/privkey.pem" --fullchain-file "$CERT_DIR/fullchain.pem" \
      --reloadcmd 'systemctl restart x-ui; systemctl restart hysteria-server; systemctl reload nginx' >/dev/null 2>&1
    say "сертификат выпущен и прописан на автопродление"
  else
    say "ВНИМАНИЕ: выпуск не удался. Сертификаты на голый IP выдаёт не любой CA"
    say "и не всегда. Положите свой в $CERT_DIR/{fullchain,privkey}.pem и повторите."
  fi
  systemctl start nginx >/dev/null 2>&1 || true
fi

# --- 7. Hysteria2 ----------------------------------------------------------
head_ "Hysteria2"
if command -v hysteria >/dev/null; then
  skip "hysteria уже стоит ($(hysteria version 2>/dev/null | awk -F'\t' '/^Version/{print $2}'))"
elif [ "$DRY" = 1 ]; then
  say "[сухой прогон] поставил бы Hysteria2 официальным установщиком"
else
  # Официальный установщик тянет бинарь с GitHub, а из России GitHub отвечает
  # через раз — без таймаута скрипт просто висит молча. Поэтому: ограничение по
  # времени, и если не вышло — качаем бинарь сами и пишем юнит руками.
  say "ставлю Hysteria2 (до 5 минут, тянется с GitHub)"
  timeout 300 bash -c 'curl -fsSL https://get.hy2.sh/ | bash' || say "официальный установщик не отработал"
  if ! command -v hysteria >/dev/null; then
    say "пробую запасной путь — прямая загрузка бинаря"
    if timeout 300 curl -fsSL --retry 2 -o /usr/local/bin/hysteria \
         https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64; then
      chmod 755 /usr/local/bin/hysteria
      id hysteria >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin hysteria
      cat > /etc/systemd/system/hysteria-server.service <<'UNIT'
[Unit]
Description=Hysteria2 server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
      systemctl daemon-reload
      say "бинарь и юнит поставлены вручную"
    else
      die "Hysteria2 поставить не удалось: GitHub недоступен.
       Скачайте hysteria-linux-amd64 любым способом, положите в /usr/local/bin/hysteria,
       сделайте chmod 755 и запустите bootstrap.sh снова — он продолжит с этого места."
    fi
  fi
fi
if [ -f /etc/hysteria/config.yaml ]; then
  skip "конфиг Hysteria уже есть — не переписываю"
elif [ "$DRY" = 1 ]; then
  say "[сухой прогон] создал бы /etc/hysteria/config.yaml (порт 36712, авторизация по базе панели)"
else
  install -d -m 700 /etc/hysteria
  cat > /etc/hysteria/config.yaml <<EOF
listen: :36712

tls:
  cert: $CERT_DIR/fullchain.pem
  key: $CERT_DIR/privkey.pem

# Пользователи здесь НЕ перечисляются: их проверяет служба hysteria-auth,
# которая смотрит прямо в базу 3x-ui. Завёл клиента в панели — он работает
# сразу. Раньше список жил в этом файле, и каждое добавление требовало
# перезапуска, то есть обрыва сессий у всех; а при пустом списке служба
# вообще падала с "empty auth userpass".
auth:
  type: http
  http:
    url: http://127.0.0.1:8790/auth
    insecure: false

masquerade:
  type: proxy
  proxy:
    url: https://www.kinopoisk.ru/
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520

ignoreClientBandwidth: false
EOF
  chmod 600 /etc/hysteria/config.yaml
  say "конфиг создан"
fi

# Прыжки по портам. Диапазон 20000-50000 забирает ВЕСЬ UDP на этих портах и
# отдаёт его Hysteria, поэтому любую новую службу на UDP из этого диапазона
# тихо лишает связи: TCP работает, UDP уходит в чужой процесс. Новые входы
# заводить только ВЫШЕ 50000.
HOPDIR=/etc/systemd/system/hysteria-server.service.d
if [ -f "$HOPDIR/porthop.conf" ]; then
  skip "прыжки по портам уже настроены"
elif [ "$DRY" = 1 ]; then
  say "[сухой прогон] добавил бы прыжки по портам 20000-50000 → 36712 на $IFACE"
else
  install -d -m 755 "$HOPDIR"
  cat > "$HOPDIR/porthop.conf" <<EOF
[Service]
ExecStartPost=/bin/sh -c 'iptables -t nat -C PREROUTING -i $IFACE -p udp --dport 20000:50000 -j REDIRECT --to-ports 36712 2>/dev/null || iptables -t nat -I PREROUTING 1 -i $IFACE -p udp --dport 20000:50000 -j REDIRECT --to-ports 36712'
ExecStopPost=/bin/sh -c 'iptables -t nat -D PREROUTING -i $IFACE -p udp --dport 20000:50000 -j REDIRECT --to-ports 36712 2>/dev/null || true'
EOF
  systemctl daemon-reload
  say "прыжки по портам 20000-50000 → 36712 добавлены"
fi

# --- 8. nginx --------------------------------------------------------------
head_ "nginx"
SITE=/etc/nginx/conf.d/vpn-help.conf
if [ -f "$SITE" ] || grep -rqs "vpn-help" /etc/nginx/sites-enabled/ 2>/dev/null; then
  skip "конфиг страницы уже есть — не переписываю"
elif [ "$DRY" = 1 ]; then
  say "[сухой прогон] положил бы $SITE из etc/nginx-vpn-help.conf.example"
else
  API_PATH=$(get API_PATH | tr -d '/')
  sed -e "s#SERVER_IP#$IP4#g" -e "s#PAGE_PATH#$PAGE_PATH#g" -e "s#API_PATH#$API_PATH#g" \
      etc/nginx-vpn-help.conf.example > "$SITE"
  install -d -m 755 "/var/www/vpn-help/$PAGE_PATH"
  [ -f "/var/www/vpn-help/$PAGE_PATH/index.html" ] || cp www/index.html "/var/www/vpn-help/$PAGE_PATH/index.html"
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx; say "страница будет на https://$IP4:2053/$PAGE_PATH/"
  else
    rm -f "$SITE"; say "ВНИМАНИЕ: nginx не принял конфиг, файл убран. Проверьте nginx -t"
  fi
fi

# --- итог ------------------------------------------------------------------
head_ "итог"
for S in x-ui hysteria-server nginx; do
  # is-active печатает состояние И возвращает ненулевой код, если служба не
  # работает: без `|| true` сюда печаталось бы и «inactive», и «нет» разом.
  ST=$(systemctl is-active "$S" 2>/dev/null || true)
  printf '  %-18s %s\n' "$S" "${ST:-не установлена}"
done
echo
PANEL_PATH=$(get PANEL_PATH); PANEL_PORT=$(get PANEL_PORT)
[ -n "$PANEL_PORT" ] && say "панель: http://$IP4:$PANEL_PORT/${PANEL_PATH:-} (логин и пароль в $CFG)"
say "основание готово. Дальше: ./install.sh — он поставит подписки,"
say "выдачу доступов, Shadowsocks, обфускацию и сторож утечек."
[ "$DRY" = 1 ] && say "(это был сухой прогон, на диск ничего не записано)"
