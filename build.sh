#!/usr/bin/env bash
# Сборка установочного zip. По умолчанию берём то, что лежит в binary/
# (в репозитории это arm64). Ключ --all докачивает остальные архитектуры.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(sed -n 's/^version=//p' module.prop)
UPSTREAM=$(sed -n 's/^version=\([0-9.]*\).*/\1/p' module.prop)
OUT="dnscrypt-proxy-android-${VERSION}.zip"
ITEMS="module.prop customize.sh service.sh post-fs-data.sh uninstall.sh scripts config binary tools META-INF LICENSE.md README.md CHANGELOG.md"

if [ "${1:-}" = "--all" ]; then
  tmp=$(mktemp -d)
  for pair in arm:android-arm i386:android-i386 x86_64:android-x86_64; do
    name=${pair%%:*}; dir=${pair##*:}
    url="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${UPSTREAM}/dnscrypt-proxy-${dir/-/_}-${UPSTREAM}.zip"
    echo "качаю $name"
    curl -sL -o "$tmp/$name.zip" "$url"
    unzip -oq "$tmp/$name.zip" -d "$tmp"
    cp -f "$tmp/$dir/dnscrypt-proxy" "binary/dnscrypt-proxy-$name"
  done
  rm -rf "$tmp"
fi

rm -f "$OUT"
if command -v zip >/dev/null 2>&1; then
  zip -r9 "$OUT" $ITEMS -x '*.orig' '*.bak' >/dev/null
else
  # На Windows/Git Bash zip обычно отсутствует. Собираем питоном и обязательно
  # с прямыми слэшами внутри архива, иначе Magisk не разберёт пакет.
  OUT="$OUT" ITEMS="$ITEMS" python - <<'PYZIP'
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
fi
echo "готово: $OUT ($(du -h "$OUT" | cut -f1))"
