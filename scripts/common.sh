#!/system/bin/sh
# Общие пути, настройки и функции модуля dnscrypt-proxy-android.
# Подключается всеми остальными скриптами через `. "$MODDIR/scripts/common.sh"`.

MODID=dnscrypt-proxy-android
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/$MODID

# Рабочие данные лежат на /data/adb: раздел доступен уже в post-fs-data,
# переживает FBE-блокировку экрана и чистится вместе с модулем.
DATADIR=/data/adb/dnscrypt-proxy
CONFIG="$DATADIR/dnscrypt-proxy.toml"
SETTINGS="$DATADIR/module.conf"
LOGFILE="$DATADIR/module.log"
PIDFILE="$DATADIR/dnscrypt-proxy.pid"
LOCKFILE="$DATADIR/supervisor.pid"
BIN="$MODDIR/system/bin/dnscrypt-proxy"

# Зеркало конфига для файлового менеджера. /data/media/0 - настоящий ext4/f2fs,
# то же самое, что видно как /storage/emulated/0.
MIRROR=/data/media/0/dnscrypt-proxy

NAT_CHAIN=DNSCRYPT
LOG_MAX_SIZE=262144

# --- настройки модуля (переопределяются в $SETTINGS) ---------------------
redirect_ipv4=true
redirect_ipv6=auto        # auto | redirect | off
tether_redirect=false
disable_private_dns=true
mirror_config=true
restart_delay_max=60

load_settings() {
  [ -f "$SETTINGS" ] || return 0
  # Читаем только строки вида ключ=значение, без исполнения произвольного кода.
  while IFS='=' read -r key value; do
    case "$key" in
      redirect_ipv4|redirect_ipv6|tether_redirect|disable_private_dns|mirror_config|restart_delay_max)
        value=$(echo "$value" | tr -d " \t\r\"'")
        eval "$key=\$value"
        ;;
    esac
  done <<SETTINGS_EOF
$(grep -E '^[[:space:]]*[a-z_]+[[:space:]]*=' "$SETTINGS" 2>/dev/null | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*=[[:space:]]*/=/')
SETTINGS_EOF
}

log_rotate() {
  [ -f "$LOGFILE" ] || return 0
  size=$(stat -c %s "$LOGFILE" 2>/dev/null) || return 0
  [ "$size" -gt "$LOG_MAX_SIZE" ] 2>/dev/null && mv -f "$LOGFILE" "$LOGFILE.1"
  return 0
}

log() {
  mkdir -p "$DATADIR" 2>/dev/null
  log_rotate
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOGFILE"
}

# Порт, на котором dnscrypt-proxy слушает локально. Берём из конфига,
# чтобы правила iptables не разъезжались с listen_addresses.
listen_port() {
  port=$(grep -m1 '^[[:space:]]*listen_addresses' "$CONFIG" 2>/dev/null \
    | grep -oE '127\.0\.0\.1:[0-9]+' | head -1 | cut -d: -f2)
  [ -n "$port" ] || port=5354
  echo "$port"
}

# IPv6-порт может отличаться от IPv4 только по недосмотру, но проверим отдельно.
listen_port6() {
  port=$(grep -m1 '^[[:space:]]*listen_addresses' "$CONFIG" 2>/dev/null \
    | grep -oE '\[::1\]:[0-9]+' | head -1 | sed 's/.*://')
  echo "$port"
}

# Адреса, которые нельзя заворачивать в dnscrypt-proxy, иначе получим петлю:
# bootstrap-резолверы, netprobe и всё, что пользователь добавил руками.
# Раньше здесь был один захардкоженный IP - при смене резолвера модуль ломался.
exclusions_v4() {
  {
    grep -E '^[[:space:]]*(bootstrap_resolvers|netprobe_address|fallback_resolvers)' "$CONFIG" 2>/dev/null
    cat "$DATADIR/exclude-ips.txt" 2>/dev/null
  } | grep -oE '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u
}

exclusions_v6() {
  {
    grep -E '^[[:space:]]*(bootstrap_resolvers|netprobe_address|fallback_resolvers)' "$CONFIG" 2>/dev/null
    cat "$DATADIR/exclude-ips.txt" 2>/dev/null
  } | grep -oE '\[[0-9a-fA-F:]+\]' | tr -d '[]' | grep ':' | sort -u
}

is_true() { [ "$1" = "true" ] || [ "$1" = "1" ] || [ "$1" = "yes" ]; }

dnscrypt_pid() {
  [ -f "$PIDFILE" ] || return 1
  pid=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  echo "$pid"
}

# --- работа со списком серверов -----------------------------------------
# Кэш резолверов качает и проверяет подписью minisign сам dnscrypt-proxy;
# мы его только читаем. Имя задано как cache_file в [sources], путь - от DATADIR.
RESOLVERS_CACHE="$DATADIR/public-resolvers.md"
RELAYS_CACHE="$DATADIR/relays.md"

# Активное значение server_names: имена через запятую либо слово auto,
# если строка закомментирована и прокси подбирает серверы сам.
servers_get() {
  line=$(grep -m1 '^[[:space:]]*server_names[[:space:]]*=' "$CONFIG" 2>/dev/null)
  if [ -z "$line" ]; then
    echo auto
    return 0
  fi
  echo "$line" | sed 's/.*\[//; s/\].*//' | tr -d " '\"" 
}

config_backup() {
  [ -f "$CONFIG" ] || return 1
  cp -f "$CONFIG" "$CONFIG-$(date +%Y%m%d%H%M%S).bak"
}

# Записываем server_names, сохраняя место ключа в файле. Если активной строки
# нет, вставляем её перед первой таблицей [...]: ключи верхнего уровня в TOML
# обязаны идти до первой секции.
servers_set() {
  names=$1
  val=""
  for n in $(echo "$names" | tr ',' ' '); do
    [ -n "$n" ] || continue
    case "$n" in
      *[!A-Za-z0-9._-]*) log "servers: недопустимое имя пропущено: $n"; continue ;;
    esac
    if [ -z "$val" ]; then val="'$n'"; else val="$val, '$n'"; fi
  done
  [ -n "$val" ] || return 1
  config_backup || return 1
  tmp="$CONFIG.tmp.$$"
  awk -v val="$val" '
    BEGIN { done = 0 }
    !done && /^[[:space:]]*server_names[[:space:]]*=/ { print "server_names = [" val "]"; done = 1; next }
    !done && /^[[:space:]]*\[/ { print "server_names = [" val "]"; print ""; done = 1 }
    { print }
    END { if (!done) print "server_names = [" val "]" }
  ' "$CONFIG" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$CONFIG"
}

# Возврат к автоподбору: строку не удаляем, а комментируем - прежний выбор
# остаётся виден и его можно вернуть руками.
servers_auto() {
  grep -q '^[[:space:]]*server_names[[:space:]]*=' "$CONFIG" 2>/dev/null || return 0
  config_backup || return 1
  sed -i 's/^\([[:space:]]*\)server_names\([[:space:]]*\)=/\1# server_names\2=/' "$CONFIG"
}

servers_list() {
  [ -f "$RESOLVERS_CACHE" ] || return 1
  grep '^## ' "$RESOLVERS_CACHE" | sed 's/^## //'
}
