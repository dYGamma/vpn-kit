#!/usr/bin/env bash
# Установка обвязки vpn-kit поверх уже работающих 3x-ui и Hysteria2.
#
# В репозитории файлы лежат с заглушками (SERVER_IP, PAGE_PATH, API_PATH,
# SUPPORT_URL) — иначе в них попали бы адрес узла и секретные пути. Установщик
# подставляет настоящие значения из /etc/vpn-issue/config ПРИ КОПИРОВАНИИ.
#
# Это не мелочь: первая версия копировала файлы как есть и затёрла рабочую
# установку шаблонами. Наружу это вылезло как «502 при установке подписки» и
# нерабочие ссылки Hysteria2 у людей — в них вместо адреса стояло слово
# SERVER_IP. Поэтому здесь: подстановка обязательна, остаток заглушек — останов,
# и есть --dry-run, чтобы проверить результат до записи в рабочие пути.
set -u
export LC_ALL=C.UTF-8
cd "$(dirname "$0")"

XUI_DB=/etc/x-ui/x-ui.db
XRAY=/usr/local/x-ui/bin/xray-linux-amd64
CFG=/etc/vpn-issue/config
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say()   { printf '  %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }
die()   { printf '\nОСТАНОВ: %s\n' "$*" >&2; exit 1; }

# --- проверки до любых изменений ------------------------------------------
head_ "проверка окружения"
[ "$(id -u)" = 0 ] || die "нужны права root"
[ -f "$XUI_DB" ] || die "нет базы панели $XUI_DB — сначала прогоните ./bootstrap.sh"
[ -x "$XRAY" ]   || die "нет бинаря Xray $XRAY"
command -v sqlite3 >/dev/null || die "нужен sqlite3: apt install sqlite3"
command -v python3 >/dev/null || die "нужен python3"
[ -f "$CFG" ] || die "нет $CFG — скопируйте etc/vpn-issue.config.example и заполните"

get() { grep -oE "^$1=.*" "$CFG" | head -1 | cut -d= -f2-; }
SECRET=$(get SECRET)
PAGE_BASE=$(get PAGE_BASE)
API_PATH=$(get API_PATH | tr -d '/')
SERVER_IP=$(get SERVER_IP)
SUPPORT_URL=$(get SUPPORT_URL)
PAGE_PATH=$(basename "$(printf '%s' "$PAGE_BASE" | sed 's#/*$##')")

# Если адрес не задан отдельно — берём его из PAGE_BASE
[ -n "$SERVER_IP" ] || SERVER_IP=$(printf '%s' "$PAGE_BASE" | sed -nE 's#https?://([^:/]+).*#\1#p')
# Ссылка поддержки — единственное, чего машина знать не может. Раньше здесь
# стояла ЗАГЛУШКА: подставлялась сама в себя, а проверка ниже находила её и
# роняла установку. Теперь: пробуем узнать имя телеграм-бота по его токену,
# а если и его нет — направляем такие ссылки на саму страницу установки.
# Мёртвых ссылок и остатков заглушек в выдаче быть не должно.
# Заглушка в конфиге — это то же самое, что пусто: у кого она уже записана
# прошлыми версиями, установка иначе встанет ровно на проверке ниже.
case "$SUPPORT_URL" in *YourBotName*) SUPPORT_URL="" ;; esac
if [ -z "$SUPPORT_URL" ]; then
  TOK=$(grep -hoE '^TG_BOT_TOKEN=.*' /etc/vpn-issue/config /etc/AVS/office.env 2>/dev/null \
        | head -1 | cut -d= -f2-)
  if [ -n "$TOK" ]; then
    BOTNAME=$(curl -s -m 10 "https://api.telegram.org/bot$TOK/getMe" 2>/dev/null \
      | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["result"]["username"])
except Exception: print("")' 2>/dev/null)
    [ -n "$BOTNAME" ] && SUPPORT_URL="https://t.me/$BOTNAME"
  fi
fi
if [ -z "$SUPPORT_URL" ]; then
  SUPPORT_URL="$PAGE_BASE/"
  SUPPORT_NOTE=1
fi

[ "${SUPPORT_NOTE:-0}" = 1 ] && say "SUPPORT_URL не задан — ссылки «написать за помощью» ведут на саму страницу"

