#!/system/bin/sh
# Ранняя подготовка данных. Правила iptables здесь НЕ ставим: netd стартует
# позже и перестраивает свои цепочки, из-за чего перехват отваливался,
# а вмешательство в сеть на этой стадии ломало раздачу Wi-Fi.
MODDIR=${0%/*}
export MODDIR
. "$MODDIR/scripts/common.sh"

mkdir -p "$DATADIR"
chmod 0700 "$DATADIR"

# Конфиг на /data/adb доступен уже сейчас, до разблокировки экрана.
if [ ! -f "$CONFIG" ] && [ -f "$MODDIR/config/dnscrypt-proxy.toml" ]; then
  cp -af "$MODDIR"/config/. "$DATADIR"/
fi
[ -f "$SETTINGS" ] || cp -af "$MODDIR/config/module.conf" "$SETTINGS" 2>/dev/null
