# dnscrypt-proxy-android (форк с исправлениями)

Magisk-модуль системного шифрованного DNS: DNSCrypt v2, DoH, Anonymized DNSCrypt, ODoH.
Форк [d3cim/dnscrypt-proxy-android](https://github.com/d3cim/dnscrypt-proxy-android),
заброшенного в феврале 2024 года, с обновлённым `dnscrypt-proxy` и починенными скриптами.

Проверялось на Magisk 30.x / Android 15-16, arm64.

## Что исправлено относительно апстрима

| Проблема | Что было | Что стало |
|---|---|---|
| Разряд батареи | `while ! [ \`pgrep -x dnscrypt-proxy\` ]` c `&& sleep 15`: пауза срабатывала только при выходе с кодом 0, упавший прокси перезапускался без пауз | `scripts/supervisor.sh` с экспоненциальной паузой 5→60 с, журналом и сбросом задержки после 2 минут работы |
| Не стартует до разблокировки | конфиг лежал на `/storage/emulated/0`, недоступном при FBE | рабочий конфиг в `/data/adb/dnscrypt-proxy`, копия для правки — на внутренней памяти |
| Ломалась раздача Wi-Fi ([#7](https://github.com/d3cim/dnscrypt-proxy-android/issues/7)) | глобальное отключение IPv6 через `resetprop` + правила в `post-fs-data`, до старта netd | IPv6 не трогаем, правила ставятся в `late_start` и переставляются, если netd их снёс |
| Мусор после удаления ([#1](https://github.com/d3cim/dnscrypt-proxy-android/issues/1)) | `while [ boot != 1 ] && [ ! -d ... ]` — выход по любому из условий, `rm` по несмонтированным путям | корректное ожидание, снятие правил, остановка процесса, резервная копия конфига |
| Петля/обрыв DNS при смене резолвера | из перехвата исключался один захардкоженный IP | исключения собираются из `bootstrap_resolvers`, `netprobe_address` и `exclude-ips.txt` |
| DNAT молча не работал | не выставлялся `route_localnet` | `net.ipv4.conf.*.route_localnet=1` с восстановлением при удалении |
| Дубликаты правил | `iptables -A` при каждом запуске | своя цепочка `nat/DNSCRYPT`, проверка `-C` перед вставкой |
| Устаревший прокси | dnscrypt-proxy 2.1.5 (август 2023) | 2.1.18 (июль 2026), включая PQDNSCrypt |

## Установка

Собрать zip и прошить в Magisk → Modules → Install from storage:

```sh
./build.sh          # только arm64
./build.sh --all    # докачать arm, i386, x86_64
```

## Настройка

* Конфиг: `/data/adb/dnscrypt-proxy/dnscrypt-proxy.toml`
* Копия для правки файловым менеджером: `/storage/emulated/0/dnscrypt-proxy/`
  Более свежий файл выигрывает при синхронизации; вручную — `dnscrypt-ctl import`.
* Параметры модуля: `/data/adb/dnscrypt-proxy/module.conf`
  (перехват IPv4/IPv6, режим тизеринга, Private DNS, зеркало конфига, потолок паузы).

По умолчанию `server_names` пуст — прокси сам выбирает серверы по фильтрам
`require_dnssec` / `require_nolog` / `require_nofilter`. Прежний список форка
оставлен в конфиге комментарием.

## Управление

```
dnscrypt-ctl status      # состояние, порт, наличие правил
dnscrypt-ctl json        # то же машиночитаемо
dnscrypt-ctl restart     # перечитать конфиг
dnscrypt-ctl log         # журнал модуля
dnscrypt-ctl proxylog    # журнал dnscrypt-proxy
dnscrypt-ctl rules       # цепочка DNSCRYPT
dnscrypt-ctl set redirect_ipv6 off

dnscrypt-ctl servers info      # где кэш резолверов, сколько их, что выбрано
dnscrypt-ctl servers list      # имена всех серверов из кэша
dnscrypt-ctl servers get       # текущий выбор или auto
dnscrypt-ctl servers set a,b   # задать список
dnscrypt-ctl servers add имя   # добавить один
dnscrypt-ctl servers remove имя
dnscrypt-ctl servers auto      # вернуть автоподбор по фильтрам require_*
dnscrypt-ctl servers active    # какой сервер выбран прокси сейчас
```

Список резолверов качает и проверяет подписью minisign сам dnscrypt-proxy;
`servers` только читает этот кэш (`public-resolvers.md`) и правит `server_names`
в конфиге, каждый раз делая резервную копию. Изменения применяются после `restart`.

## Совместимость с другими модулями

Проверено по исходникам: `dnscrypt-ctl conflicts` покажет картину на конкретном устройстве.

**[magisk-zapret2](https://git.zapret.moe/zapretdiscordyoutube/magisk-zapret2) — совместим.**
Он работает в таблице `mangle` (цепочки `ZAPRET2_OUT`/`ZAPRET2_IN`, действие `NFQUEUE`),
а мы — в `nat`. Пересечений по портам нет: ни один из 98 пресетов не фильтрует 53,
только TCP 80/443 и UDP из верхних диапазонов. Единственное касание — если DNSCrypt-сервер
слушает UDP-порт из диапазона `443-65535`, трафик прокси пройдёт через NFQUEUE;
десинхронизации он не подвергнется, потому что `--dpi-desync-any-protocol` не включён
ни в одном пресете, а на DNSCrypt-пакетах сигнатуры TLS/QUIC не срабатывают.

**[box_for_magisk](https://github.com/taamarin/box_for_magisk) — конфликтует за порт 53.**
С ядром clash он ставит `-I OUTPUT -j CLASH_DNS_LOCAL` в `nat` и заворачивает `udp:53`
на свой порт 1053; с другими ядрами забирает 53 в `mangle` через TPROXY. Стартует он
после загрузочной анимации, то есть позже нас, а `-I` вставляет правило в начало цепочки —
значит DNS достаётся ему, а наш перехват простаивает. Два перехватчика одновременно
держать нельзя. Рабочая схема — отдать перехват box, а нас сделать его резолвером:

```sh
dnscrypt-ctl set redirect_ipv4 false
dnscrypt-ctl set redirect_ipv6 off
dnscrypt-ctl set run_gid net_admin
dnscrypt-ctl restart
```

и в конфиге clash/sing-box указать сервером `127.0.0.1:5354`. Тогда системный DNS
забирает box, а шифрует его наш прокси.

`run_gid=net_admin` нужен потому, что box пропускает мимо своего перехвата трафик
с владельцем `root:net_admin` — иначе запросы самого dnscrypt-proxy к резолверам
пойдут через прокси box и сломаются, если тот не умеет UDP.

При `ipv6="false"` box добавляет `ip6tables -A OUTPUT -p udp --dport 53 -j DROP`,
так что перехват IPv6 с его стороны всё равно не нужен.

## Как это работает

`post-fs-data.sh` только готовит `/data/adb/dnscrypt-proxy`. Сеть трогает
`service.sh` → `scripts/supervisor.sh`: дожидается iptables, строит цепочку
`nat/DNSCRYPT` (исключения → DNAT :53 на `127.0.0.1:5354`), привязывает её к
`OUTPUT`, запускает прокси и следит за ним, раз в 30 с проверяя, что правила на месте.
Private DNS выключается после `sys.boot_completed` — в recovery `settings` недоступен.
