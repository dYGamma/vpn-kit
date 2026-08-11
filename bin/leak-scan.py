#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Поиск российских сервисов, которые утекли через тоннель.

Зачем: списки geosite отстают от жизни, и российские сервисы на зарубежных
доменах в них не попадают. Так мы поймали `dodopizza.io` — только после того,
как у человека перестала проходить оплата. Ловить по жалобам — плохая схема.

Сервер видит КАЖДЫЙ адрес, который проксирует. Если через тоннель ушло что-то
российское, значит либо у клиента не применяются правила обхода, либо домена нет
в наших списках. И то и другое надо знать до жалобы, а не после.

Ничего не меняет: только читает лог и пишет отчёт.
"""

import json
import os
import re
import socket
import subprocess
import sqlite3
import sys
from collections import defaultdict

ACCESS_LOG = "/var/log/x-ui/access.log"
OUT = "/var/lib/vpn-issue/leaks.json"
DB = "/etc/x-ui/x-ui.db"
RULES_DIR = "/var/www/vpn-help/rules"
IPSET = "ru_nets"          # ~11400 российских подсетей, обновляется ru-allowlist.timer

# Российские бренды на зарубежных доменах: ни geosite, ни geoip:ru их не ловят
# (ozon.io живёт на AWS anycast, sbercdn.com — на Cloudflare), поймать можно
# только по имени.
BRANDS = ("ozon", "sber", "sbers", "dodo", "tinkoff", "tbank", "wildberries", "wb",
          "avito", "vtb", "alfa", "gazprom", "yandex", "mail", "vk", "rutube",
          "kinopoisk", "megafon", "mts", "beeline", "tele2", "rostelecom", "rzd",
          "gosuslugi", "nalog", "pochta", "magnit", "lenta", "perekrestok", "samokat",
          "delivery", "dostavka", "citilink", "dns", "mvideo", "eldorado", "lamoda",
          "aliexpress", "megamarket", "pyaterochka", "x5", "raiffeisen", "psb",
          "sovcombank", "otkritie", "mkb", "qiwi", "yoomoney", "cloudpayments",
          "payture", "payselection", "best2pay", "robokassa", "unitpay", "nspk",
          "mirconnect", "max", "oneme", "litres", "ivi", "okko", "premier", "wink")

RU_TLD = (".ru", ".su", ".xn--p1ai", ".moscow", ".tatar")


def known_direct():
    """Домены, которые мы УЖЕ отправляем напрямую. Если такой домен нашёлся в
    логе — правила у клиента не работают, и это отдельный, более важный сигнал."""
    out = set()
    try:
        con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True, timeout=5)
        raw = con.execute(
            "select value from settings where key='subRoutingRules'").fetchone()
        con.close()
        for r in json.loads(raw[0]) if raw else []:
            for d in r.get("domain") or []:
                if d.startswith("domain:"):
                    out.add(d[7:])
    except Exception:
        pass
    for name in ("outside-ru.lst",):
        try:
            with open(os.path.join(RULES_DIR, name), encoding="utf-8") as f:
                out.update(l.strip().lower() for l in f
                           if l.strip() and not l.startswith("#"))
        except OSError:
            pass
    return out


def in_russia(ip):
    """Российский ли адрес — по тому же ipset, что охраняет панель."""
    try:
        return subprocess.run(["ipset", "test", IPSET, ip],
                              capture_output=True, timeout=5).returncode == 0
    except Exception:
        return False


def rdns(ip):
    try:
        return socket.gethostbyaddr(ip)[0].lower()
    except Exception:
        return ""


def covered(dom, direct):
    """Домен или любой его родитель уже в списке обхода."""
    parts = dom.split(".")
    return any(".".join(parts[i:]) in direct for i in range(len(parts) - 1))


# Вторые уровни, которые сами по себе доменом не являются
SLD = {"co", "com", "net", "org", "gov", "edu", "ac", "msk", "spb", "nnov", "pp"}


def base_domain(host):
    """Свернуть имя до регистрируемого домена.

    Без этого отчёт бесполезен: реклама и телеметрия ходят по одноразовым
    поддоменам вида `1786425518-6a7a2249...`, и каждое соединение выглядит новым
    доменом. Смотреть надо на `mail.ru`, а не на десять тысяч его поддоменов.
    """
    p = host.split(".")
    if len(p) < 3:
        return host
    return ".".join(p[-3:]) if p[-2] in SLD else ".".join(p[-2:])


def main():
    if not os.path.exists(ACCESS_LOG):
        sys.exit("нет лога %s" % ACCESS_LOG)
    # Необязательный порог по времени в формате лога Xray: «2026/08/11 15:44».
    # Нужен, чтобы отделить утечки ДО правки правил от утечек ПОСЛЕ.
    since = None
    for a in sys.argv[1:]:
        if a.startswith("--since="):
            since = a.split("=", 1)[1]

    direct = known_direct()
    doms = defaultdict(lambda: [set(), 0])   # корневой домен -> (кто, сколько раз)
    ips = defaultdict(lambda: [set(), 0])
    line_re = re.compile(
        r'^(\S+ \S+)\s.*accepted\s+\w+:([^\s:]+):\d+\s+\[([^\]]+)\]'
        r'(?:\s+email:\s*(\S+))?')
    for line in open(ACCESS_LOG, encoding="utf-8", errors="replace"):
        m = line_re.search(line)
        if not m:
            continue
        ts, dst, route, who = m.group(1), m.group(2), m.group(3), m.group(4) or "?"
        if since and ts < since:
            continue
        if route.startswith("api"):
            continue
        dst = dst.lower()
        if re.match(r"^\d+\.\d+\.\d+\.\d+$", dst):
            rec = ips[dst]
        else:
            rec = doms[base_domain(dst)]
        rec[0].add(who)
        rec[1] += 1

    report = {"broken_rules": [], "new_ru_domain": [], "ru_by_ip": [], "check_by_hand": []}

    for dom, (users, hits) in doms.items():
        label = dom.split(".")[0]
        rec = {"dst": dom, "users": sorted(users), "hits": hits}
        if covered(dom, direct):
            # уже в списке обхода, а всё равно приехал -> клиент правила не применяет
            report["broken_rules"].append(rec)
        elif dom.endswith(RU_TLD):
            report["new_ru_domain"].append(rec)
        elif any(b == label for b in BRANDS):
            report["check_by_hand"].append(rec)

    # адреса без домена проверяем по ipset и обратной записи
    for ip, (users, hits) in ips.items():
        if not in_russia(ip):
            continue
        report["ru_by_ip"].append({"dst": ip, "users": sorted(users), "hits": hits,
                                    "rdns": rdns(ip)})

    for k in report:
        report[k].sort(key=lambda r: -r["hits"])

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    os.replace(tmp, OUT)

    titles = {
        "broken_rules": "УЖЕ В СПИСКЕ, но всё равно шло через тоннель (у клиента не работают правила)",
        "new_ru_domain": "российский домен, которого нет в списке обхода",
        "ru_by_ip": "российский адрес без имени (QUIC или соединение по IP)",
        "check_by_hand": "похоже на российский сервис на зарубежном домене — проверить",
    }
    total = sum(len(v) for v in report.values())
    print("итого кандидатов: %d" % total)
    for k, title in titles.items():
        rows = report[k]
        if not rows:
            continue
        print("\n%s (%d):" % (title, len(rows)))
        for r in rows[:20]:
            extra = (" [%s]" % r["rdns"]) if r.get("rdns") else ""
            print("  %-30s %5d раз  %s%s"
                  % (r["dst"][:30], r["hits"], ",".join(r["users"]), extra))
        if len(rows) > 20:
            print("  … ещё %d" % (len(rows) - 20))


if __name__ == "__main__":
    main()
