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
NO_INSTALL=0
for A in "$@"; do
  case "$A" in
    --dry-run)    DRY=1 ;;
    --no-install) NO_INSTALL=1 ;;
    *) printf 'использование: %s [--dry-run] [--no-install]\n' "$0" >&2; exit 2 ;;
  esac
done

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
for c in curl sqlite3 python3 nginx socat openssl upnpc; do
  # пакет с upnpc называется иначе, чем сама команда
  case "$c" in upnpc) PKG=miniupnpc ;; *) PKG="$c" ;; esac
  command -v "$c" >/dev/null || NEED="$NEED $PKG"
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
    : > /etc/vpn-issue/.panel-configured
    systemctl restart x-ui >/dev/null 2>&1 || true
  fi
elif [ -f /etc/vpn-issue/.panel-configured ]; then
  skip "панель уже настроена"
else
  skip "панели нет — порт и учётку задам после установки"
fi

# Секретный путь панели придумывает установщик 3x-ui и пишет в
# install-result.env. Забираем его отдельным шагом, а не внутри первичной
# настройки: иначе на повторном прогоне (когда настройка пропускается) путь
# так и не попадёт в конфиг, и человек получит адрес панели без пути.
if [ "$DRY" = 0 ] && [ -f "$CFG" ] && ! grep -q '^PANEL_PATH=' "$CFG"; then
  WBP=$(grep -oE '^WebBasePath=.*' /etc/x-ui/install-result.env 2>/dev/null | cut -d= -f2- | tr -d '"')
  [ -z "$WBP" ] && [ -f "$XUI_DB" ] && WBP=$(sqlite3 "$XUI_DB" \
    "select value from settings where key='webBasePath';" 2>/dev/null | tr -d '/')
  if [ -n "$WBP" ]; then
    printf 'PANEL_PATH=%s\n' "$WBP" >> "$CFG"
    say "секретный путь панели записан в $CFG"
  fi
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
# --- локальный фаервол ----------------------------------------------------
# Ubuntu часто идёт с включённым ufw, который пропускает только SSH. Тогда все
# наши порты закрыты — причём изнутри сети тоже, и человек ищет причину в
# панели, в роутере, где угодно, только не здесь. Открываем явно.
head_ "локальный фаервол"
FW_PORTS="80/tcp 443/tcp 8443/tcp 2053/tcp 36712/udp 20000:50000/udp"
[ -n "${PANEL_PORT:-}" ] && FW_PORTS="$FW_PORTS $PANEL_PORT/tcp"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi '^Status: active'; then
  if [ "$DRY" = 1 ]; then
    say "[сухой прогон] открыл бы в ufw: $FW_PORTS"
  else
    for FP in $FW_PORTS; do ufw allow "$FP" >/dev/null 2>&1; done
    say "в ufw открыто: $FW_PORTS"
  fi
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  if [ "$DRY" = 1 ]; then
    say "[сухой прогон] открыл бы в firewalld: $FW_PORTS"
  else
    # firewalld пишет диапазон через дефис, а не через двоеточие, как ufw:
    # 20000:50000/udp у него не принимается вовсе.
    for FP in $FW_PORTS; do firewall-cmd --permanent --add-port="${FP/:/-}" >/dev/null 2>&1; done
    firewall-cmd --reload >/dev/null 2>&1
    say "в firewalld открыто: $FW_PORTS"
  fi
else
  skip "локальный фаервол не включён — открывать нечего"
fi

