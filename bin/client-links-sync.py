#!/usr/bin/env python3
"""Держит в подписках 3x-ui ссылки на все входы, которых панель не знает.

Панель умеет только свои inbound (VLESS+Reality на 443 и 8443). Остальные три
входа - Hysteria2, Hysteria2 с обфускацией и Shadowsocks-2022 - живут
отдельными процессами, и клиент узнаёт о них строкой в client_external_links.
Панель отдаёт эти строки в подписке сразу, перезапускать её не нужно.

Раньше скрипт вёл только Hysteria2, а две другие ссылки я один раз прописал
руками. Это выстрелило ровно так, как и должно было: у клиента, заведённого
позже, в подписке оказалось три узла вместо пяти, и выяснилось это по жалобе
«в приложении только три профиля». Теперь все три вида ведутся здесь.

Скрипт идемпотентный: если всё совпадает, он молчит и в базу не пишет.
Перезапускать hysteria-server или xray-ss не нужно - список пользователей они
читают сами (Hysteria через hysteria-auth, xray-ss через свой генератор).
"""
import json
import os
import sqlite3
import sys
import time
import urllib.parse
from base64 import b64encode

DB = "/etc/x-ui/x-ui.db"
ADDR = "SERVER_IP"

HY_PORT, HY_HOP = 36712, "20000-50000"
OBFS_PORT, OBFS_PW_FILE = 51712, "/etc/hysteria/obfs-password"
SS_PORT, SS_METHOD, SS_KEYS = 51643, "2022-blake3-aes-256-gcm", "/etc/xray-ss/keys.json"

q = lambda s: urllib.parse.quote(s, safe="")


def link_hy(email, uuid, _keys, _obfs):
    return "hysteria2://%s:%s@%s:%d/?sni=%s&mport=%s#%s" % (
        q(email), q(uuid), ADDR, HY_PORT, ADDR, HY_HOP, q("Hysteria2-" + email))


def link_obfs(email, uuid, _keys, obfs):
    if not obfs:
        return None
    return "hysteria2://%s:%s@%s:%d/?sni=%s&obfs=salamander&obfs-password=%s#%s" % (
        q(email), q(uuid), ADDR, OBFS_PORT, ADDR, q(obfs), q("Hysteria2-obfs"))


def link_ss(email, _uuid, keys, _obfs):
    # В Shadowsocks-2022 пароль составной: серверный ключ и ключ пользователя
    # через двоеточие. Без серверного ключа вход отвечает, но не расшифровывает.
    psk = (keys.get("users") or {}).get(email)
    if not psk or not keys.get("server"):
        return None
    userinfo = "%s:%s:%s" % (SS_METHOD, keys["server"], psk)
    # Хвостовые "=" срезаны намеренно: ровно в таком виде ссылки уже лежат у
    # четырёх человек, и менять их без нужды - это менять рабочее.
    b64 = b64encode(userinfo.encode()).decode().rstrip("=")
    return "ss://%s@%s:%d#Shadowsocks" % (b64, ADDR, SS_PORT)


KINDS = [("Hysteria2", 10, link_hy),
         ("Shadowsocks", 20, link_ss),
         ("Hysteria2-obfs", 30, link_obfs)]


def read_keys():
    try:
        with open(SS_KEYS, encoding="utf-8") as f:
            return json.load(f)
    except OSError:
        return {}


def read_obfs():
    try:
        with open(OBFS_PW_FILE, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def main():
    dry = "--dry-run" in sys.argv
    keys, obfs = read_keys(), read_obfs()
    con = sqlite3.connect(DB, timeout=10)
    cur = con.cursor()
    clients = cur.execute(
        "select id, email, uuid from clients where enable = 1 order by id").fetchall()

    changed = []
    for remark, sort_index, build in KINDS:
        want = {}
        for cid, email, uuid in clients:
            v = build(email, uuid, keys, obfs)
            if v:
                want[cid] = v
        have = dict(cur.execute(
            "select client_id, value from client_external_links where remark = ?",
            (remark,)).fetchall())
        if want == have:
            continue
        changed.append("%s: было %d, стало %d" % (remark, len(have), len(want)))
        if dry:
            for cid in sorted(set(want) - set(have)):
                print("  + %s для client_id=%s" % (remark, cid))
            for cid in sorted(set(have) - set(want)):
                print("  - %s у client_id=%s" % (remark, cid))
            for cid in sorted(set(want) & set(have)):
                if want[cid] != have[cid]:
                    print("  ~ %s у client_id=%s изменилась" % (remark, cid))
            continue
        now = int(time.time() * 1000)
        cur.execute("delete from client_external_links where remark = ?", (remark,))
        for cid, link in want.items():
            cur.execute(
                "insert into client_external_links"
                "(client_id, kind, value, remark, sort_index, created_at)"
                " values (?,?,?,?,?,?)",
                (cid, "link", link, remark, sort_index, now))

    if not changed:
        con.close()
        return 0
    if not dry:
        con.commit()
    con.close()
    print("%s%s" % ("(проверка) " if dry else "", "; ".join(changed)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
