#!/system/bin/sh
# late_start service: поднимаем присмотр за dnscrypt-proxy и правила перехвата.
# Раньше здесь был сам цикл перезапуска; теперь логика в scripts/supervisor.sh.
MODDIR=${0%/*}
export MODDIR
. "$MODDIR/scripts/common.sh"
load_settings

# Автозапуск можно выключить: модуль остаётся установленным, но при
# загрузке ничего не поднимает и правил не ставит. Ручной запуск идёт
# мимо этого файла (start_supervisor), поэтому работает как обычно.
if ! is_true "$autostart"; then
  log "автозапуск выключен, при загрузке ничего не поднимаю"
  exit 0
fi

( "$MODDIR/scripts/supervisor.sh" >/dev/null 2>&1 & )
