#!/usr/bin/env bash
# Обновление зеркала баз правил, которое раздаётся клиентам с нашего же сервера.
#
# Зачем зеркало: клиенты тянут .srs/.mrs при первом запуске, а GitHub из России
# доступен через раз — без правил подписка бесполезна ровно в момент установки.
#
# Замена только атомарная и только после проверок. Один раз уже было, что
# оборванная запись оставила пустой файл и он затёр рабочий; здесь скачивание
# идёт во временный файл, и он переезжает на место, лишь если прошёл проверки.
set -u
export LC_ALL=C

DIR=/var/www/vpn-help/rules
LOG=/var/log/rules-mirror.log
SG=https://raw.githubusercontent.com/SagerNet
MC=https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo
ID=https://github.com/itdoginfo/allow-domains/releases/latest/download
IDR=https://raw.githubusercontent.com/itdoginfo/allow-domains/main
MIN=100          # ниже этого — страница ошибки, а не файл

# Размер плохой признак: законный набор из 39 доменов весит 474 байта и порог
# 500 его отбраковал. Проверяем формат: .srs начинается с «SRS» и байта версии,
# .mrs — это zstd (28 b5 2f fd).
good_format() {
  case "$1" in
    *.srs) [ "$(head -c 3 "$2" | tr -d '\0')" = "SRS" ] ;;
    *.mrs) [ "$(head -c 4 "$2" | od -An -tx1 | tr -d ' \n')" = "28b52ffd" ] ;;
    *)     return 0 ;;
  esac
}

# имя_файла<TAB>адрес
#
# blocked-* — заблокированное в России. Эти правила обязаны стоять ВЫШЕ
# российских: `geosite:category-ru` тянет include:tld-ru, то есть ВСЕ `.ru`
# целиком. Без такого порядка theins.ru и republic.ru уходят мимо тоннеля и не
# открываются вовсе — провайдер их режет, а мы им в этом помогаем.
#
# outside-* — российские сервисы, которые сами отбивают зарубежные адреса.
# Дополняет ручной список: там 41 домен, включая госуслуги, налоговую и РЖД.
LIST=$(cat <<SRC
geosite-ru.srs	$SG/sing-geosite/rule-set/geosite-category-ru.srs
geosite-gov-ru.srs	$SG/sing-geosite/rule-set/geosite-category-gov-ru.srs
geosite-ads.srs	$SG/sing-geosite/rule-set/geosite-category-ads-all.srs
geoip-ru.srs	$SG/sing-geoip/rule-set/geoip-ru.srs
clash-geosite-ru.mrs	$MC/geosite/category-ru.mrs
clash-geosite-gov-ru.mrs	$MC/geosite/category-gov-ru.mrs
clash-ads.mrs	$MC/geosite/category-ads-all.mrs
clash-geoip-ru.mrs	$MC/geoip/ru.mrs
blocked-news.srs	$ID/news.srs
blocked-news.mrs	$ID/news_domain.mrs
blocked-inside.srs	$ID/russia_inside.srs
blocked-inside.mrs	$ID/russia_inside_domain.mrs
outside-ru.srs	$ID/russia_outside.srs
outside-ru.mrs	$ID/russia_outside_domain.mrs
SRC
)

# Отдельно, не как база правил: сырые списки нужны, чтобы собрать короткий
# перечень доменов для форматов, где правила едут заголовком (там есть предел
# размера) — Happ и INCY полноценный набор правил не проглотят.
RAW="blocked-news.lst	$IDR/Categories/news.lst
outside-ru.lst	$IDR/Russia/outside-raw.lst
blocked-inside.lst	$IDR/Categories/block.lst"

log() { echo "$(date -Is) $*" >> "$LOG"; }

mkdir -p "$DIR"
ok=0; fail=0; same=0
while IFS=$'\t' read -r name url; do
  [ -n "$name" ] || continue
  tmp="$DIR/.$name.tmp"
  if ! curl -sfL -m 90 -o "$tmp" "$url"; then
    log "СКАЧАТЬ НЕ ВЫШЛО $name ($url) — оставляю прежний файл"
    rm -f "$tmp"; fail=$((fail+1)); continue
  fi
  size=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
  if [ "$size" -lt "$MIN" ] || ! good_format "$name" "$tmp"; then
    log "ОТКАЗ $name: $size байт, формат не распознан — оставляю прежний"
    rm -f "$tmp"; fail=$((fail+1)); continue
  fi
  if [ -f "$DIR/$name" ] && cmp -s "$tmp" "$DIR/$name"; then
    rm -f "$tmp"; same=$((same+1)); continue
  fi
  chmod 644 "$tmp"
  mv -f "$tmp" "$DIR/$name"           # атомарно: клиент никогда не увидит половину файла
  log "обновлён $name ($size байт)"
  ok=$((ok+1))
done <<< "$LIST"

# Сырые текстовые списки — те же проверки, свой минимум размера
while IFS=$'\t' read -r name url; do
  [ -n "$name" ] || continue
  tmp="$DIR/.$name.tmp"
  if ! curl -sfL -m 90 -o "$tmp" "$url"; then
    log "СКАЧАТЬ НЕ ВЫШЛО $name — оставляю прежний"; rm -f "$tmp"; fail=$((fail+1)); continue
  fi
  lines=$(grep -cvE '^\s*(#|$)' "$tmp" 2>/dev/null || echo 0)
  if [ "$lines" -lt 20 ]; then
    log "ОТКАЗ $name: строк $lines, это не список"; rm -f "$tmp"; fail=$((fail+1)); continue
  fi
  if [ -f "$DIR/$name" ] && cmp -s "$tmp" "$DIR/$name"; then
    rm -f "$tmp"; same=$((same+1)); continue
  fi
  chmod 644 "$tmp"; mv -f "$tmp" "$DIR/$name"
  log "обновлён $name ($lines доменов)"; ok=$((ok+1))
done <<< "$RAW"

log "итог: обновлено $ok, без изменений $same, не вышло $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
