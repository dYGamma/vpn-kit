#!/usr/bin/env bash
# Установка обвязки vpn-kit поверх уже работающих 3x-ui и Hysteria2.
#
# Идемпотентен: повторный запуск ничего не портит. Ничего не перезапускает без
# нужды — на боевом узле лишний перезапуск Xray рвёт сессии всем сразу.
set -u
export LC_ALL=C.UTF-8
cd "$(dirname "$0")"

XUI_DB=/etc/x-ui/x-ui.db
XRAY=/usr/local/x-ui/bin/xray-linux-amd64
CFG=/etc/vpn-issue/config

say()  { printf '  %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }
die()  { printf '\nОСТАНОВ: %s\n' "$*" >&2; exit 1; }

# --- проверки до любых изменений ------------------------------------------
head_ "проверка окружения"
[ "$(id -u)" = 0 ] || die "нужны права root"
[ -f "$XUI_DB" ] || die "нет базы панели $XUI_DB — сначала поставьте 3x-ui"
[ -x "$XRAY" ]   || die "нет бинаря Xray $XRAY"
command -v sqlite3 >/dev/null || die "нужен sqlite3: apt install sqlite3"
command -v python3 >/dev/null || die "нужен python3"
[ -f "$CFG" ] || die "нет $CFG — скопируйте etc/vpn-issue.config.example и заполните"
for K in SECRET PAGE_BASE API_PATH; do
  grep -qE "^$K=.+" "$CFG" || die "в $CFG не заполнено $K"
  grep -qE "^$K=(YOUR_|SERVER_IP|API_PATH$)" "$CFG" && die "в $CFG значение $K осталось образцом"
done
say "окружение в порядке"

HYS=$(command -v hysteria || true)
[ -n "$HYS" ] || say "внимание: hysteria не найдена — входы Hysteria2 поставлены не будут"

# --- скрипты ---------------------------------------------------------------
head_ "скрипты"
install -d -m 755 /opt/vpn-issue /usr/local/sbin
for F in service/*.py; do install -m 644 "$F" /opt/vpn-issue/; done
chmod 755 /opt/vpn-issue/server.py 2>/dev/null || true
for F in bin/*; do
  case "$(basename "$F")" in
    vpnctl) install -m 755 "$F" /usr/local/bin/vpnctl ;;
    *)      install -m 755 "$F" /usr/local/sbin/ ;;
  esac
done
say "разложено: $(ls bin | wc -l) в sbin, $(ls service | wc -l) в /opt/vpn-issue"

# --- резервный вход Shadowsocks-2022 --------------------------------------
head_ "резервный вход Shadowsocks-2022"
install -d -m 700 /etc/xray-ss
if [ ! -f /etc/xray-ss/keys.json ]; then
  say "ключей нет, генерирую"
fi
/usr/local/sbin/xray-ss-sync.py || die "не удалось собрать конфиг Shadowsocks"
chmod 600 /etc/xray-ss/config.json /etc/xray-ss/keys.json
"$XRAY" run -test -c /etc/xray-ss/config.json >/dev/null 2>&1 \
  || die "ядро не приняло конфиг Shadowsocks — смотрите /etc/xray-ss/config.json"
say "конфиг принят ядром"

# --- Hysteria2 с обфускацией ----------------------------------------------
head_ "Hysteria2 с обфускацией"
if [ -n "$HYS" ] && [ -f /etc/hysteria/config.yaml ]; then
  if [ ! -f /etc/hysteria/obfs-password ]; then
    head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24 > /etc/hysteria/obfs-password
    chmod 600 /etc/hysteria/obfs-password
    say "пароль обфускации создан"
  fi
  if [ ! -f /etc/hysteria/config-obfs.yaml ]; then
    # Порт ВЫШЕ диапазона прыжков: иначе UDP этого входа перехватит основной
    sed 's/^listen: :[0-9]*/listen: :51712/' /etc/hysteria/config.yaml > /etc/hysteria/config-obfs.yaml
    {
      echo
      echo "obfs:"
      echo "  type: salamander"
      echo "  salamander:"
      echo "    password: $(cat /etc/hysteria/obfs-password)"
    } >> /etc/hysteria/config-obfs.yaml
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
for F in units/*; do install -m 644 "$F" /etc/systemd/system/; done
systemctl daemon-reload
for U in vpn-issue xray-ss hysteria-auth; do
  [ -f /etc/systemd/system/$U.service ] || continue
  [ "$U" = hysteria-auth ] && [ -z "$HYS" ] && continue
  systemctl enable --now $U >/dev/null 2>&1 && say "$U запущен"
done
if [ -n "$HYS" ] && [ -f /etc/hysteria/config-obfs.yaml ]; then
  systemctl enable --now hysteria-obfs >/dev/null 2>&1 && say "hysteria-obfs запущен"
fi
for T in rules-mirror.timer leak-scan.timer xray-ss-sync.timer \
         hysteria-links-sync.timer ru-allowlist.timer; do
  [ -f /etc/systemd/system/$T ] || continue
  systemctl enable --now $T >/dev/null 2>&1 && say "$T включён"
done

# --- ссылки клиентам ------------------------------------------------------
head_ "ссылки клиентам"
[ -f /etc/systemd/system/xray-ss-sync.service ] && systemctl start xray-ss-sync.service 2>/dev/null || true
[ -f /etc/systemd/system/hysteria-links-sync.service ] && systemctl start hysteria-links-sync.service 2>/dev/null || true
say "клиентов в базе: $(sqlite3 "$XUI_DB" 'select count(*) from clients;' 2>/dev/null || echo '?')"

# --- итог -----------------------------------------------------------------
head_ "итог"
for S in x-ui xray-ss hysteria-server hysteria-obfs hysteria-auth vpn-issue nginx; do
  printf '  %-18s %s\n' "$S" "$(systemctl is-active $S 2>/dev/null || echo нет)"
done
echo
say "страницу положите в /var/www/vpn-help/<секретный путь>/index.html из www/"
say "правила nginx возьмите из etc/nginx-vpn-help.conf.example"
say "панель наблюдения: vpnctl"
