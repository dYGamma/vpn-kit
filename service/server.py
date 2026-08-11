#!/usr/bin/env python3
"""Сервис выдачи VPN-подписок. Слушает только localhost - наружу его
выставляет nginx по секретному пути, он же даёт TLS.

Заявки (ещё не одобренные Димой) лежат в отдельном файле: они временные,
и в базе панели им делать нечего.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, "/opt/vpn-issue")
import store
import dl
import sub as subgen

CONF = "/etc/vpn-issue/config"
QUEUE = "/var/lib/vpn-issue/requests.json"
LISTEN = ("127.0.0.1", 8791)
REQUEST_TTL = 7 * 24 * 3600     # заявка без ответа живёт неделю


def config():
    out = {}
    with open(CONF) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"')
    return out


CFG = config()


def queue_load():
    try:
        with open(QUEUE) as f:
            return json.load(f)
    except (IOError, ValueError):
        return {"next_id": 1, "items": {}}


def queue_save(q):
    os.makedirs(os.path.dirname(QUEUE), exist_ok=True)
    tmp = QUEUE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(q, f, ensure_ascii=False, indent=1)
    os.replace(tmp, QUEUE)


def page_link(sub_id):
    return CFG["PAGE_BASE"].rstrip("/") + "/#" + sub_id


def do_request(body):
    """Человек написал боту. Уже есть доступ - сразу отдаём ссылку."""
    tg_id = int(body["tg_id"])
    username = (body.get("username") or "").lstrip("@")

    have = store.find_by_tg(tg_id)
    if have:
        return {"status": "exists", "link": page_link(have["sub_id"]), "name": have["email"]}

    q = queue_load()
    now = int(time.time())
    q["items"] = {k: v for k, v in q["items"].items()
                  if now - v.get("at", 0) < REQUEST_TTL and v.get("state") == "pending"}
    for rid, item in q["items"].items():
        if item["tg_id"] == tg_id:
            return {"status": "pending", "req_id": int(rid)}

    rid = q["next_id"]
    q["next_id"] += 1
    q["items"][str(rid)] = {"tg_id": tg_id, "username": username, "at": now, "state": "pending"}
    queue_save(q)
    return {"status": "new", "req_id": rid}


# Слова, по которым видно, что человек пришёл за доступом. Не угадываем по
# одному «привет»: на первое сообщение бот сам спрашивает, и заявка рождается
# только из ответа человека. Так Дима не получает заявок от случайных людей.
INTENT = (
    "впн", "впн", "vpn", "доступ", "подписк", "прокси", "proxy", "ключ", "конфиг",
    "подключ", "обход", "заблокир", "блокиров", "не открыва", "не работа",
    "ютуб", "youtube", "инстаграм", "instagram", "дискорд", "discord",
    "тикток", "tiktok", "нужен", "нужна", "нужно", "хочу", "дай", "можно",
    "/start", "/vpn", "да",
)
GREET_LIMIT = 5   # столько сообщений без внятного ответа — и замолкаем


def wants_access(text):
    t = (text or "").lower()
    return any(w in t for w in INTENT)


def do_touch(body):
    """Человек написал боту. Решаем, что делать, но заявку создаём только
    когда он сам сказал, что хочет доступ."""
    tg_id = int(body["tg_id"])
    username = (body.get("username") or "").lstrip("@")
    text = body.get("text") or ""

    have = store.find_by_tg(tg_id)
    if have:
        return {"action": "exists", "link": page_link(have["sub_id"]), "name": have["email"]}

    q = queue_load()
    seen = q.setdefault("seen", {})
    key = str(tg_id)
    for rid, item in q["items"].items():
        if item["tg_id"] == tg_id and item.get("state") == "pending":
            # Настойчивый человек пишет каждые полминуты — напоминать ему
            # «заявка уже у Димы» на каждое сообщение незачем.
            rec = seen.get(key) or {}
            now = int(time.time())
            if now - int(rec.get("told", 0)) < 600:
                queue_save(q)
                return {"action": "silent"}
            rec["told"] = now
            seen[key] = rec
            queue_save(q)
            return {"action": "pending", "req_id": int(rid)}

    rec = seen.get(key) or {"greeted": False, "msgs": 0}

    if wants_access(text):
        rid = q["next_id"]
        q["next_id"] += 1
        q["items"][str(rid)] = {"tg_id": tg_id, "username": username,
                                "at": int(time.time()), "state": "pending"}
        seen.pop(key, None)
        queue_save(q)
        return {"action": "new", "req_id": rid}

    rec["msgs"] += 1
    if not rec["greeted"]:
        rec["greeted"] = True
        seen[key] = rec
        queue_save(q)
        return {"action": "greet"}

    seen[key] = rec
    queue_save(q)
    return {"action": "silent" if rec["msgs"] > GREET_LIMIT else "nudge"}


def do_approve(body):
    rid = str(int(body["req_id"]))
    q = queue_load()
    item = q["items"].get(rid)
    if not item or item.get("state") != "pending":
        return {"ok": False, "error": "заявки с таким номером нет"}
    client = store.create(item["tg_id"], item["username"])
    item["state"] = "approved"
    item["email"] = client["email"]
    queue_save(q)
    return {"ok": True, "tg_id": item["tg_id"], "username": item["username"],
            "name": client["email"], "link": page_link(client["sub_id"])}


def do_deny(body):
    rid = str(int(body["req_id"]))
    q = queue_load()
    item = q["items"].get(rid)
    if not item or item.get("state") != "pending":
        return {"ok": False, "error": "заявки с таким номером нет"}
    item["state"] = "denied"
    queue_save(q)
    return {"ok": True, "tg_id": item["tg_id"], "username": item["username"]}


def do_revoke(body):
    return {"ok": store.revoke(int(body["tg_id"]))}


def do_list(_body):
    q = queue_load()
    pend = [{"req_id": int(k), **v} for k, v in q["items"].items() if v.get("state") == "pending"]
    return {"pending": sorted(pend, key=lambda x: x["req_id"]),
            "clients": store.count_clients()}


def do_leaks(_body):
    """Кандидаты на утечку: что российское ушло через тоннель.

    Списки geosite отстают от жизни, а клиенты не всегда применяют правила —
    без этого отчёта и то и другое выясняется по жалобе «не работает оплата».
    Считает таймер leak-scan, здесь только отдаём готовое.
    """
    try:
        with open("/var/lib/vpn-issue/leaks.json", encoding="utf-8") as f:
            d = json.load(f)
    except Exception as e:
        return {"ok": False, "error": "отчёта нет: %s" % e}
    top = lambda k, n: [{"dst": r["dst"], "hits": r["hits"], "users": r["users"]}
                        for r in d.get(k, [])[:n]]
    return {"ok": True,
            "broken_rules": top("broken_rules", 10),
            "new_ru_domain": top("new_ru_domain", 10),
            "check_by_hand": top("check_by_hand", 10),
            "counts": {k: len(v) for k, v in d.items()}}

ROUTES = {"/request": do_request, "/touch": do_touch, "/approve": do_approve, "/deny": do_deny,
          "/revoke": do_revoke, "/list": do_list,
    "/leaks": do_leaks}



class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "vpn-issue"

    def _send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path.startswith("/dl/"):
            # Переходник на свежий файл релиза. Секрет не нужен: это публичные
            # адреса на GitHub, и человек всё равно попадёт туда же руками.
            target = dl.resolve(u.path[4:])
            if not target:
                return self._send(404, {"error": "нет такого файла"})
            self.send_response(302)
            self.send_header("Location", target)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if u.path.startswith("/s/"):
            # Подписка под конкретное приложение. Секрета нет и не нужно:
            # защита — сам код подписки, как и у /info.
            code, ctype, body, hdr = subgen.handle(u.path, self.headers.get("User-Agent", ""))
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            for k, v in hdr.items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if u.path != "/info":
            return self._send(404, {"error": "нет такого пути"})
        # Сюда ходит браузер человека, секрета у него нет и быть не может.
        # Защита - сам код подписки: не зная его, данные не получить.
        sub = (parse_qs(u.query).get("sub") or [""])[0]
        data = store.info(sub) if sub else None
        return self._send(200 if data else 404, data or {"error": "не найдено"})

    def do_POST(self):
        if self.headers.get("X-Auth") != CFG["SECRET"]:
            self.log_error("отказ: неверный секрет с %s", self.client_address[0])
            return self._send(403, {"error": "нет доступа"})
        fn = ROUTES.get(urlparse(self.path).path)
        if not fn:
            return self._send(404, {"error": "нет такого пути"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            return self._send(200, fn(body))
        except Exception as e:
            self.log_error("ошибка обработки %s: %s", self.path, e)
            return self._send(500, {"ok": False, "error": str(e)})

    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % (fmt % args))


if __name__ == "__main__":
    HTTPServer(LISTEN, Handler).serve_forever()
