#!/system/bin/sh
# Постановка и снятие правил перехвата DNS.
#
# Правила живут в собственной цепочке nat/DNSCRYPT, а не россыпью в OUTPUT:
# так их можно переставить идемпотентно и снять целиком, не задевая netd.
# Ставятся они из service.sh (late_start), а не из post-fs-data - netd
# перестраивает свои цепочки при старте и раньше срока правила терялись.

IPT=iptables
IPT6=ip6tables

nf_init_cmd() {
  if $IPT -w 2 -t nat -L -n >/dev/null 2>&1; then
    IPT="iptables -w 2"
    IPT6="ip6tables -w 2"
  fi
}

# DNAT на 127.0.0.1 из OUTPUT ядро отбросит, если route_localnet выключен.
# Оригинальный модуль этого не делал - отсюда «правила есть, DNS не идёт».
nf_enable_route_localnet() {
  for f in /proc/sys/net/ipv4/conf/all/route_localnet /proc/sys/net/ipv4/conf/default/route_localnet; do
    [ -w "$f" ] || continue
    old=$(cat "$f" 2>/dev/null)
    [ "$old" = "1" ] || echo "$old" >"$DATADIR/.route_localnet.$(basename "$(dirname "$f")")"
    echo 1 >"$f" 2>/dev/null
  done
}

nf_restore_route_localnet() {
  for scope in all default; do
    bak="$DATADIR/.route_localnet.$scope"
    [ -f "$bak" ] || continue
    cat "$bak" >"/proc/sys/net/ipv4/conf/$scope/route_localnet" 2>/dev/null
    rm -f "$bak"
  done
}

nf_build_chain() {
  port=$(listen_port)
  $IPT -t nat -N $NAT_CHAIN 2>/dev/null
  $IPT -t nat -F $NAT_CHAIN 2>/dev/null

  # Апстрим самого dnscrypt-proxy наружу - иначе он завернёт себя же.
  for ip in $(exclusions_v4); do
    $IPT -t nat -A $NAT_CHAIN -d "$ip" -j RETURN 2>/dev/null
  done
  $IPT -t nat -A $NAT_CHAIN -d 127.0.0.0/8 -j RETURN 2>/dev/null

  $IPT -t nat -A $NAT_CHAIN -p udp --dport 53 -j DNAT --to-destination "127.0.0.1:$port" 2>/dev/null
  $IPT -t nat -A $NAT_CHAIN -p tcp --dport 53 -j DNAT --to-destination "127.0.0.1:$port" 2>/dev/null
}

nf_build_chain6() {
  port6=$(listen_port6)
  [ -n "$port6" ] || return 1
  $IPT6 -t nat -L -n >/dev/null 2>&1 || return 1
  $IPT6 -t nat -N $NAT_CHAIN 2>/dev/null || return 1
  $IPT6 -t nat -F $NAT_CHAIN 2>/dev/null

  for ip in $(exclusions_v6); do
    $IPT6 -t nat -A $NAT_CHAIN -d "$ip" -j RETURN 2>/dev/null
  done
  $IPT6 -t nat -A $NAT_CHAIN -d ::1/128 -j RETURN 2>/dev/null

  $IPT6 -t nat -A $NAT_CHAIN -p udp --dport 53 -j DNAT --to-destination "[::1]:$port6" 2>/dev/null || return 1
  $IPT6 -t nat -A $NAT_CHAIN -p tcp --dport 53 -j DNAT --to-destination "[::1]:$port6" 2>/dev/null || return 1
  return 0
}

# Привязки OUTPUT -> DNSCRYPT. Проверка -C перед -I, иначе при каждом
# перезапуске накапливались дубликаты правил.
nf_link() {
  cmd=$1; table_chain=$2; proto=$3; extra=$4
  # shellcheck disable=SC2086
  $cmd -t nat -C $table_chain -p "$proto" --dport 53 $extra -j $NAT_CHAIN 2>/dev/null && return 0
  # shellcheck disable=SC2086
  $cmd -t nat -I $table_chain -p "$proto" --dport 53 $extra -j $NAT_CHAIN 2>/dev/null
}

nf_unlink_all() {
  cmd=$1; table_chain=$2
  for proto in udp tcp; do
    while $cmd -t nat -D $table_chain -p $proto --dport 53 -j $NAT_CHAIN 2>/dev/null; do :; done
    # Правила с -i бывают только в PREROUTING (режим tether_redirect).
    [ "$table_chain" = PREROUTING ] || continue
    for ifp in ap+ wlan+ swlan+ rndis+ usb+ bt-pan; do
      while $cmd -t nat -D $table_chain -i $ifp -p $proto --dport 53 -j $NAT_CHAIN 2>/dev/null; do :; done
    done
  done
}

nf_start() {
  nf_init_cmd
  nf_enable_route_localnet
  nf_build_chain

  if is_true "$redirect_ipv4"; then
    nf_link "$IPT" OUTPUT udp
    nf_link "$IPT" OUTPUT tcp
  fi

  # Клиенты хотспота: по умолчанию не трогаем. Именно вмешательство в
  # tethering (и глобальное отключение IPv6) ломало раздачу Wi-Fi.
  if is_true "$tether_redirect"; then
    for ifp in ap+ wlan+ swlan+ rndis+ usb+ bt-pan; do
      nf_link "$IPT" PREROUTING udp "-i $ifp"
      nf_link "$IPT" PREROUTING tcp "-i $ifp"
    done
  fi

  case "$redirect_ipv6" in
    redirect|auto)
      if nf_build_chain6; then
        nf_link "$IPT6" OUTPUT udp
        nf_link "$IPT6" OUTPUT tcp
        log "IPv6: перехват DNS включён"
      else
        # Молча оставляем IPv6-DNS системе: REJECT здесь убил бы резолвинг
        # в IPv6-only сетях, а глобальное отключение IPv6 - раздачу Wi-Fi.
        [ "$redirect_ipv6" = "redirect" ] && log "IPv6: nat-таблица недоступна, перехват пропущен"
        [ "$redirect_ipv6" = "auto" ] && log "IPv6: перехват недоступен (нет ip6tables nat), пропущено"
      fi
      ;;
    *) log "IPv6: перехват отключён настройкой" ;;
  esac
}

# Проверка, что привязки на месте: netd при смене сети или включении
# tethering перестраивает nat и может унести их с собой.
nf_check() {
  is_true "$redirect_ipv4" || return 0
  $IPT -t nat -C OUTPUT -p udp --dport 53 -j $NAT_CHAIN 2>/dev/null && \
  $IPT -t nat -C OUTPUT -p tcp --dport 53 -j $NAT_CHAIN 2>/dev/null
}

nf_stop() {
  nf_init_cmd
  nf_unlink_all "$IPT" OUTPUT
  nf_unlink_all "$IPT" PREROUTING
  $IPT -t nat -F $NAT_CHAIN 2>/dev/null
  $IPT -t nat -X $NAT_CHAIN 2>/dev/null
  nf_unlink_all "$IPT6" OUTPUT
  $IPT6 -t nat -F $NAT_CHAIN 2>/dev/null
  $IPT6 -t nat -X $NAT_CHAIN 2>/dev/null
  nf_restore_route_localnet
}
