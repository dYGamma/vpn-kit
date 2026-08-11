#!/usr/bin/env python3
"""Переходник на свежий файл релиза с GitHub.

Часть приложений держит версию в имени файла, поэтому вечной ссылки у них нет.
Здесь по короткому имени спрашиваем у GitHub последний релиз, находим нужный
файл по образцу и отдаём на него перенаправление. Ответ кешируем на час,
чтобы не долбить чужой API и не зависеть от него на каждом клике.
"""
import json
import re
import time
import urllib.request

# короткое имя -> (репозиторий, образец имени файла)
TARGETS = {
    "v2rayng-android": ("2dust/v2rayNG",                    r"_arm64-v8a\.apk$"),
    "nekobox-android": ("MatsuriDayo/NekoBoxForAndroid",     r"-arm64-v8a\.apk$"),
    "nekoray-windows": ("MatsuriDayo/nekoray",               r"windows64\.zip$"),
    "nekoray-linux":   ("MatsuriDayo/nekoray",               r"linux-x64\.AppImage$"),
    "verge-windows":   ("clash-verge-rev/clash-verge-rev",   r"_x64-setup\.exe$"),
    "verge-macos":     ("clash-verge-rev/clash-verge-rev",   r"_aarch64\.dmg$"),
    "verge-linux":     ("clash-verge-rev/clash-verge-rev",   r"_amd64\.deb$"),
    "v2rayn-windows":  ("2dust/v2rayN",                      r"^v2rayN-windows-64\.zip$"),
    "v2rayn-linux":    ("2dust/v2rayN",                      r"^v2rayN-linux-64\.deb$"),
    "sfm-macos":       ("SagerNet/sing-box",                 r"^SFM-.*\.pkg$"),
}

TTL = 3600
_cache = {}


def resolve(slug):
    """Прямой адрес файла или None, если такого имени нет / GitHub недоступен."""
    if slug not in TARGETS:
        return None
    hit = _cache.get(slug)
    if hit and time.time() - hit[0] < TTL:
        return hit[1]

    repo, pattern = TARGETS[slug]
    req = urllib.request.Request(
        "https://api.github.com/repos/%s/releases/latest" % repo,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "vpn-issue"})
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            data = json.load(r)
    except Exception:
        # Отдать прошлый ответ лучше, чем ничего: файл вряд ли исчез.
        return hit[1] if hit else None

    rx = re.compile(pattern)
    for a in data.get("assets", []):
        if rx.search(a.get("name", "")):
            url = a.get("browser_download_url")
            _cache[slug] = (time.time(), url)
            return url
    return hit[1] if hit else None
