#!/system/bin/sh
# Присмотр за процессом dnscrypt-proxy.
#
# Старый service.sh крутил `while ! [ `pgrep -x dnscrypt-proxy` ]` с `&& sleep 15`:
# пауза выполнялась только при выходе с кодом 0, поэтому падающий бинарник
# (например, когда конфиг ещё не смонтирован) перезапускался в цикле без пауз
# и высаживал батарею. Здесь - экспоненциальная пауза и понятный лог.

MODDIR=${MODDIR:-/data/adb/modules/dnscrypt-proxy-android}
. "$MODDIR/scripts/common.sh"
. "$MODDIR/scripts/netfilter.sh"
load_settings

acquire_lock() {
  if [ -f "$LOCKFILE" ]; then
    old=$(cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null && [ "$old" != "$$" ]; then
      log "supervisor уже запущен (pid $old), выхожу"
      exit 0
    fi
  fi
  echo $$ >"$LOCKFILE"
}

prepare_data() {
  mkdir -p "$DATADIR"
  chmod 0700 "$DATADIR"
  # Первая установка или пользователь удалил конфиг - разворачиваем дефолтный.
  if [ ! -f "$CONFIG" ] && [ -f "$MODDIR/config/dnscrypt-proxy.toml" ]; then
    cp -af "$MODDIR"/config/. "$DATADIR"/
    log "развёрнут конфиг по умолчанию"
  fi
  [ -f "$SETTINGS" ] || cp -af "$MODDIR/config/module.conf" "$SETTINGS" 2>/dev/null
  chmod 0600 "$CONFIG" 2>/dev/null
}

wait_netfilter() {
  i=0
  while [ $i -lt 60 ]; do
    iptables -t nat -L -n >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 1
  done
  log "iptables не отвечает, правила перехвата не поставлены"
  return 1
}

wait_boot() {
  i=0
  while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 300 ]; do
    i=$((i + 1))
    sleep 1
  done
  [ "$(getprop sys.boot_completed)" = "1" ]
}

# Конфиг живёт в /data/adb (доступен до разблокировки экрана), а на внутреннюю
# память кладётся копия для правки файловым менеджером. Симлинк или bind-mount
# сюда не годятся: FUSE не отдаёт симлинки, а SELinux-контекст adb_data_file
# закрыт для приложений.
mirror_sync() {
  is_true "$mirror_config" || return 0
  mkdir -p "$MIRROR" 2>/dev/null || return 0
  if [ -f "$MIRROR/dnscrypt-proxy.toml" ] && [ "$MIRROR/dnscrypt-proxy.toml" -nt "$CONFIG" ]; then
    cp -f "$MIRROR/dnscrypt-proxy.toml" "$CONFIG"
    log "конфиг импортирован из $MIRROR"
  else
    cp -f "$CONFIG" "$MIRROR/dnscrypt-proxy.toml" 2>/dev/null
  fi
  for f in blocked-names.txt blocked-ips.txt allowed-names.txt allowed-ips.txt exclude-ips.txt module.conf; do
    if [ -f "$MIRROR/$f" ] && [ "$MIRROR/$f" -nt "$DATADIR/$f" ]; then
      cp -f "$MIRROR/$f" "$DATADIR/$f"
      log "$f импортирован из $MIRROR"
    elif [ -f "$DATADIR/$f" ]; then
      cp -f "$DATADIR/$f" "$MIRROR/$f" 2>/dev/null
    fi
  done
  chmod -R 0644 "$MIRROR" 2>/dev/null
  chmod 0755 "$MIRROR" 2>/dev/null
  chown -R 0:1023 "$MIRROR" 2>/dev/null
}

# Private DNS перехватить нельзя - он ходит мимо порта 53 по DoT.
# `settings` доступен только после загрузки, в customize.sh (recovery) его нет.
disable_private_dns() {
  is_true "$disable_private_dns" || return 0
  current=$(settings get global private_dns_mode 2>/dev/null)
  [ "$current" = "off" ] && return 0
  settings put global private_dns_mode off 2>/dev/null \
    || cmd settings put global private_dns_mode off 2>/dev/null
  log "Private DNS переключён в off (было: ${current:-неизвестно})"
}

trim_logs() {
  for f in "$DATADIR/stdout.log" "$DATADIR/dnscrypt-proxy.log"; do
    [ -f "$f" ] || continue
    size=$(stat -c %s "$f" 2>/dev/null) || continue
    [ "$size" -gt 1048576 ] 2>/dev/null && : >"$f"
  done
  log_rotate
}

acquire_lock
log "--- старт модуля ($(getprop ro.build.version.release 2>/dev/null), Magisk $(magisk -V 2>/dev/null)) ---"
prepare_data

if wait_netfilter; then
  nf_start
  log "правила перехвата DNS поставлены (порт $(listen_port))"
fi

# Всё, что требует поднятой системы, не должно задерживать запуск прокси.
(
  wait_boot && {
    disable_private_dns
    mirror_sync
  }
) &

delay=5
while :; do
  if [ ! -f "$CONFIG" ]; then
    log "конфиг $CONFIG отсутствует, жду"
    sleep 10
    prepare_data
    continue
  fi

  started=$(date +%s)
  cd "$DATADIR" || exit 1
  gid=$(run_gid_numeric)
  # Проверяем смену группы заранее: настройка не должна ронять резолвинг.
  if [ -n "$gid" ] && ! su -g "$gid" 0 -c 'exit 0' >/dev/null 2>&1; then
    log "смена первичной группы на $gid недоступна, запускаю без неё"
    gid=""
  fi
  if [ -n "$gid" ]; then
    # box_for_magisk пропускает мимо своего перехвата трафик root:net_admin,
    # поэтому смена первичной группы выводит запросы прокси из-под него.
    # Опции su обязаны стоять до имени пользователя, иначе они уходят в шелл.
    su -g "$gid" 0 -c "cd '$DATADIR' && exec '$BIN' -config '$CONFIG'" >>"$DATADIR/stdout.log" 2>&1 &
    pid=$!
    # su остаётся посредником, поэтому pid самого прокси ищем отдельно.
    sleep 1
    real=$(pidof dnscrypt-proxy 2>/dev/null | tr ' ' '\n' | tail -1)
    [ -n "$real" ] && pid=$real
  else
    "$BIN" -config "$CONFIG" >>"$DATADIR/stdout.log" 2>&1 &
    pid=$!
  fi
  echo "$pid" >"$PIDFILE"
  log "dnscrypt-proxy запущен, pid $pid"

  while kill -0 "$pid" 2>/dev/null; do
    sleep 30
    if ! nf_check; then
      log "правила перехвата пропали (netd?), ставлю заново"
      nf_start
    fi
    trim_logs
  done
  wait "$pid" 2>/dev/null
  rc=$?
  rm -f "$PIDFILE"

  lived=$(( $(date +%s) - started ))
  if [ "$lived" -gt 120 ]; then
    delay=5
  fi
  log "dnscrypt-proxy завершился (код $rc, прожил ${lived}с), перезапуск через ${delay}с"
  sleep "$delay"
  delay=$((delay * 2))
  [ "$delay" -gt "$restart_delay_max" ] && delay="$restart_delay_max"
done
