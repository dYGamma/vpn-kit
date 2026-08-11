#!/usr/bin/env python3
"""Работа с базой 3x-ui: завести, найти и убрать клиента.

Клиент попадает сразу в два места:
  * база панели - чтобы он пережил перезапуск и попал в подписку;
  * работающий Xray через `xray api adu` - чтобы заработал немедленно,
    без перезапуска, который оборвал бы сессии всем остальным.

Ссылка Hysteria2 добавится сама: таймер hysteria-links-sync сверяет
таблицу раз в минуту, а пользователей Hysteria2 проверяет по этой же базе.
"""
import json
import os
import random
import re
import sqlite3
import string
import subprocess
import time

DB = "/etc/x-ui/x-ui.db"
XRAY = "/usr/local/x-ui/bin/xray-linux-amd64"
API = "127.0.0.1:62789"
FLOW = "xtls-rprx-vision"


def _conn():
    return sqlite3.connect(DB, timeout=15)


def _rand(n):
    return "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(n))


def _free_email(cur, wanted):
    """Ник может повторяться или отсутствовать - подбираем свободное имя."""
    base = re.sub(r"[^A-Za-z0-9_-]", "", (wanted or "")).strip("-_")[:24].lower()
    if len(base) < 3:
        base = "tg" + _rand(6)
    name = base
    for i in range(2, 100):
        taken = cur.execute("select 1 from clients where email = ?", (name,)).fetchone()
        if not taken:
            return name
        name = "%s-%d" % (base, i)
    return base + "-" + _rand(4)


def _inbounds(cur):
    """Все включённые inbound панели: (id, tag, port, protocol)."""
    return cur.execute(
        "select id, tag, port, protocol from inbounds where enable = 1 order by id"
    ).fetchall()


def find_by_tg(tg_id):
    # Клиенты, заведённые руками через панель, лежат с tg_id = 0. Искать по нулю
    # нельзя: совпал бы первый попавшийся человек и мы отдали бы чужую подписку.
    if int(tg_id) <= 0:
        return None
    con = _conn()
    try:
        row = con.execute(
            "select email, sub_id, uuid, enable from clients where tg_id = ?", (int(tg_id),)
        ).fetchone()
    finally:
        con.close()
    if not row:
        return None
    return {"email": row[0], "sub_id": row[1], "uuid": row[2], "enable": bool(row[3])}


def _push_to_xray(uuid, email, inbounds):
    """Добавляет пользователя в работающий Xray. Без этого он заработает
    только после перезапуска панели."""
    cfg = {"inbounds": [
        {"tag": tag, "port": port, "protocol": proto,
         "settings": {"clients": [{"id": uuid, "email": email, "flow": FLOW}],
                      "decryption": "none"}}
        for (_id, tag, port, proto) in inbounds
    ]}
    path = "/run/vpn-issue-adu.json"
    with open(path, "w") as f:
        json.dump(cfg, f)
    try:
        out = subprocess.run([XRAY, "api", "adu", "--server=" + API, path],
                             capture_output=True, text=True, timeout=15)
        return out.returncode == 0 and "Added" in (out.stdout or "")
    finally:
        os.unlink(path)


def _drop_from_xray(email, inbounds):
    ok = True
    for (_id, tag, _port, _proto) in inbounds:
        out = subprocess.run([XRAY, "api", "rmu", "--server=" + API, "-tag=" + tag, email],
                             capture_output=True, text=True, timeout=15)
        ok = ok and out.returncode == 0
    return ok


