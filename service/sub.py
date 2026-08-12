# -*- coding: utf-8 -*-
"""Генератор подписок под конкретное приложение.

Встроенный генератор панели отдаёт всем один и тот же список ссылок, а правила
обхода прикладывает заголовком, который читают только Happ и Hiddify. Остальные
приложения гонят в тоннель весь трафик, включая российский, — из-за этого ВК,
Яндекс и банки видели адрес нашего сервера в Амстердаме.

Здесь на каждое ядро собирается свой конфиг, и правила обхода лежат ВНУТРИ него.
Для клиента `direct` означает «идти напрямую со своего адреса», то есть
российское до сервера просто не доезжает.

Базы правил зеркалированы на этот же сервер (/var/www/vpn-help/rules): тянуть их
с GitHub нельзя — он из России доступен через раз, а без правил подписка
бесполезна ровно в тот момент, когда её ставят.
"""

import base64
import json
import re
import sqlite3
import ssl
import time
import urllib.request
from urllib.parse import urlparse, parse_qs, unquote

DB = "/etc/x-ui/x-ui.db"
RULES_DIR = "/var/www/vpn-help/rules"
# По своему же публичному адресу, а не по 127.0.0.1: сертификат выписан на IP,
# и так проверка TLS проходит штатно. Соединение всё равно не покидает машину.
XUI_SUB = "https://SERVER_IP:2096/sub/"
RULES_BASE = "https://SERVER_IP:2053/rules"
BASE_URL = "https://SERVER_IP:2053/PAGE_PATH"
UPDATE_HOURS = 6

# Яндекс-DNS: российские домены разрешаются напрямую с адреса пользователя.
# Через тоннель они дали бы ответы для Амстердама, и CDN отдавал бы чужие узлы.
DNS_RU = ["77.88.8.8", "77.88.8.1"]
DNS_OUT = "https://1.1.1.1/dns-query"

_cache = {}
_CACHE_TTL = 60


# --- источник данных -------------------------------------------------------

def _xui_links(sub_id):
    """Три ссылки подключения, как их отдаёт панель. Она — источник истины по
    ключам Reality и паролям, поэтому параметры не выводим заново, а читаем."""
    req = urllib.request.Request(XUI_SUB + sub_id, headers={"User-Agent": "sub-builder"})
    # Повторяем при срыве: разовая заминка резолвера или панели не должна
    # превращаться в 502. Приложение на ошибку может стереть профиль целиком,
    # и человек останется без доступа из-за мгновенного сбоя.
    last = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=10,
                                        context=ssl.create_default_context()) as r:
                raw = r.read()
            break
        except Exception as e:
            last = e
            if attempt < 2:
                time.sleep(0.7 * (attempt + 1))
    else:
        raise last
    try:
        txt = base64.b64decode(raw + b"==").decode("utf-8")
    except Exception:
        txt = raw.decode("utf-8", "replace")
    return [l.strip() for l in txt.splitlines() if "://" in l]


def _parse(uri):
    """vless://, hysteria2:// или ss:// в словарь."""
    u = urlparse(uri)
    q = {k: v[0] for k, v in parse_qs(u.query).items()}
    method = ""
    user, pw = unquote(u.username or ""), unquote(u.password or "") if u.password else ""
    if u.scheme == "ss":
        # либо ss://base64(method:password)@host, либо ss://method:password@host
        if not pw:
            try:
                raw = base64.urlsafe_b64decode(user + "=" * (-len(user) % 4)).decode()
                method, _, pw = raw.partition(":")
            except Exception:
                pass
        else:
            method, pw = user, pw
        user = ""
    return {
        "method": method,
        "scheme": u.scheme,
        "user": user,
        "pw": pw,
        "host": u.hostname or "",
        "port": u.port or 0,
        "name": unquote(u.fragment or "") or u.scheme,
        "q": q,
    }


def nodes(sub_id):
    now = time.time()
    hit = _cache.get(sub_id)
    if hit and now - hit[0] < _CACHE_TTL:
        return hit[1]
    ns = [_parse(x) for x in _xui_links(sub_id)]
    _cache[sub_id] = (now, ns)
    return ns


