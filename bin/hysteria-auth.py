#!/usr/bin/env python3
"""Проверяет пользователей Hysteria2 прямо по базе 3x-ui.

Hysteria спрашивает разрешение на каждое подключение, поэтому список
пользователей не нужно держать в конфиге и не нужно перезапускать службу,
когда клиента завели или удалили в панели.

Клиент присылает строку вида "email:uuid" - ровно то, что зашито
в ссылке hysteria2:// из подписки.
"""
import json
import sqlite3
from http.server import BaseHTTPRequestHandler, HTTPServer

DB = "file:/etc/x-ui/x-ui.db?mode=ro"
LISTEN = ("127.0.0.1", 8790)


def resolve(auth):
    """Возвращает email, если пара email:uuid есть в базе и клиент включён."""
    if not auth or ":" not in auth:
        return None
    email, secret = auth.split(":", 1)
    try:
        con = sqlite3.connect(DB, uri=True, timeout=3)
        try:
            row = con.execute(
                "select uuid from clients where email = ? and enable = 1", (email,)
            ).fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    return email if row and row[0] == secret else None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            payload = {}
        email = resolve(payload.get("auth"))
        body = json.dumps({"ok": bool(email), "id": email or ""}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(LISTEN, Handler).serve_forever()
