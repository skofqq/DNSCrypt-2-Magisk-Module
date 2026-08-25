#!/system/bin/sh
# Снятие модуля. Прежняя версия ждала загрузку условием
#   while [ boot != 1 ] && [ ! -d /storage/emulated/0/... ]
# то есть выходила, как только выполнялось ЛЮБОЕ из условий, и удаляла файлы
# по ещё не смонтированным путям - каталог на внутренней памяти оставался.
MODDIR=${0%/*}
export MODDIR
. "$MODDIR/scripts/common.sh"
. "$MODDIR/scripts/netfilter.sh"
load_settings

# Останавливаем присмотр и сам прокси.
for f in "$LOCKFILE" "$PIDFILE"; do
  pid=$(cat "$f" 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
done
pkill -f "$MODDIR/system/bin/dnscrypt-proxy" 2>/dev/null

nf_stop

# Копию конфига оставляем рядом с бывшим зеркалом - пользовательские правки
# восстановить проще, чем вспомнить.
if [ -f "$CONFIG" ]; then
  cp -f "$CONFIG" "/data/media/0/dnscrypt-proxy.toml.bak" 2>/dev/null
  chown 0:1023 "/data/media/0/dnscrypt-proxy.toml.bak" 2>/dev/null
fi

rm -rf "$DATADIR"

# Зеркало и следы старых версий на внутренней памяти. Ждём готовности хранилища,
# но не дольше двух минут - при удалении из приложения оно уже смонтировано.
(
  i=0
  while [ "$(getprop sys.boot_completed)" != "1" ] || [ ! -d /data/media/0 ]; do
    i=$((i + 1))
    [ "$i" -gt 120 ] && break
    sleep 1
  done
  for p in /data/media/0/dnscrypt-proxy /storage/emulated/0/dnscrypt-proxy \
           /sdcard/dnscrypt-proxy /storage/self/primary/dnscrypt-proxy \
           /mnt/runtime/default/emulated/0/dnscrypt-proxy \
           /mnt/runtime/full/emulated/0/dnscrypt-proxy \
           /mnt/runtime/read/emulated/0/dnscrypt-proxy \
           /mnt/runtime/write/emulated/0/dnscrypt-proxy; do
    rm -rf "$p" 2>/dev/null
  done
) &