def _setting(key, default=None):
    try:
        con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True, timeout=5)
        row = con.execute("select value from settings where key=?", (key,)).fetchone()
        con.close()
        return row[0] if row else default
    except Exception:
        return default


def xray_rules():
    """Правила обхода в формате Xray. Берём из настроек панели, чтобы список
    доменов правился в одном месте и не разъезжался между форматами."""
    raw = _setting("subRoutingRules")
    if raw:
        try:
            return json.loads(raw)
        except Exception:
            pass
    return [{"type": "field", "outboundTag": "direct",
             "domain": ["geosite:category-ru", "geosite:category-gov-ru"]},
            {"type": "field", "outboundTag": "direct", "ip": ["geoip:ru", "geoip:private"]}]


def direct_domains():
    """Домены обхода из правил панели, приведённые к суффиксам.

    sing-box и mihomo задают маршруты не по-Xray'ному, и раньше они опирались
    только на скачанные наборы правил. Наборы отстают от жизни: российские
    сервисы на зарубежных доменах (`dodopizza.io`, `payture.com`, `sbercdn.com`)
    в `geosite:category-ru` не попадают, и оплата в приложении уходила через
    Амстердам, где её отбивал антифрод банка. Теперь любое пополнение списка в
    панели доезжает до ВСЕХ форматов само, а не ловится по одному.
    """
    out = []
    for r in xray_rules():
        if r.get("outboundTag") != "direct":
            continue
        for d in r.get("domain") or []:
            if d.startswith("domain:"):
                out.append(d[7:])
            elif d.startswith("full:"):
                out.append(d[5:])
            elif ":" not in d:
                out.append(d)
            # geosite: и regexp: пропускаем — их закрывают наборы правил
    return sorted(set(out))


def blocked_ru_domains():
    """Заблокированные в России сайты на РОССИЙСКИХ доменах.

    `geosite:category-ru` тянет `include:tld-ru`, то есть все `.ru` целиком идут
    напрямую. Для заблокированного это приговор: провайдер его режет, а мы сами
    отправляем запрос мимо тоннеля — сайт не открывается вообще. Заблокированное
    на `.io`, `.org`, `.com` этой беды не знает: оно под `tld-ru` не попадает и
    штатно уходит в тоннель.

    Поэтому чинить надо ровно пересечение «заблокировано И на .ru» — это два
    десятка адресов, а не весь дамп. Для форматов, где правила едут заголовком,
    это принципиально: полный список туда не влезет.
    """
    out = []
    for name in ("blocked-news.lst", "blocked-inside.lst"):
        try:
            with open("%s/%s" % (RULES_DIR, name), encoding="utf-8") as f:
                for line in f:
                    d = line.strip().lower()
                    if not d or d.startswith("#"):
                        continue
                    if d.endswith((".ru", ".su", ".xn--p1ai")):
                        out.append(d)
        except OSError:
            pass
    if not out:
        # Зеркало недоступно — минимум, чтобы правило не исчезло совсем
        out = ["theins.ru", "republic.ru", "grani.ru", "tvrain.ru", "novayagazeta.ru",
               "moscowtimes.ru", "colta.ru", "polit.ru", "the-village.ru", "ej.ru",
               "kasparov.ru", "newtimes.ru", "paperpaper.ru", "zahav.ru"]
    return sorted(set(out))


def traffic(sub_id):
    """upload/download/total/expire для заголовка subscription-userinfo."""
    try:
        con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True, timeout=5)
        em = con.execute("select email from clients where sub_id=? limit 1", (sub_id,)).fetchone()
        if not em:
            con.close()
            return None
        row = con.execute(
            "select coalesce(sum(up),0), coalesce(sum(down),0), coalesce(max(total),0),"
            " coalesce(max(expiry_time),0) from client_traffics where email=?", (em[0],)).fetchone()
        con.close()
        up, down, total, exp = row
        return "upload=%d; download=%d; total=%d; expire=%d" % (
            up, down, total, int(exp / 1000) if exp else 0)
    except Exception:
        return None


# --- сборка форматов -------------------------------------------------------

