#!/usr/bin/env bash
# Сборка установочного zip. Бинарники всех архитектур кладутся в пакет:
# раньше по умолчанию собирался zip только с arm64, и на x86_64 (эмулятор
# Android Studio, Chromebook) установка обрывалась на «Бинарник отсутствует».
# В репозитории лежит arm64, остальные докачиваются с релиза dnscrypt-proxy.
# Ключ --arm64 собирает старый вариант только с arm64.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(sed -n 's/^version=//p' module.prop)
# С 2.2 у модуля своя нумерация, версию dnscrypt-proxy берём отдельно:
# раньше она вычислялась из module.prop, и --all качал несуществующий 2.4.
UPSTREAM=2.1.18
OUT="dnscrypt-proxy-android-${VERSION}.zip"
ITEMS="module.prop customize.sh service.sh post-fs-data.sh uninstall.sh scripts config binary tools META-INF LICENSE.md README.md CHANGELOG.md"

if [ "${1:-}" != "--arm64" ]; then
  # Временный каталог рядом со скриптом и с относительным путём: в Git Bash
  # с MSYS_NO_PATHCONV=1 нативный curl.exe не понимает /tmp/... от mktemp
  # и падает с «curl: (23) ERROR on write».
  tmp=$(mktemp -d .dl.XXXXXX)
  for pair in arm:android-arm i386:android-i386 x86_64:android-x86_64; do
    name=${pair%%:*}; dir=${pair##*:}
    [ -s "binary/dnscrypt-proxy-$name" ] && continue
    url="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${UPSTREAM}/dnscrypt-proxy-${dir/-/_}-${UPSTREAM}.zip"
    echo "качаю $name"
    curl -fsSL -o "$tmp/$name.zip" "$url"
    unzip -oq "$tmp/$name.zip" -d "$tmp"
    cp -f "$tmp/$dir/dnscrypt-proxy" "binary/dnscrypt-proxy-$name"
  done
  rm -rf "$tmp"
fi

rm -f "$OUT"

# Настоящий питон, а не заглушка Microsoft Store: в Git Bash на Windows
# python/python3 часто ведут в WindowsApps и только печатают подсказку.
find_python() {
  for p in python3 python py; do
    command -v "$p" >/dev/null 2>&1 || continue
    "$p" -c 'import zipfile' >/dev/null 2>&1 && { echo "$p"; return 0; }
  done
  return 1
}

find_tool() {
  for p in "$@"; do
    command -v "$p" >/dev/null 2>&1 && { command -v "$p"; return 0; }
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

if command -v zip >/dev/null 2>&1; then
  zip -r9 "$OUT" $ITEMS -x '*.orig' '*.bak' >/dev/null
elif PY=$(find_python); then
  # На Windows/Git Bash zip обычно отсутствует. Собираем питоном и обязательно
  # с прямыми слэшами внутри архива, иначе Magisk не разберёт пакет.
  OUT="$OUT" ITEMS="$ITEMS" "$PY" - <<'PYZIP'
import os, zipfile
out = os.environ["OUT"]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for item in os.environ["ITEMS"].split():
        if os.path.isfile(item):
            z.write(item, item)
            continue
        for root, _dirs, files in os.walk(item):
            for name in files:
                if name.endswith((".orig", ".bak")):
                    continue
                full = os.path.join(root, name)
                z.write(full, full.replace(os.sep, "/"))
PYZIP
elif SZ=$(find_tool 7z 7z.exe "/c/Program Files/7-Zip/7z.exe"); then
  # 7-Zip пишет в zip пути с прямыми слэшами, как того требует формат.
  # shellcheck disable=SC2086
  "$SZ" a -tzip -mx=9 "$OUT" $ITEMS '-xr!*.orig' '-xr!*.bak' >/dev/null
elif JAR=$(find_tool jar jar.exe "/c/Program Files/Android/Android Studio/jbr/bin/jar.exe"); then
  # jar из JDK Android Studio: обычный zip без манифеста (-M).
  # shellcheck disable=SC2086
  "$JAR" -cfM "$OUT" $ITEMS
else
  echo "нечем упаковать zip: нужен zip, python, 7-Zip или jar из JDK" >&2
  exit 1
fi
[ -s "$OUT" ] || { echo "архив $OUT не создан" >&2; exit 1; }
echo "готово: $OUT ($(du -h "$OUT" | cut -f1))"
