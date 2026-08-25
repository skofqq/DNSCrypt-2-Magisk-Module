#!/system/bin/sh
# late_start service: поднимаем присмотр за dnscrypt-proxy и правила перехвата.
# Раньше здесь был сам цикл перезапуска; теперь логика в scripts/supervisor.sh.
MODDIR=${0%/*}
export MODDIR
( "$MODDIR/scripts/supervisor.sh" >/dev/null 2>&1 & )