def _vless_singbox(n, tag):
    q = n["q"]
    o = {
        "type": "vless", "tag": tag,
        "server": n["host"], "server_port": n["port"],
        "uuid": n["user"],
        "packet_encoding": "xudp",
        "tls": {
            "enabled": True,
            "server_name": q.get("sni", ""),
            "utls": {"enabled": True, "fingerprint": q.get("fp", "chrome")},
            "reality": {"enabled": True, "public_key": q.get("pbk", ""),
                        "short_id": q.get("sid", "")},
        },
    }
    if q.get("flow"):
        o["flow"] = q["flow"]
    return o


def _hy2_singbox(n, tag):
    # server_ports (порт-хоппинг) намеренно не ставим: поле появилось только в
    # sing-box 1.12, а версию клиента мы не знаем. Один порт работает везде.
    o = {
        "type": "hysteria2", "tag": tag,
        "server": n["host"], "server_port": n["port"],
        "password": "%s:%s" % (n["user"], n["pw"]) if n["pw"] else n["user"],
        "tls": {"enabled": True, "server_name": n["q"].get("sni", n["host"])},
    }
    # Обфускация: узел перестаёт выглядеть валидным сервером HTTP/3 и становится
    # просто случайным UDP. Маскировка теряется, зато не срабатывает отпечаток
    # QUIC — обмен осознанный, поэтому такой узел держим отдельным, вторым.
    if n["q"].get("obfs") and n["q"].get("obfs-password"):
        o["obfs"] = {"type": n["q"]["obfs"], "password": n["q"]["obfs-password"]}
    return o


def _ss_singbox(n, tag):
    return {"type": "shadowsocks", "tag": tag,
            "server": n["host"], "server_port": n["port"],
            "method": n["method"], "password": n["pw"]}


def build_singbox(sub_id, title):
    ns = nodes(sub_id)
    outs, tags = [], []
    for n in ns:
        tag = n["name"]
        if n["scheme"] == "vless":
            outs.append(_vless_singbox(n, tag))
        elif n["scheme"] == "ss":
            outs.append(_ss_singbox(n, tag))
        else:
            outs.append(_hy2_singbox(n, tag))
        tags.append(tag)

    def rs(tag):
        return {"type": "remote", "tag": tag, "format": "binary",
                "url": "%s/%s.srs" % (RULES_BASE, tag),
                "download_detour": "direct", "update_interval": "7d"}

    # Блока dns здесь намеренно нет. Старый формат объявлен устаревшим в
    # sing-box 1.12 и удаляется в 1.14, а новый не понимают ядра 1.11, на
    # которых сидит Hiddify. Без блока ядро берёт системный резолвер напрямую —
    # это и нужно: домены сопоставляются правилами до всякого DNS, а российские
    # имена разрешаются с адреса пользователя, а не из Амстердама.
    cfg = {
        "log": {"level": "warn", "timestamp": True},
        "inbounds": [{
            "type": "tun", "tag": "tun-in",
            "address": ["172.19.0.1/30"],
            "auto_route": True, "strict_route": False,
            "stack": "mixed",
        }],
        "outbounds": outs + [
            {"type": "urltest", "tag": "⚡ Автовыбор", "outbounds": tags,
             "url": "https://cp.cloudflare.com/generate_204",
             "interval": "3m", "tolerance": 80, "idle_timeout": "30m"},
            {"type": "selector", "tag": "Тоннель",
             "outbounds": ["⚡ Автовыбор"] + tags, "default": "⚡ Автовыбор"},
            {"type": "direct", "tag": "direct"},
        ],
        "route": {
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"ip_is_private": True, "outbound": "direct"},
                {"rule_set": "geosite-ads", "action": "reject"},
                # Заблокированное — ВЫШЕ российского. Иначе include:tld-ru
                # уводит заблокированные `.ru` напрямую, и они не открываются.
                {"rule_set": ["blocked-news", "blocked-inside"], "outbound": "Тоннель"},
                {"domain_suffix": direct_domains(), "outbound": "direct"},
                {"rule_set": ["outside-ru", "geosite-ru", "geosite-gov-ru", "geoip-ru"],
                 "outbound": "direct"},
                {"protocol": "bittorrent", "outbound": "direct"},
            ],
            "rule_set": [rs("geosite-ru"), rs("geosite-gov-ru"),
                          rs("geosite-ads"), rs("geoip-ru"),
                          rs("blocked-news"), rs("blocked-inside"), rs("outside-ru")],
            "final": "Тоннель",
            "auto_detect_interface": True,
        },
        "experimental": {
            "cache_file": {"enabled": True, "store_fakeip": False},
            "clash_api": {"external_controller": "127.0.0.1:9090"},
        },
    }
    return json.dumps(cfg, ensure_ascii=False, indent=2)