# --- проброс портов на роутере ------------------------------------------
if is_private "$LOCAL_IP"; then
  head_ "проброс портов на роутере"
  if [ "$DRY" = 1 ]; then
    say "[сухой прогон] попробовал бы открыть порты через UPnP"
  elif ! command -v upnpc >/dev/null; then
    say "нет upnpc — пробросьте порты на роутере руками"
  else
    UP=$(upnpc -s 2>/dev/null)
    EXT=$(printf '%s' "$UP" | grep -oE 'ExternalIPAddress[ =]+[0-9.]+' | grep -oE '[0-9.]+$')
    if [ -z "$EXT" ]; then
      say "роутер не отвечает по UPnP (или он выключен в его настройках)"
      say "пробросьте вручную на $LOCAL_IP: TCP 80, 443, 8443, 2053 и UDP 36712"
    elif [ "$EXT" != "$IP4" ]; then
      # Роутер видит снаружи не тот адрес, что весь интернет, — значит выше
      # стоит ещё один NAT провайдера. Пробрасывать бесполезно: до роутера
      # входящее соединение просто не дойдёт. Лечится только белым адресом
      # у провайдера или узлом на обычном VPS.
      say "у роутера снаружи адрес $EXT, а интернет видит $IP4 — это NAT провайдера"
      say "проброс тут не поможет: до роутера входящее соединение не доходит."
      say "Нужен белый адрес у провайдера, либо ставьте узел на обычный VPS."
    else
      OKN=0; BADN=0
      for R in "80 TCP" "443 TCP" "8443 TCP" "2053 TCP" "36712 UDP"; do
        set -- $R
        if upnpc -e "vpn-kit" -a "$LOCAL_IP" "$1" "$1" "$2" >/dev/null 2>&1; then
          OKN=$((OKN+1))
        else
          BADN=$((BADN+1)); say "не удалось открыть $2 $1"
        fi
      done
      say "открыто портов: $OKN, не удалось: $BADN"
      # Диапазон прыжков — тридцать тысяч портов, по UPnP их не открыть.
      # Основной вход на 36712 работает и без них, прыжки просто не включатся.
      say "диапазон прыжков UDP 20000-50000 через UPnP не открыть — если он нужен,"
      say "пробросьте его на роутере одним правилом на $LOCAL_IP"
    fi
  fi
fi

head_ "сертификат"
# Самоподписанный распознаём по совпадению издателя с владельцем. Это важно:
# такой сертификат — временная затычка, чтобы узел собрался целиком, и на
# каждом следующем прогоне надо снова пробовать выпустить настоящий, а не
# считать «сертификат есть, пропускаем».
SELF_SIGNED=0
if [ -s "$CERT_DIR/fullchain.pem" ]; then
  CS=$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject 2>/dev/null | sed 's/^subject=//')
  CI=$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
  [ -n "$CS" ] && [ "$CS" = "$CI" ] && SELF_SIGNED=1
fi

if [ -s "$CERT_DIR/fullchain.pem" ] && [ "$SELF_SIGNED" = 0 ]; then
  skip "настоящий сертификат уже лежит в $CERT_DIR"
elif [ "$DRY" = 1 ]; then
  say "[сухой прогон] выпустил бы сертификат Let's Encrypt на адрес $IP4,"
  say "[сухой прогон] а если не вышло — сделал бы временный самоподписанный"
