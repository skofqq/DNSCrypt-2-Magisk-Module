# DNSCrypt-Proxy 2 для Magisk

Системный шифрованный DNS для Android: DNSCrypt v2, DoH, Anonymized DNSCrypt, ODoH.
Весь DNS устройства заворачивается на локальный прокси, включая приложения,
которые ходят к своим резолверам мимо системных настроек.

Самостоятельный проект: скрипты модуля, супервизор, netfilter-слой, утилита
`dnscrypt-ctl` и приложение-менеджер написаны здесь. Вырос из заброшенного
[d3cim/dnscrypt-proxy-android](https://github.com/d3cim/dnscrypt-proxy-android) —
см. [Благодарности](#благодарности).

Проверялось на Magisk 30.x, Android 15–16, arm64.
Внутри dnscrypt-proxy 2.1.18 (июль 2026), включая PQDNSCrypt.

## Что входит

| | |
|---|---|
| Модуль Magisk | перехват DNS, супервизор процесса, восстановление правил после netd |
| `dnscrypt-ctl` | управление из шелла: состояние, настройки, серверы, журналы, конфликты |
| DNSCrypt Manager | приложение с графическим интерфейсом, APK лежит в [релизе](https://github.com/skofqq/DNSCrypt-2-Magisk-Module/releases/latest) |

## Установка

Собрать zip и прошить в Magisk → Modules → Install from storage:

```sh
./build.sh          # только arm64
./build.sh --all    # докачать arm, i386, x86_64
```

Либо взять готовый `dnscrypt-proxy-android-<версия>.zip` со страницы релизов.

## Приложение-менеджер

`DNSCryptManager-<версия>.apk` в том же релизе. Требует Android 12+ и root;
модуль не устанавливает и не собирает — работает через `dnscrypt-ctl`.

* состояние прокси, время работы, порт, наличие правил перехвата, режим IPv6;
* проверка резолвинга UDP-запросом на `127.0.0.1:<порт>` — без root, ровно так,
  как это видит обычное приложение;
* выбор резолверов из кэша `public-resolvers.md` с поиском и фильтрами
  по протоколу, DNSSEC, логированию и фильтрации;
* правка `module.conf` и `dnscrypt-proxy.toml` с резервными копиями и откатом;
* журналы модуля и прокси, вывод `rules` и `conflicts`;
* плитка в шторке для быстрого включения.

## Настройка

* Конфиг: `/data/adb/dnscrypt-proxy/dnscrypt-proxy.toml`
* Копия для правки файловым менеджером: `/storage/emulated/0/dnscrypt-proxy/`
  Более свежий файл выигрывает при синхронизации; вручную — `dnscrypt-ctl import`.
* Параметры модуля: `/data/adb/dnscrypt-proxy/module.conf`

| ключ | значения | смысл |
|---|---|---|
| `redirect_ipv4` | `true` / `false` | перехват IPv4 DNS, основной режим |
| `redirect_ipv6` | `auto` / `redirect` / `off` | `auto` перехватывает, только если ядро умеет `ip6tables nat` |
| `tether_redirect` | `true` / `false` | заворачивать DNS клиентов хотспота |
| `disable_private_dns` | `true` / `false` | системный Private DNS ходит по DoT мимо порта 53 |
| `mirror_config` | `true` / `false` | держать копию конфига на внутренней памяти |
| `restart_delay_max` | 5…600 секунд | потолок паузы между перезапусками упавшего прокси |
| `run_gid` | имя группы, GID или пусто | первичная группа процесса, нужна рядом с box_for_magisk |

По умолчанию `server_names` пуст — прокси сам выбирает серверы по фильтрам
`require_dnssec` / `require_nolog` / `require_nofilter`.

## Управление

```
dnscrypt-ctl status      # состояние, порт, наличие правил
dnscrypt-ctl json        # то же машиночитаемо
dnscrypt-ctl restart     # перечитать конфиг
dnscrypt-ctl log         # журнал модуля
dnscrypt-ctl proxylog    # журнал dnscrypt-proxy
dnscrypt-ctl rules       # цепочка DNSCRYPT
dnscrypt-ctl conflicts   # кто ещё перехватывает порт 53
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

Готовый блок для `/data/adb/box/clash/config.yaml`:

```yaml
dns:
  enable: true
  listen: 0.0.0.0:1053        # отсюда box берёт порт; строка должна быть одна
  ipv6: false
  enhanced-mode: fake-ip      # redir-host - если через dnscrypt должен идти весь DNS
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*.lan'
    - '*.local'
    - '+.pool.ntp.org'
    - 'time.*.com'
  default-nameserver:
    - 127.0.0.1:5354
  nameserver:
    - 127.0.0.1:5354
  proxy-server-nameserver:
    - 127.0.0.1:5354
  fallback: []
```

`fallback` обязательно пустой: иначе часть запросов уйдёт мимо dnscrypt-proxy напрямую.
`proxy-server-nameserver` тоже указывает на нас, иначе адреса прокси-серверов
резолвятся системным DNS и запрос возвращается в clash по кругу.

Что даёт `enhanced-mode`: при `fake-ip` через dnscrypt-proxy идут только direct-домены
и адреса прокси-серверов, а проксируемые домены резолвятся на выходной ноде.
При `redir-host` через него проходит весь DNS, но каждое соединение ждёт реального
резолва — заметно медленнее на первом обращении к домену.

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

## Что здесь переписано

Апстрим d3cim заброшен в феврале 2024 года. От него остались идея и структура
Magisk-модуля; ниже — что было исправлено и заменено своим кодом.

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
| Нечем управлять | правка файлов вручную | `dnscrypt-ctl` и приложение-менеджер |

## Благодарности

Проект стоит на чужой работе, и это стоит назвать поимённо.

* **[Frank Denis (jedisct1)](https://github.com/jedisct1)** и участники
  [DNSCrypt/dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy) — сам прокси,
  протокол DNSCrypt v2, Anonymized DNSCrypt и подписанные списки резолверов.
  Модуль лишь доставляет его на Android и включает в системный DNS-путь.
* **[d3cim](https://github.com/d3cim)** и
  [d3cim/dnscrypt-proxy-android](https://github.com/d3cim/dnscrypt-proxy-android) —
  исходный Magisk-модуль, с которого всё начиналось. Скрипты с тех пор переписаны,
  но структура пакета и первоначальная идея — оттуда.
* **[topjohnwu](https://github.com/topjohnwu)** —
  [Magisk](https://github.com/topjohnwu/Magisk), без которого модуля бы не было,
  и [libsu](https://github.com/topjohnwu/libsu), на которой держится root-слой
  приложения-менеджера.
* **[taamarin](https://github.com/taamarin)** и
  [box_for_magisk](https://github.com/taamarin/box_for_magisk) — по его исходникам
  разобрана схема совместного существования на порту 53.
* Команда **[magisk-zapret2](https://git.zapret.moe/zapretdiscordyoutube/magisk-zapret2)** —
  пресеты и код, по которым проверялось отсутствие конфликта в `mangle`.
* **[DNSCrypt community](https://github.com/DNSCrypt)** — публичный список резолверов
  `public-resolvers.md` и его подписи minisign.

## Лицензия

[GNU GPL v3](LICENSE.md), как и у апстрима. Конфигурационные файлы в `config/`
сохраняют [лицензию dnscrypt-proxy](config/LICENSE) (ISC).