for V in SECRET PAGE_BASE API_PATH SERVER_IP PAGE_PATH; do
  eval "v=\$$V"
  [ -n "$v" ] || die "в $CFG не удалось получить $V"
  case "$v" in
    YOUR_*|SERVER_IP|PAGE_PATH|API_PATH) die "$V в $CFG осталось заглушкой ($v)" ;;
  esac
  [ ${#v} -ge 4 ] || die "$V подозрительно короткое: $v"
  say "$V получен (${#v} симв.)"
done

# --- подстановка -----------------------------------------------------------
head_ "подстановка значений"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -r bin service bot units www "$STAGE"/ 2>/dev/null
# Порядок важен: SERVER_IP подставляем раньше, иначе он попадёт под другие замены
find "$STAGE" -type f -exec sed -i \
  -e "s#SERVER_IP#$SERVER_IP#g" \
  -e "s#PAGE_PATH#$PAGE_PATH#g" \
  -e "s#API_PATH#$API_PATH#g" \
  -e "s#https://t.me/YourBotName#$SUPPORT_URL#g" \
  -e "s#YourBotName#$(basename "$SUPPORT_URL")#g" {} +

LEFT=$(grep -rlE 'SERVER_IP|PAGE_PATH|API_PATH|YourBotName' "$STAGE" 2>/dev/null || true)
[ -z "$LEFT" ] || die "заглушки остались в: $(echo "$LEFT" | sed "s#$STAGE/##" | tr '\n' ' ')"
say "заглушек не осталось ни в одном файле"

for F in "$STAGE"/service/*.py "$STAGE"/bin/*.py; do
  python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$F" \
    || die "после подстановки сломался синтаксис: $(basename "$F")"
done
for F in "$STAGE"/bin/*.sh "$STAGE"/bot/*.sh; do
  [ -f "$F" ] && { bash -n "$F" || die "после подстановки сломался синтаксис: $(basename "$F")"; }
done
say "синтаксис всех файлов в порядке"

if [ "$DRY" = 1 ]; then
  head_ "это была проверка (--dry-run)"
  say "подстановка прошла, в рабочие пути ничего не записано"
  say "готовые файлы лежали в $STAGE и сейчас будут удалены"
  exit 0
fi

# --- раскладка -------------------------------------------------------------
head_ "скрипты"
install -d -m 755 /opt/vpn-issue /usr/local/sbin
for F in "$STAGE"/service/*.py; do install -m 640 "$F" /opt/vpn-issue/; done
for F in "$STAGE"/bin/*; do
  case "$(basename "$F")" in
    vpnctl) install -m 755 "$F" /usr/local/bin/vpnctl ;;
    *)      install -m 750 "$F" /usr/local/sbin/ ;;
  esac
done
say "разложено: $(ls "$STAGE"/bin | wc -l) в sbin, $(ls "$STAGE"/service | wc -l) в /opt/vpn-issue"

# --- резервный вход Shadowsocks-2022 --------------------------------------
head_ "резервный вход Shadowsocks-2022"
install -d -m 700 /etc/xray-ss
/usr/local/sbin/xray-ss-sync.py; RC=$?
case $RC in 0|3) : ;; *) die "не удалось собрать конфиг Shadowsocks" ;; esac
chmod 600 /etc/xray-ss/config.json /etc/xray-ss/keys.json 2>/dev/null || true
"$XRAY" run -test -c /etc/xray-ss/config.json >/dev/null 2>&1 \
  || die "ядро не приняло конфиг Shadowsocks"
say "конфиг принят ядром"

# --- Hysteria2 с обфускацией ----------------------------------------------
head_ "Hysteria2 с обфускацией"
HYS=$(command -v hysteria || true)
if [ -n "$HYS" ] && [ -f /etc/hysteria/config.yaml ]; then
  [ -f /etc/hysteria/obfs-password ] || {
    head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24 > /etc/hysteria/obfs-password
    chmod 600 /etc/hysteria/obfs-password; say "пароль обфускации создан"; }
  if [ ! -f /etc/hysteria/config-obfs.yaml ]; then
    # Порт ВЫШЕ диапазона прыжков основного входа: иначе его UDP перехватывается
    sed 's/^listen: :[0-9]*/listen: :51712/' /etc/hysteria/config.yaml > /etc/hysteria/config-obfs.yaml
    printf '\nobfs:\n  type: salamander\n  salamander:\n    password: %s\n' \
      "$(cat /etc/hysteria/obfs-password)" >> /etc/hysteria/config-obfs.yaml
    chmod 600 /etc/hysteria/config-obfs.yaml
    say "конфиг создан на порту 51712"
  else
    say "конфиг уже есть, не трогаю"
  fi
else
  say "пропущено: нет hysteria или её основного конфига"
fi

# --- зеркало баз правил ---------------------------------------------------
head_ "зеркало баз правил"
install -d -m 755 /var/www/vpn-help/rules
/usr/local/sbin/rules-mirror.sh || say "часть баз не скачалась — прогоните позже вручную"
say "файлов в зеркале: $(ls /var/www/vpn-help/rules 2>/dev/null | wc -l)"

# --- юниты ----------------------------------------------------------------
head_ "службы и расписания"
for F in "$STAGE"/units/*; do install -m 644 "$F" /etc/systemd/system/; done
systemctl daemon-reload
for U in vpn-issue xray-ss; do
  systemctl enable --now $U >/dev/null 2>&1 && say "$U запущен"
done
[ -n "$HYS" ] && {
  systemctl enable --now hysteria-auth >/dev/null 2>&1 && say "hysteria-auth запущен"
  [ -f /etc/hysteria/config-obfs.yaml ] && systemctl enable --now hysteria-obfs >/dev/null 2>&1 \
    && say "hysteria-obfs запущен"; }
for T in rules-mirror.timer leak-scan.timer xray-ss-sync.timer \
         hysteria-links-sync.timer ru-allowlist.timer; do
  [ -f /etc/systemd/system/$T ] && systemctl enable --now $T >/dev/null 2>&1 && say "$T включён"
done

# --- ссылки клиентам ------------------------------------------------------
head_ "ссылки клиентам"
systemctl start xray-ss-sync.service 2>/dev/null || true
systemctl start hysteria-links-sync.service 2>/dev/null || true
BAD=$(sqlite3 "$XUI_DB" "select count(*) from client_external_links where value like '%SERVER_IP%';" 2>/dev/null || echo 0)
[ "$BAD" = 0 ] || die "в базе $BAD ссылок с заглушкой — почините и прогоните ещё раз"
say "клиентов: $(sqlite3 "$XUI_DB" 'select count(*) from clients;' 2>/dev/null || echo '?'), битых ссылок: 0"

# --- итог -----------------------------------------------------------------
head_ "итог"
for S in x-ui xray-ss hysteria-server hysteria-obfs hysteria-auth vpn-issue nginx; do
  printf '  %-18s %s\n' "$S" "$(systemctl is-active $S 2>/dev/null || echo нет)"
done
echo
say "страницу положите в /var/www/vpn-help/$PAGE_PATH/index.html из www/"
say "правила nginx возьмите из etc/nginx-vpn-help.conf.example"
say "панель наблюдения: vpnctl"
