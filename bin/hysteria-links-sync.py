#!/usr/bin/env python3
"""Держит ссылки Hysteria2 в подписках 3x-ui в актуальном виде.

Панель знает только про свои inbound, поэтому Hysteria2 добавляется каждому
клиенту отдельной строкой в таблицу client_external_links. Скрипт приводит
эту таблицу в соответствие со списком клиентов и ничего не делает, если
всё уже совпадает - его безопасно дёргать хоть каждую минуту.

Перезапускать hysteria-server не нужно: пользователей она проверяет
через службу hysteria-auth прямо по этой же базе.
"""
import sqlite3
import sys
import time
import urllib.parse

DB = "/etc/x-ui/x-ui.db"
ADDR = "SERVER_IP"
PORT = 36712
HOP = "20000-50000"
REMARK = "Hysteria2"


def build_link(email, uuid):
    auth = "%s:%s" % (urllib.parse.quote(email, safe=""), urllib.parse.quote(uuid, safe=""))
    label = urllib.parse.quote("Hysteria2-" + email, safe="")
    return "hysteria2://%s@%s:%d/?sni=%s&mport=%s#%s" % (auth, ADDR, PORT, ADDR, HOP, label)


def main():
    con = sqlite3.connect(DB, timeout=10)
    cur = con.cursor()
    clients = cur.execute(
        "select id, email, uuid from clients where enable = 1 order by id"
    ).fetchall()
    want = {cid: build_link(email, uuid) for cid, email, uuid in clients}
    have = dict(
        cur.execute(
            "select client_id, value from client_external_links where remark = ?", (REMARK,)
        ).fetchall()
    )

    if want == have:
        con.close()
        return 0

    now = int(time.time() * 1000)
    cur.execute("delete from client_external_links where remark = ?", (REMARK,))
    for cid, link in want.items():
        cur.execute(
            "insert into client_external_links"
            "(client_id, kind, value, remark, sort_index, created_at) values (?,?,?,?,?,?)",
            (cid, "link", link, REMARK, 10, now),
        )
    con.commit()
    con.close()
    added = len(set(want) - set(have))
    removed = len(set(have) - set(want))
    print("ссылок Hysteria2: %d (добавлено %d, убрано %d)" % (len(want), added, removed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
