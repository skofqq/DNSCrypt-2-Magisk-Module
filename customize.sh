SKIPUNZIP=0

ui_print " "
ui_print "******************************"
ui_print "*   dnscrypt-proxy-android   *"
ui_print "*            2.4             *"
ui_print "******************************"
ui_print " "

DATADIR=/data/adb/dnscrypt-proxy
LEGACY=/data/media/0/dnscrypt-proxy

case "$ARCH" in
  arm)   BINARY_PATH=$MODPATH/binary/dnscrypt-proxy-arm ;;
  arm64) BINARY_PATH=$MODPATH/binary/dnscrypt-proxy-arm64 ;;
  x86)   BINARY_PATH=$MODPATH/binary/dnscrypt-proxy-i386 ;;
  x64)   BINARY_PATH=$MODPATH/binary/dnscrypt-proxy-x86_64 ;;
  *)     abort "! Неизвестная архитектура: $ARCH" ;;
esac

[ -n "$KSU" ] && ui_print "! KernelSU не тестировался, модуль рассчитан на Magisk"
[ -n "$APATCH" ] && ui_print "! APatch не тестировался, модуль рассчитан на Magisk"

ui_print "* Устанавливаю бинарник dnscrypt-proxy ($ARCH)."
mkdir -p "$MODPATH/system/bin"
if [ -f "$BINARY_PATH" ]; then
  cp -af "$BINARY_PATH" "$MODPATH/system/bin/dnscrypt-proxy"
else
  abort "! Бинарник для $ARCH отсутствует в пакете!"
fi
cp -af "$MODPATH/tools/dnscrypt-ctl" "$MODPATH/system/bin/dnscrypt-ctl"

mkdir -p "$DATADIR"

# Переезд с /storage/emulated/0: оттуда конфиг не читался до разблокировки
# экрана, и он же оставался мусором после удаления модуля.
if [ -f "$LEGACY/dnscrypt-proxy.toml" ] && [ ! -f "$DATADIR/dnscrypt-proxy.toml" ]; then
  ui_print "* Переношу существующий конфиг в $DATADIR."
  cp -af "$LEGACY"/*.toml "$LEGACY"/*.txt "$DATADIR"/ 2>/dev/null
fi

if [ -f "$DATADIR/dnscrypt-proxy.toml" ]; then
  ui_print "* Конфиг уже есть - оставляю ваш, новый рядом как .new"
  cp -af "$MODPATH/config/dnscrypt-proxy.toml" "$DATADIR/dnscrypt-proxy.toml.new"
  cp -f "$DATADIR/dnscrypt-proxy.toml" "$DATADIR/dnscrypt-proxy.toml-$(date +%Y%m%d%H%M).bak"
else
  ui_print "* Разворачиваю конфиг по умолчанию."
  cp -af "$MODPATH"/config/dnscrypt-proxy.toml "$DATADIR"/
fi

for f in blocked-names.txt blocked-ips.txt allowed-names.txt allowed-ips.txt module.conf; do
  [ -f "$DATADIR/$f" ] || cp -af "$MODPATH/config/$f" "$DATADIR/$f" 2>/dev/null
done

ui_print "* Выставляю права."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/system/bin/dnscrypt-proxy" 0 0 0755
set_perm "$MODPATH/system/bin/dnscrypt-ctl" 0 0 0755
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
chmod 0700 "$DATADIR"
chmod 0600 "$DATADIR"/*.toml 2>/dev/null

ui_print "* Убираю лишние файлы."
rm -rf "$MODPATH/binary" "$MODPATH/tools"

ui_print " "
ui_print "  Конфиг:  $DATADIR/dnscrypt-proxy.toml"
ui_print "  Настройки: $DATADIR/module.conf"
ui_print "  Управление: dnscrypt-ctl status | restart | log"
ui_print "  Private DNS будет выключен после загрузки."
ui_print " "
