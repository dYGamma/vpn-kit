#!/bin/sh
# Синхронизировать клиентов и перезапустить вход ТОЛЬКО если конфиг изменился.
/usr/local/sbin/xray-ss-sync.py
case $? in
  0) systemctl restart xray-ss ;;   # список поменялся
  3) : ;;                           # изменений нет, ничего не трогаем
  *) exit 1 ;;
esac