def _xray_outbound(n, tag):
    """Один узел как исходящее соединение Xray."""
    q = n["q"]
    if n["scheme"] == "ss":
        return {"tag": tag, "protocol": "shadowsocks",
                "settings": {"servers": [{"address": n["host"], "port": n["port"],
                                           "method": n["method"], "password": n["pw"],
                                           "uot": True}]}}
    return {
        "tag": tag, "protocol": "vless",
        "settings": {"vnext": [{"address": n["host"], "port": n["port"],
                                "users": [{"id": n["user"], "encryption": "none",
                                            "flow": q.get("flow", "")}]}]},
        "streamSettings": {
            "network": q.get("type", "tcp"), "security": "reality",
            "realitySettings": {"show": False, "fingerprint": q.get("fp", "chrome"),
                                 "serverName": q.get("sni", ""),
                                 "publicKey": q.get("pbk", ""),
                                 "shortId": q.get("sid", ""),
                                 "spiderX": q.get("spx", "/")},
        },
    }


def _xray_base(remarks, outs, balancer_tags=None):
    """Полный конфиг Xray: правила обхода внутри, инбаунды там, где их ждёт клиент."""
    # Куда уходит всё, что не отправлено напрямую: балансировщик, если узлов
    # несколько, иначе единственный узел.
    via = {"balancerTag": "auto"} if balancer_tags else {"outboundTag": "proxy"}

    rules = [
        # Заблокированное в РФ — В тоннель, и обязательно ПЕРЕД правилами обхода:
        # ниже `geosite:category-ru` увёл бы эти домены напрямую (он включает все
        # `.ru`), и они не открылись бы вовсе.
        dict({"type": "field",
              "domain": ["domain:%s" % d for d in blocked_ru_domains()]}, **via),
    ]
    rules += xray_rules()
    rules.append({"type": "field", "protocol": ["bittorrent"], "outboundTag": "direct"})
    rules.append(dict({"type": "field", "network": "tcp,udp"}, **via))

    cfg = {
        "remarks": remarks,
        "log": {"loglevel": "warning"},
        "dns": {"servers": [{"address": DNS_RU[0],
                              "domains": ["geosite:category-ru", "geosite:category-gov-ru"]},
                             DNS_OUT, "1.1.1.1"],
                 "queryStrategy": "UseIPv4"},
        "inbounds": [
            {"tag": "socks", "port": 10808, "listen": "127.0.0.1", "protocol": "socks",
             "settings": {"udp": True},
             "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}},
            {"tag": "http", "port": 10809, "listen": "127.0.0.1", "protocol": "http"},
        ],
        "outbounds": outs + [
            {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIP"}},
            {"tag": "block", "protocol": "blackhole"},
        ],
        "routing": {"domainStrategy": "IPIfNonMatch", "rules": rules},
        "stats": {},
    }
    if balancer_tags:
        cfg["routing"]["balancers"] = [{"tag": "auto", "selector": balancer_tags,
                                         "strategy": {"type": "leastPing"}}]
        cfg["observatory"] = {"subjectSelector": balancer_tags, "probeInterval": "5m",
                               "probeURL": "https://cp.cloudflare.com/generate_204"}
    return cfg


def build_xray(sub_id, title):
    """Массив полных конфигов: сначала автовыбор, затем каждый узел отдельно.

    Hysteria2 в конфиг Xray положить нельзя — его ядро этого протокола не знает,
    поэтому сюда попадают только VLESS и Shadowsocks. Кому нужен UDP-вход,
    добавляет вторым адресом формат со ссылками.
    """
    ns = [n for n in nodes(sub_id) if n["scheme"] in ("vless", "ss")]
    if not ns:
        return json.dumps([], ensure_ascii=False)

    tags = ["p%d" % i for i in range(len(ns))]
    auto = _xray_base("⚡ Автовыбор",
                      [_xray_outbound(n, t) for n, t in zip(ns, tags)], tags)
    out = [auto]
    for n in ns:
        o = _xray_outbound(n, "proxy")
        out.append(_xray_base(n["name"], [o]))
    return json.dumps(out, ensure_ascii=False, indent=1)


def build_clash(sub_id, title):
    """mihomo/Clash Meta. Встроенный генератор панели отдаёт здесь ноль правил —
    поэтому конфиг собираем целиком сами."""
    ns = nodes(sub_id)
    proxies, names = [], []
    for n in ns:
        q = n["q"]
        if n["scheme"] == "vless":
            p = {"name": n["name"], "type": "vless", "server": n["host"], "port": n["port"],
                 "uuid": n["user"], "network": q.get("type", "tcp"), "udp": True,
                 "tls": True, "servername": q.get("sni", ""),
                 "client-fingerprint": q.get("fp", "chrome"),
                 "reality-opts": {"public-key": q.get("pbk", ""), "short-id": q.get("sid", "")}}
            if q.get("flow"):
                p["flow"] = q["flow"]
        elif n["scheme"] == "ss":
            p = {"name": n["name"], "type": "ss", "server": n["host"], "port": n["port"],
                 "cipher": n["method"], "password": n["pw"], "udp": True}
        else:
            p = {"name": n["name"], "type": "hysteria2", "server": n["host"],
                 "port": n["port"], "password": "%s:%s" % (n["user"], n["pw"]),
                 "sni": n["q"].get("sni", n["host"]), "udp": True}
            if q.get("mport"):
                p["ports"] = q["mport"]
            if q.get("obfs") and q.get("obfs-password"):
                p["obfs"] = q["obfs"]
                p["obfs-password"] = q["obfs-password"]
        proxies.append(p)
        names.append(n["name"])

    def prov(tag, fname, behavior):
        return {tag: {"type": "http", "behavior": behavior, "format": "mrs",
                      "url": "%s/%s" % (RULES_BASE, fname),
                      "path": "./ruleset/%s" % fname, "interval": 604800}}

    providers = {}
    providers.update(prov("ru-domains", "clash-geosite-ru.mrs", "domain"))
    providers.update(prov("ru-gov", "clash-geosite-gov-ru.mrs", "domain"))
    providers.update(prov("ads", "clash-ads.mrs", "domain"))
    providers.update(prov("ru-ip", "clash-geoip-ru.mrs", "ipcidr"))
    providers.update(prov("blocked-news", "blocked-news.mrs", "domain"))
    providers.update(prov("blocked-inside", "blocked-inside.mrs", "domain"))
    providers.update(prov("outside-ru", "outside-ru.mrs", "domain"))

    cfg = {
        "mixed-port": 7890,
        "allow-lan": False,
        "mode": "rule",
        "log-level": "warning",
        "ipv6": False,
        "unified-delay": True,
        "tcp-concurrent": True,
        "find-process-mode": "off",
        # global-client-fingerprint убрали из mihomo — отпечаток задаём на самом
        # прокси (client-fingerprint в каждом узле).
        "profile": {"store-selected": True, "store-fake-ip": False},
        "dns": {
            "enable": True, "ipv6": False, "enhanced-mode": "fake-ip",
            "fake-ip-range": "198.18.0.1/16",
            "fake-ip-filter": ["*.lan", "*.local", "+.ru"],
            "nameserver": [DNS_OUT, "https://8.8.8.8/dns-query"],
            "direct-nameserver": DNS_RU,
            "nameserver-policy": {"rule-set:ru-domains,ru-gov": DNS_RU},
        },
        "proxies": proxies,
        "proxy-groups": [
            {"name": "⚡ Автовыбор", "type": "url-test", "proxies": names,
             "url": "https://cp.cloudflare.com/generate_204",
             "interval": 180, "tolerance": 80},
            {"name": "Тоннель", "type": "select",
             "proxies": ["⚡ Автовыбор"] + names},
        ],
        "rule-providers": providers,
        "rules": ["RULE-SET,ads,REJECT",
                  # Заблокированное — выше российского, иначе `.ru` из этих
                  # списков уйдёт напрямую и не откроется.
                  "RULE-SET,blocked-news,Тоннель",
                  "RULE-SET,blocked-inside,Тоннель"]
                 + ["DOMAIN-SUFFIX,%s,DIRECT" % d for d in direct_domains()]
                 + [
            "RULE-SET,outside-ru,DIRECT",
            "RULE-SET,ru-gov,DIRECT",
            "RULE-SET,ru-domains,DIRECT",
            # без no-resolve: иначе правило по российским адресам не сработает
            # для доменов, которых нет в списках, — а таких хватает
            "RULE-SET,ru-ip,DIRECT",
            "GEOIP,private,DIRECT,no-resolve",
            "MATCH,Тоннель",
        ],
    }
    return _yaml(cfg)


def _yaml(o, ind=0):
    """Минимальный YAML-дампер: pyyaml на сервере нет, а тянуть зависимость в
    боевой сервис ради одного формата не хочется."""
    sp = "  " * ind
    out = []
    if isinstance(o, dict):
        for k, v in o.items():
            key = _yk(k)
            if isinstance(v, (dict, list)) and v:
                out.append("%s%s:" % (sp, key))
                out.append(_yaml(v, ind + 1))
            elif isinstance(v, (dict, list)):
                out.append("%s%s: %s" % (sp, key, "{}" if isinstance(v, dict) else "[]"))
            else:
                out.append("%s%s: %s" % (sp, key, _yv(v)))
    elif isinstance(o, list):
        for v in o:
            if isinstance(v, dict):
                body = _yaml(v, ind + 1).split("\n")
                out.append("%s- %s" % (sp, body[0].strip()))
                out.extend(body[1:])
            elif isinstance(v, list):
                out.append("%s-" % sp)
                out.append(_yaml(v, ind + 1))
            else:
                out.append("%s- %s" % (sp, _yv(v)))
    return "\n".join(x for x in out if x != "")


def _yk(k):
    return '"%s"' % k if re.search(r'[:\s#\[\]{}*&!|>%@`,]', str(k)) else str(k)


def _yv(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "null"
    if isinstance(v, (int, float)):
        return str(v)
    s = str(v)
    if s == "" or re.search(r'[:#\[\]{}*&!|>%@`,\'"]|^\s|\s$', s) or s.lower() in (
            "true", "false", "null", "yes", "no", "on", "off", "~"):
        return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')
    return s


def build_links(sub_id, title):
    return base64.b64encode("\n".join(_xui_links(sub_id)).encode()).decode()


def build_incy_profile(sub_id, title):
    """Профиль маршрутизации в НАТИВНОМ формате INCY.

    Правила Xray четвёртой строкой тела INCY молча выбрасывает — проверено по
    логу: после переподключения `yandex.ru`, `api.vk.com` и `mail.ru` всё равно
    шли в тоннель, хотя в списке обхода они есть. Приложение ждёт СВОЙ профиль
    (`DirectSites`/`DirectIp`), а ссылку на него — в заголовке `autorouting`.
    Заодно это даёт автообновление: правим список у себя — у людей применяется
    само, переустанавливать подписку не надо.
    """
    return json.dumps({
        "Name": title,
        "GlobalProxy": "true",
        "RemoteDNSType": "DoH",
        "RemoteDNSDomain": "https://cloudflare-dns.com/dns-query",
        "RemoteDNSIP": "1.1.1.1",
        # Ссылок на geosite здесь НЕТ, и это осознанно. Xray неизвестный код не
        # пропускает, а роняет весь конфиг: `geosite:ru` в базе отсутствует, и
        # INCY отказался запускаться целиком — «illegal domain rule: geosite:ru».
        # На встроенную базу клиента опираться нельзя, её содержимое нам
        # неизвестно и проверить его мы не можем.
        # Заодно уходит вторая беда: `geosite:category-ru` тянет include:tld-ru,
        # то есть ВСЕ `.ru`, включая заблокированные — те шли мимо тоннеля и не
        # открывались. Явный список плюс geoip:ru закрывают то же самое без
        # обеих ловушек.
        "DirectSites": ["domain:" + d for d in direct_domains()],
        "DirectIp": ["geoip:ru", "geoip:private"],
        # обязательно: без разрешения имён правило по российским адресам молчит
        "DomainStrategy": "IPIfNonMatch",
    }, ensure_ascii=False, indent=2)


def build_incy(sub_id, title):
    """Тело для INCY: ссылки плюс документированная строка-директива.

    Заголовок `autorouting` — основной путь, он же включает автообновление
    правил. Строку в теле держим как дубль: заголовки по дороге теряются
    (прокси, кеши), а тело доезжает всегда. Формат директивы описан в
    документации INCY, посторонней ссылкой он её не считает.
    """
    lines = _xui_links(sub_id)
    lines.append("://autorouting/add/%s/s/%s/incy-profile" % (BASE_URL, sub_id))
    return base64.b64encode("\n".join(lines).encode()).decode()


FORMATS = {
    "singbox":      (build_singbox,      "application/json; charset=utf-8"),
    "xray":         (build_xray,         "application/json; charset=utf-8"),
    "clash":        (build_clash,        "text/yaml; charset=utf-8"),
    "links":        (build_links,        "text/plain; charset=utf-8"),
    "incy":         (build_incy,         "text/plain; charset=utf-8"),
    "incy-profile": (build_incy_profile, "application/json; charset=utf-8"),
}

# Определение по User-Agent — для тех, кто дёргает общий адрес /s/<id>.
UA_MAP = [
    (r"hiddify|karing|sing-?box|SFA|SFI|SFM", "singbox"),
    (r"clash|mihomo|meta|koala|verge|flclash|stash", "clash"),
    (r"incy", "incy"),
    (r"v2rayn(?!g)|nekoray|nekobox", "xray"),
]


def pick(ua):
    for pat, fmt in UA_MAP:
        if re.search(pat, ua or "", re.I):
            return fmt
    return "links"


def handle(path, ua):
    """path вида /s/<subId> или /s/<subId>/<формат>. Возвращает
    (код, content-type, тело, доп. заголовки)."""
    parts = [p for p in path.split("/") if p]
    if len(parts) < 2 or parts[0] != "s":
        return 404, "text/plain", b"not found", {}
    sub_id = parts[1]
    if not re.match(r"^[A-Za-z0-9_-]{6,64}$", sub_id):
        return 400, "text/plain", b"bad id", {}
    fmt = parts[2] if len(parts) > 2 else pick(ua)
    if fmt not in FORMATS:
        return 404, "text/plain", b"unknown format", {}

    fn, ctype = FORMATS[fmt]
    title = _setting("subTitle", "VPN") or "VPN"
    try:
        body = fn(sub_id, title).encode()
    except Exception as e:
        return 502, "text/plain", ("panel error: %s" % e).encode(), {}

    b64 = lambda s: base64.b64encode(s.encode()).decode()
    hdr = {
        "profile-update-interval": str(UPDATE_HOURS),
        "profile-title": "base64:" + b64(title),
        "profile-web-page-url": "https://SERVER_IP:2053/PAGE_PATH/",
        "support-url": "https://t.me/YourBotName",
        "Cache-Control": "no-store",
    }
    tr = traffic(sub_id)
    if tr:
        hdr["subscription-userinfo"] = tr
    if fmt == "links":
        # Happ и Hiddify читают правила из заголовка — остальным он безвреден.
        # ensure_ascii обязателен: HTTP-заголовки не переносят не-ASCII.
        hdr["Routing"] = json.dumps(xray_rules(), ensure_ascii=True)
        hdr["Routing-Enable"] = "true"
        ann = _setting("subAnnounce")
        if ann:
            hdr["announce"] = "base64:" + b64(ann)
    if fmt == "incy":
        # Порядок важен: INCY берёт `autorouting` первым и с ним же включает
        # автообновление правил. `routing` оставляем как запасной путь, если
        # ссылка почему-то не открылась.
        prof = build_incy_profile(sub_id, title)
        hdr["autorouting"] = "%s/s/%s/incy-profile" % (BASE_URL, sub_id)
        hdr["routing"] = "base64:" + base64.b64encode(prof.encode()).decode()
    return 200, ctype, body, hdr