else
  [ "$SELF_SIGNED" = 1 ] && say "сейчас стоит временный самоподписанный — пробую получить настоящий"
  [ -d /root/.acme.sh ] || run "curl -s https://get.acme.sh | sh -s email=admin@$IP4"
  install -d -m 700 "$CERT_DIR"
  # standalone: порт 80 на время выпуска должен быть свободен
  systemctl stop nginx >/dev/null 2>&1 || true
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
  if /root/.acme.sh/acme.sh --issue --standalone -d "$IP4" --keylength ec-256 >/dev/null 2>&1; then
    /root/.acme.sh/acme.sh --install-cert -d "$IP4" --ecc \
      --key-file "$CERT_DIR/privkey.pem" --fullchain-file "$CERT_DIR/fullchain.pem" \
      --reloadcmd 'systemctl restart x-ui; systemctl restart hysteria-server; systemctl reload nginx' >/dev/null 2>&1
    SELF_SIGNED=0
    say "сертификат выпущен и прописан на автопродление"
  elif [ "$SELF_SIGNED" = 1 ]; then
    say "настоящий выпустить снова не вышло — оставляю временный"
  else
    # Просить человека сгенерировать сертификат руками — значит не
    # автоматизировать ровно то, ради чего скрипт и написан. Делаем сами:
    # без сертификата не поднимаются ни Hysteria, ни страница, и узел
    # остаётся полусобранным. Настоящий подменит этот файл на месте.
    say "выпуск не удался (нужен доступ снаружи по порту 80)"
    say "делаю временный самоподписанный, чтобы узел собрался целиком"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" -days 3650 \
      -subj "/CN=$IP4" -addext "subjectAltName=IP:$IP4" >/dev/null 2>&1
    if [ -s "$CERT_DIR/fullchain.pem" ]; then
      chmod 600 "$CERT_DIR/privkey.pem"; SELF_SIGNED=1
      say "временный сертификат готов — клиенты ему не поверят, узел поднимется"
    else
      say "ВНИМАНИЕ: не удалось сделать даже временный, проверьте openssl"
    fi
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
  say "ставлю Hysteria2 (тянется с GitHub, из России это бывает долго)"
  # Скачиваем в файл и ПРОВЕРЯЕМ, а не льём в bash по трубе. Обрыв на середине
  # даёт половину скрипта, и bash её честно выполняет до места разрыва:
  # `syntax error: unexpected end of file` и наполовину поставленная система.
  # `bash -n` ловит обрыв надёжно — оборванный скрипт не разбирается.
  HYSI=$(mktemp)
  if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 \
       -o "$HYSI" https://get.hy2.sh/ 2>/dev/null && [ -s "$HYSI" ] && bash -n "$HYSI" 2>/dev/null; then
    bash "$HYSI" || say "установщик отработал с ошибкой"
  else
    say "установщик скачался не полностью — не запускаю его"
  fi
  rm -f "$HYSI"
  if ! command -v hysteria >/dev/null; then
    say "пробую запасной путь — прямая загрузка бинаря"
    HYSB=$(mktemp)
    if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 -o "$HYSB" \
         https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64 \
       && chmod 755 "$HYSB" && "$HYSB" version >/dev/null 2>&1; then
      # version запускаем ДО установки: оборванная закачка даёт битый бинарь,
      # который молча не стартует, а служба уходит в цикл перезапусков.
      install -m 755 "$HYSB" /usr/local/bin/hysteria; rm -f "$HYSB"
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
      rm -f "$HYSB"
      say "ВНИМАНИЕ: Hysteria2 поставить не удалось — GitHub недоступен."
      say "Скачайте hysteria-linux-amd64 любым способом, положите в /usr/local/bin/hysteria,"
      say "сделайте chmod 755 и запустите bootstrap.sh снова — он продолжит с этого места."
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

# Запуск. Раньше этого не делал ни bootstrap, ни install: бинарь стоял, конфиг
# лежал, юнит был — а служба не работала, и человек искал причину в клиенте.
if [ "$DRY" = 1 ]; then
  say "[сухой прогон] включил бы и запустил hysteria-server"
elif command -v hysteria >/dev/null && [ -f /etc/hysteria/config.yaml ]; then
  if [ ! -s "$CERT_DIR/fullchain.pem" ]; then
    say "не запускаю: нет сертификата в $CERT_DIR, без него Hysteria не поднимется"
  else
    systemctl enable --now hysteria-server >/dev/null 2>&1
    sleep 2
    if systemctl is-active --quiet hysteria-server; then
      say "hysteria-server запущен"
    else
      say "ВНИМАНИЕ: hysteria-server не поднялся — journalctl -u hysteria-server -n 30"
    fi
  fi
else
  say "не запускаю: нет бинаря или конфига"
fi

# --- 8. nginx --------------------------------------------------------------
head_ "nginx"
SITE=/etc/nginx/conf.d/vpn-help.conf
if [ -f "$SITE" ] || grep -rqs "vpn-help" /etc/nginx/sites-enabled/ 2>/dev/null; then
  skip "конфиг страницы уже есть — не переписываю"
elif [ "$DRY" = 0 ] && [ ! -s "$CERT_DIR/fullchain.pem" ]; then
  # Раньше конфиг писался всегда, nginx его не принимал из-за отсутствующего
  # сертификата, и человек получал «ВНИМАНИЕ: nginx не принял конфиг» без
  # объяснения причины. Причина одна и та же, так и говорим.
  say "пропускаю: нет сертификата в $CERT_DIR — nginx с таким конфигом не стартует"
  say "положите сертификат и запустите bootstrap.sh снова"
elif [ "$DRY" = 1 ]; then
  say "[сухой прогон] положил бы $SITE из etc/nginx-vpn-help.conf.example"