def create(tg_id, username):
    """Заводит клиента во всех включённых inbound. Повторный вызов вернёт
    существующего - выдавать одному человеку два доступа незачем."""
    have = find_by_tg(tg_id)
    if have:
        return have

    con = _conn()
    cur = con.cursor()
    now = int(time.time() * 1000)
    try:
        email = _free_email(cur, username)
        uuid = subprocess.run(["cat", "/proc/sys/kernel/random/uuid"],
                              capture_output=True, text=True).stdout.strip()
        sub_id = _rand(16)
        inbounds = _inbounds(cur)

        cur.execute(
            "insert into clients(email, sub_id, uuid, flow, limit_ip, total_gb, expiry_time,"
            " enable, tg_id, comment, reset, created_at, updated_at)"
            " values(?,?,?,?,0,0,0,1,?,?,0,?,?)",   # limit_ip=0: ограничение по числу IP
            # не включаем — у мобильных операторов адрес меняется сам, и человек
            # получил бы бан на ровном месте. От утёкшего конфига спасает отзыв.
            (email, sub_id, uuid, FLOW, int(tg_id), "@" + (username or "?"), now, now))
        cid = cur.lastrowid

        for (iid, _tag, _port, _proto) in inbounds:
            cur.execute("insert or ignore into client_inbounds"
                        "(client_id, inbound_id, flow_override, created_at) values(?,?,?,?)",
                        (cid, iid, FLOW, now))

        cur.execute("insert or ignore into client_traffics"
                    "(inbound_id, enable, email, up, down, expiry_time, total, reset)"
                    " values(?,1,?,0,0,0,0,0)", (inbounds[0][0], email))

        # Тот же клиент - в JSON каждого inbound, иначе он исчезнет при перезапуске панели.
        entry = {"comment": "", "created_at": now, "email": email, "enable": True,
                 "expiryTime": 0, "flow": FLOW, "id": uuid, "limitIp": 0, "reset": 0,
                 "subId": sub_id, "tgId": int(tg_id), "totalGB": 0, "updated_at": now}
        for (iid, _tag, _port, _proto) in inbounds:
            s = json.loads(cur.execute("select settings from inbounds where id = ?",
                                       (iid,)).fetchone()[0])
            s.setdefault("clients", []).append(dict(entry))
            cur.execute("update inbounds set settings = ? where id = ?",
                        (json.dumps(s, indent=2), iid))
        con.commit()
    finally:
        con.close()

    _push_to_xray(uuid, email, inbounds)
    return {"email": email, "sub_id": sub_id, "uuid": uuid, "enable": True}


def revoke(tg_id):
    if int(tg_id) <= 0:
        return False
    con = _conn()
    cur = con.cursor()
    try:
        row = cur.execute("select id, email from clients where tg_id = ?",
                          (int(tg_id),)).fetchone()
        if not row:
            return False
        cid, email = row
        inbounds = _inbounds(cur)
        cur.execute("delete from client_inbounds where client_id = ?", (cid,))
        cur.execute("delete from client_external_links where client_id = ?", (cid,))
        cur.execute("delete from client_traffics where email = ?", (email,))
        cur.execute("delete from clients where id = ?", (cid,))
        for (iid, _tag, _port, _proto) in inbounds:
            s = json.loads(cur.execute("select settings from inbounds where id = ?",
                                       (iid,)).fetchone()[0])
            s["clients"] = [c for c in (s.get("clients") or []) if c.get("email") != email]
            cur.execute("update inbounds set settings = ? where id = ?",
                        (json.dumps(s, indent=2), iid))
        con.commit()
    finally:
        con.close()
    _drop_from_xray(email, inbounds)
    return True


def info(sub_id):
    """Данные для шапки страницы."""
    con = _conn()
    try:
        row = con.execute("select email, enable from clients where sub_id = ?",
                          (sub_id,)).fetchone()
        if not row:
            return None
        email, enable = row
        t = con.execute("select up, down from client_traffics where email = ?",
                        (email,)).fetchone() or (0, 0)
    finally:
        con.close()
    return {"name": email, "enable": bool(enable), "used": int(t[0] or 0) + int(t[1] or 0)}


def count_clients():
    con = _conn()
    try:
        return con.execute("select count(*) from clients where enable = 1").fetchone()[0]
    finally:
        con.close()
