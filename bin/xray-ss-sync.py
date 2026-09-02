#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Собрать конфиг резервного входа Shadowsocks-2022 из списка клиентов панели.

Панель этот протокол своей моделью описать не умеет: при генерации она теряет
серверный пароль, и ядро падает с `missing password`. Поэтому вход живёт
отдельным процессом, а панель о нём знает только ссылками в
client_external_links — их она отдаёт в подписке без перезапуска.
"""
import base64, json, os, sqlite3, sys

DB = "/etc/x-ui/x-ui.db"
CFG = "/etc/xray-ss/config.json"
KEYS = "/etc/xray-ss/keys.json"
PORT, METHOD = 51643, "2022-blake3-aes-256-gcm"

keys = json.load(open(KEYS)) if os.path.exists(KEYS) else {}
keys.setdefault("server", base64.b64encode(os.urandom(32)).decode())
keys.setdefault("users", {})

con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True)
emails = [r[0] for r in con.execute("select email from clients order by id")]
con.close()
for e in emails:
    keys["users"].setdefault(e, base64.b64encode(os.urandom(32)).decode())
# у ушедших ключи убираем, чтобы доступ не оставался
keys["users"] = {e: p for e, p in keys["users"].items() if e in emails}

cfg = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "tag": "ss-in", "port": PORT, "protocol": "shadowsocks",
        "settings": {"method": METHOD, "password": keys["server"], "network": "tcp,udp",
                     # method у пользователей обязан быть пустым — в
                     # многопользовательском SS2022 шифр задаётся один раз
                     "clients": [{"password": p, "email": e}
                                 for e, p in sorted(keys["users"].items())]},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
    }],
    "outbounds": [{"tag": "direct", "protocol": "freedom",
                   "settings": {"domainStrategy": "UseIP"}},
                  {"tag": "block", "protocol": "blackhole"}],
    "routing": {"rules": [
        {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
        {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
    ]},
}
# Сравниваем с тем, что уже лежит: Xray не умеет перечитывать конфиг, поэтому
# любой «reload» превращается в restart и рвёт живые соединения. Перезапускать
# можно ТОЛЬКО когда список клиентов действительно изменился.
new_text = json.dumps(cfg, indent=1, ensure_ascii=False)
try:
    same = open(CFG, encoding="utf-8").read() == new_text
except OSError:
    same = False
if same:
    print("клиентов в конфиге: %d, изменений нет" % len(keys["users"]))
    raise SystemExit(3)
tmp = CFG + ".tmp"
open(tmp, "w", encoding="utf-8").write(new_text)
os.chmod(tmp, 0o600)
os.replace(tmp, CFG)
os.umask(0o077)
json.dump(keys, open(KEYS + ".tmp", "w"), indent=1)
os.chmod(KEYS + ".tmp", 0o600)
os.replace(KEYS + ".tmp", KEYS)
print("клиентов в конфиге: %d" % len(keys["users"]))