else
  API_PATH=$(get API_PATH | tr -d '/')
  sed -e "s#SERVER_IP#$IP4#g" -e "s#PAGE_PATH#$PAGE_PATH#g" -e "s#API_PATH#$API_PATH#g" \
      etc/nginx-vpn-help.conf.example > "$SITE"
  install -d -m 755 "/var/www/vpn-help/$PAGE_PATH"
  [ -f "/var/www/vpn-help/$PAGE_PATH/index.html" ] || cp www/index.html "/var/www/vpn-help/$PAGE_PATH/index.html"
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    if is_private "$LOCAL_IP"; then
      say "страница: https://$LOCAL_IP:2053/$PAGE_PATH/ — из домашней сети"
      say "снаружи она откроется по https://$IP4:2053/$PAGE_PATH/, когда пробросите порт 2053"
    else
      say "страница будет на https://$IP4:2053/$PAGE_PATH/"
    fi
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

# Разделяем НЕПОЛАДКИ и ЗАМЕЧАНИЯ. Раньше всё валилось в одну кучу, и узел,
# у которого работали все три службы, объявлялся неполным из-за того, что
# машина стоит за NAT, — а обвязку при этом ставить запрещалось. NAT это
# внешнее обстоятельство, install.sh от него не зависит вообще.
MISS=""; WARN=""
command -v hysteria >/dev/null || MISS="$MISS\n  · Hysteria2 не установлена (GitHub был недоступен)"
[ -s "$CERT_DIR/fullchain.pem" ] || MISS="$MISS\n  · нет сертификата в $CERT_DIR — без него не поднимутся ни Hysteria, ни страница"
[ -f /etc/nginx/conf.d/vpn-help.conf ] || grep -rqs "vpn-help" /etc/nginx/sites-enabled/ 2>/dev/null \
  || MISS="$MISS\n  · страница установки не отдаётся: конфиг nginx не положен"

[ "${SELF_SIGNED:-0}" = 1 ] && WARN="$WARN\n  · сертификат временный, самоподписанный: узел работает, но клиенты ему не поверят.\n    Настоящий выпустится сам на следующем прогоне, как только адрес станет доступен снаружи по порту 80"
is_private "$LOCAL_IP" && WARN="$WARN\n  · машина за NAT: снаружи ничего не откроется, пока на роутере не проброшены порты"

PANEL_PATH=$(get PANEL_PATH); PANEL_PORT=$(get PANEL_PORT)
if [ -n "$PANEL_PORT" ]; then
  # За NAT печатаем ЛОКАЛЬНЫЙ адрес. По внешнему из своей же сети браузер
  # упирается в роутер: разворачивать запрос обратно внутрь себя (hairpin NAT)
  # большинство домашних роутеров не умеет, и человек получает
  # ERR_CONNECTION_REFUSED на работающей панели.
  if is_private "$LOCAL_IP"; then
    say "панель: http://$LOCAL_IP:$PANEL_PORT/${PANEL_PATH:-} — открывать из домашней сети"
    say "(снаружи она намеренно не выставлена: порт панели не пробрасываем)"
  else
    say "панель: http://$IP4:$PANEL_PORT/${PANEL_PATH:-}"
  fi
  say "логин и пароль в $CFG"
fi
[ -n "$WARN" ] && printf '\n  ЗАМЕЧАНИЯ:%b\n' "$WARN"

if [ -n "$MISS" ]; then
  printf '\n  ОСНОВАНИЕ НЕПОЛНОЕ, не хватает:%b\n\n' "$MISS"
  say "Допоставьте недостающее и запустите bootstrap.sh снова — он продолжит"
  say "с этого места и уже сделанное не тронет. install.sh пока не запускайте."
  exit 1
fi

echo
if [ "$DRY" = 1 ]; then
  say "основание готово, дальше запустился бы install.sh"
  say "(это был сухой прогон, на диск ничего не записано)"
  exit 0
fi
if [ "$NO_INSTALL" = 1 ]; then
  say "основание готово. Дальше: ./install.sh — он поставит подписки,"
  say "выдачу доступов, Shadowsocks, обфускацию и сторож утечек."
  exit 0
fi
# Ради этого скрипт и написан: человек не должен вводить руками ничего, что
# машина может сделать сама. Основание собрано — сразу ставим обвязку.
say "основание готово, ставлю обвязку"
exec ./install.sh
