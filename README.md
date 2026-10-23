# Shieldy для Magisk (DNSCrypt Magisk Module)

[![Поддержать проект](https://img.shields.io/badge/%D0%9F%D0%BE%D0%B4%D0%B4%D0%B5%D1%80%D0%B6%D0%B0%D1%82%D1%8C-DonationAlerts-F57D07)](https://www.donationalerts.com/r/skofqq)

Поддержать разработку: [donationalerts.com/r/skofqq](https://www.donationalerts.com/r/skofqq)

Модуль Magisk, который переводит весь DNS-трафик Android на локальный
[dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy) и отправляет запросы
наружу в зашифрованном виде: DNSCrypt v2, DNS-over-HTTPS, Anonymized DNSCrypt, ODoH.

Перехват выполняется на уровне netfilter. Поэтому через прокси проходят и запросы
приложений, которые обращаются к собственным резолверам на порт 53 в обход
системных настроек DNS.

Состав пакета:

| Компонент | Назначение |
|---|---|
| модуль Magisk | установка dnscrypt-proxy 2.1.18, перехват DNS, супервизор процесса, восстановление правил после netd |
| `dnscrypt-ctl` | управление из командной строки: состояние, настройки, выбор и исключение серверов, журналы, диагностика |
| Shieldy | приложение для Android с графическим интерфейсом поверх `dnscrypt-ctl`, APK публикуется в [релизах](https://github.com/skofqq/DNSCrypt-2-Magisk-Module/releases/latest) |

## Требования

| | |
|---|---|
| Root | Magisk 20.4 и новее. Проверено на Magisk 30.x и 31.x. KernelSU и APatch не тестировались |
| Android | проверено на Android 15–16 |
| Архитектура | `arm64-v8a`, `armeabi-v7a`. Установщик выбирает бинарник по `$ARCH` устройства |
| Ядро | `iptables` с таблицей `nat`. `ip6tables nat` желателен, но не обязателен (см. [IPv6](#ipv6)) |
| Приложение | Android 12 и новее, root-доступ |

Один zip подходит для обеих архитектур.

## Установка

1. Скачать `dnscrypt-proxy-android-<версия>.zip` со [страницы релизов](https://github.com/skofqq/DNSCrypt-2-Magisk-Module/releases/latest).
2. Magisk → Модули → Установить из хранилища → выбрать zip.
3. Перезагрузить устройство.
4. Проверить работу: `su -c dnscrypt-ctl test`.

При обновлении существующий `dnscrypt-proxy.toml` сохраняется, новая версия
конфига кладётся рядом как `dnscrypt-proxy.toml.new`, прежняя копируется в `.bak`.
Обновления модуля приходят через Magisk (`updateJson` в `module.prop`).

### Сборка из исходников

```sh
./build.sh          # arm64 и arm: arm64 из репозитория, arm загружается с GitHub dnscrypt-proxy
./build.sh --arm64  # только arm64
```

Для упаковки используется `zip`. Если его нет, используются Python `zipfile`, `7z` или `jar` из JDK.
CI ([.github/workflows/build.yml](.github/workflows/build.yml)) проверяет скрипты
`shellcheck`, собирает zip, проверяет наличие бинарников arm64 и arm и при push тега
прикладывает zip к релизу.

## Файлы и каталоги

| Путь | Содержимое |
|---|---|
| `/data/adb/dnscrypt-proxy/dnscrypt-proxy.toml` | конфиг dnscrypt-proxy |
| `/data/adb/dnscrypt-proxy/module.conf` | параметры модуля |
| `/data/adb/dnscrypt-proxy/*.txt` | `blocked-names`, `blocked-ips`, `allowed-names`, `allowed-ips`, `exclude-ips` |
| `/data/adb/dnscrypt-proxy/public-resolvers.md` | кэш списка резолверов, загружается и проверяется подписью minisign самим dnscrypt-proxy |
| `/system/bin/dnscrypt-proxy`, `/system/bin/dnscrypt-ctl` | бинарники, монтируются Magisk |

Каталог имеет права `0700`. Во внутренней памяти (`/storage/emulated/0`) модуль ничего
не хранит, поэтому конфиг доступен до первой разблокировки после загрузки (FBE).

## Параметры модуля

`/data/adb/dnscrypt-proxy/module.conf`. Изменение: `dnscrypt-ctl set <ключ> <значение>`,
затем `dnscrypt-ctl restart`. Сброс всех параметров: `dnscrypt-ctl reset`.

| Ключ | Значения | По умолчанию | Назначение |
|---|---|---|---|
| `autostart` | `true` / `false` | `true` | запуск при загрузке. `false`: модуль остаётся установленным, при загрузке ничего не запускается |
| `redirect_ipv4` | `true` / `false` | `true` | перехват IPv4 DNS (порт 53) |
| `redirect_ipv6` | `auto` / `redirect` / `off` | `auto` | перехват IPv6 DNS, см. [IPv6](#ipv6) |
| `tether_redirect` | `true` / `false` | `false` | перехват DNS клиентов точки доступа и USB-модема (`PREROUTING`) |
| `disable_private_dns` | `true` / `false` | `true` | отключение системного Private DNS (DoT на порт 853 не перехватывается). Исходный режим восстанавливается при `stop` и удалении модуля |
| `restart_delay_max` | 5…600 | `60` | максимальная пауза между перезапусками упавшего прокси, секунды |
| `run_gid` | пусто, имя группы или GID | пусто | первичная группа процесса dnscrypt-proxy. Экспериментальный параметр, нужен только при цепочке с box_for_magisk |

Значения проверяются при `set`, недопустимые отклоняются.

Конфиг dnscrypt-proxy по умолчанию слушает `127.0.0.1:5354` и `[::1]:5354`.
Список `server_names` пуст, поэтому серверы выбираются автоматически по фильтрам
`require_dnssec`, `require_nolog`, `require_nofilter` (все `true`) со стратегией балансировки `p2`.

## Управление: dnscrypt-ctl

Требует root (`su -c dnscrypt-ctl …`).

```
dnscrypt-ctl status            # состояние процесса, порт, правила IPv4/IPv6, Private DNS
dnscrypt-ctl json              # то же в JSON (используется приложением)
dnscrypt-ctl start | stop | restart
dnscrypt-ctl test              # резолвит уникальное имя системным резолвером и проверяет счётчики DNAT
dnscrypt-ctl rules             # цепочки nat/DNSCRYPT для IPv4 и IPv6
dnscrypt-ctl conflicts         # другие перехватчики порта 53, процессы на порту прокси
dnscrypt-ctl log [N]           # журнал модуля
dnscrypt-ctl proxylog [N]      # журнал dnscrypt-proxy
dnscrypt-ctl set <ключ> <значение>
dnscrypt-ctl reset             # module.conf к значениям по умолчанию, с резервной копией

dnscrypt-ctl servers info      # кэш резолверов, количество, текущий выбор
dnscrypt-ctl servers list      # имена серверов из кэша
dnscrypt-ctl servers relays    # релеи Anonymized DNSCrypt
dnscrypt-ctl servers get       # server_names или auto
dnscrypt-ctl servers set a,b   # задать server_names
dnscrypt-ctl servers add|remove <имя>
dnscrypt-ctl servers auto      # очистить server_names, выбор по фильтрам require_*
dnscrypt-ctl servers active    # серверы, выбранные прокси в данный момент
dnscrypt-ctl servers live      # JSON: стратегия, число живых серверов, RTT каждого
dnscrypt-ctl servers excluded [list]   # disabled_server_names
dnscrypt-ctl servers exclude|include a,b
```

`stop` сохраняется между перезагрузками: остановленный вручную прокси не запускается
при загрузке и при `restart` до следующего `start`. Перед каждой записью в
`dnscrypt-proxy.toml` создаётся резервная копия. Изменения конфига применяются после `restart`.

## Как это работает

* `post-fs-data.sh` подготавливает `/data/adb/dnscrypt-proxy`. Сеть на этом этапе не затрагивается.
* `service.sh` запускает `scripts/supervisor.sh`, если `autostart=true` и нет флага ручной остановки.
* Супервизор:
  * дожидается готовности iptables;
  * включает `route_localnet`;
  * строит цепочку `nat/DNSCRYPT`: исключения, затем DNAT `udp/tcp :53` на `127.0.0.1:5354`;
  * подключает цепочку к `OUTPUT` и запускает dnscrypt-proxy;
  * перезапускает упавший прокси с экспоненциальной паузой (5 с … `restart_delay_max`);
  * каждые 30 с проверяет, что правила на месте. Если netd их удалил, правила восстанавливаются.
* Из перехвата исключаются адреса `bootstrap_resolvers`, `netprobe_address` и `exclude-ips.txt`,
  иначе прокси перехватывал бы собственные запросы. Приложение, которое само отправляет DNS
  на эти адреса (по умолчанию 9.9.9.9, 1.1.1.1, 8.8.8.8), проходит мимо прокси.
  Если это критично, в `bootstrap_resolvers` следует указать адреса, которые приложения не используют.
* Private DNS отключается после `sys.boot_completed`, исходный режим сохраняется.
* Раздача Wi-Fi не затрагивается: IPv6 глобально не отключается, `FORWARD` не изменяется,
  `PREROUTING` используется только при `tether_redirect=true`.

### IPv6

| Ядро | `auto` | `redirect` | `off` |
|---|---|---|---|
| есть `ip6tables nat` | DNAT на `[::1]:5354` | DNAT на `[::1]:5354` | IPv6 DNS идёт мимо прокси |
| нет `ip6tables nat` | REJECT DNS на IPv6-адреса в `filter/OUTPUT`, пока есть IPv4-маршрут | REJECT всегда | IPv6 DNS идёт мимо прокси |

Резолвер Android после REJECT переходит на IPv4 DNS, который перехватывается.
В сети только с IPv6 режим `auto` снимает блокировку, чтобы DNS не пропал полностью.
Текущее состояние: строка `IPv6 DNS` в `status`, поле `ipv6_dns` в `json`
(`redirected` / `blocked` / `bypass`).

## Совместимость с другими модулями

`dnscrypt-ctl conflicts` показывает фактическое состояние на устройстве.

### box_for_magisk

[box_for_magisk](https://github.com/taamarin/box_for_magisk) тоже перехватывает DNS:
с ядром clash через `nat/CLASH_DNS_LOCAL` (порт 1053), с остальными ядрами через TPROXY в `mangle`.
Два перехватчика порта 53 одновременно не работают. Поддерживаются две схемы.

**Переключение.** Оба модуля включены в Magisk, активен один из них. Переключение
выполняется кнопками Start/Stop в приложениях (Shieldy и Box) или командами
`dnscrypt-ctl stop` / `start`. Остановка dnscrypt-proxy снимает правила, восстанавливает
Private DNS и сохраняется после перезагрузки. Box в режиме tproxy не забирает
порт 53 (`BOX_LOCAL` возвращает его), такая конфигурация распознаётся `conflicts` и полем `box_dns`.

Собственный dnscrypt-proxy в составе Box тоже может слушать порт 5354. Модуль
отслеживает свой процесс по пути бинарника, а не по имени, поэтому процессы не путаются.
Занятый порт отображается в `status` и `conflicts`.

**Цепочка.** DNS перехватывает box, dnscrypt-proxy работает как его вышестоящий резолвер:

```sh
dnscrypt-ctl set redirect_ipv4 false
dnscrypt-ctl set redirect_ipv6 off
dnscrypt-ctl set run_gid net_admin
dnscrypt-ctl restart
```

Блок для `/data/adb/box/clash/config.yaml`:

```yaml
dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip      # redir-host, если через dnscrypt-proxy должен идти весь DNS
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter: ['*.lan', '*.local', '+.pool.ntp.org', 'time.*.com']
  default-nameserver: [127.0.0.1:5354]
  nameserver: [127.0.0.1:5354]
  proxy-server-nameserver: [127.0.0.1:5354]
  fallback: []
```

* `fallback` должен быть пустым, иначе часть запросов уходит напрямую.
* `proxy-server-nameserver` указывает на dnscrypt-proxy, иначе адреса прокси-серверов
  резолвятся системным DNS и запрос возвращается в clash по кругу.
* `run_gid=net_admin` выводит запросы dnscrypt-proxy к резолверам из-под перехвата box:
  box пропускает трафик владельца `root:net_admin`.
* При `fake-ip` через dnscrypt-proxy идут direct-домены и адреса прокси-серверов.
* При `redir-host` через dnscrypt-proxy идёт весь DNS ценой задержки первого соединения.

### Boxy

[Boxy](https://github.com/skofqq/Boxy) — приложение для управления Box for Root
(`/data/adb/box`) с собственной сборкой модуля. Совместимость проверена на устройстве
с включёнными в Magisk обоими модулями.

* **Переключение.** DNS-перехват включается кнопкой Start в одном приложении после Stop в другом:
  Stop в Boxy и Start в Shieldy, или наоборот. Остановка в Shieldy сохраняется после перезагрузки.
  Чтобы после перезагрузки не запускался Box, в Boxy выключается «Запуск при загрузке»
  (файл `/data/adb/box/manual`).
* **Встроенный DNSCrypt Boxy** (Tools → DNS) запускает отдельный dnscrypt-proxy из
  `/data/adb/box/bin` с конфигом `/data/adb/box/dnscrypt` в роли вышестоящего DNS ядра.
  Он может слушать тот же порт 5354, что и этот модуль. Одновременно должен работать
  только один из них: занятый порт показывают `dnscrypt-ctl status` и `conflicts`.
  Процессы не путаются, модуль отслеживает свой dnscrypt-proxy по пути бинарника.
* **Цепочка** (Box перехватывает DNS, этот модуль шифрует) настраивается так же, как для
  box_for_magisk выше. Встроенный DNSCrypt Boxy при этом выключается.
* В режиме tproxy Box без перехвата DNS не забирает порт 53 (`BOX_LOCAL` возвращает его),
  и `conflicts` не считает его конкурентом. Если в Boxy включён DNS hijack, `conflicts`
  и поле `box_dns` в `json` показывают, что DNS забирает Box.

### magisk-zapret2

[magisk-zapret2](https://git.zapret.moe/zapretdiscordyoutube/magisk-zapret2) совместим.
Он работает в таблице `mangle` (`ZAPRET2_OUT` / `ZAPRET2_IN`, `NFQUEUE`) и в пресетах
не фильтрует порт 53. Если DNSCrypt-сервер слушает UDP-порт из диапазона `443-65535`,
пакеты прокси проходят через NFQUEUE без десинхронизации: `--dpi-desync-any-protocol`
в пресетах не включён.

## Shieldy (ранее DNSCrypt Manager)

Приложение `Shieldy-<версия>.apk` из релиза, пакет `com.skofqq.shieldy`. Управляет модулем через
`dnscrypt-ctl` и не устанавливает модуль самостоятельно.

При первом запуске Shieldy переносит настройки из DNSCrypt Manager (`io.github.skofqq.dnscryptmanager`),
если тот установлен; после переноса старое приложение можно удалить. Magisk запрашивает root для нового пакета.

* **Статус:**
  * состояние прокси и время работы, кнопки Start/Stop;
  * проверка DNS: какие резолверы видит внешний сервис, есть ли утечка;
  * текущий сервер и RTT;
  * версия модуля и проверка обновлений;
  * предупреждения при отсутствии правил перехвата, утечке по IPv6 или включённом Private DNS.
* **Серверы:**
  * выбор из `public-resolvers.md` с поиском и фильтрами по протоколу, DNSSEC, логированию и фильтрации;
  * исключение серверов по стране. Страна определяется по описанию сервера и базе GeoIP, для неопределённых её можно указать вручную.
* **Блокировка:**
  * подключаемые блок-листы (HaGeZi, OISD, произвольный URL) с ежедневным обновлением;
  * блокировка и разрешение доменов из журнала.
* **Настройки:**
  * все параметры `module.conf`, применяются с перезапуском только если прокси запущен;
  * редактор `dnscrypt-proxy.toml` с резервными копиями;
  * обновление модуля из релиза.
* **Журналы:** журналы модуля и прокси, правила, конфликты, режим Live.
* **Интерфейс:** 12 языков (en, ru, uk, be, kk, es, fr, it, pt, de, pl, tr), масштаб интерфейса 80–120%, плитка быстрых настроек.

## Изменения относительно исходного модуля

Модуль основан на заброшенном в 2024 году [d3cim/dnscrypt-proxy-android](https://github.com/d3cim/dnscrypt-proxy-android).
Скрипты переписаны:

| Проблема исходного модуля | Решение |
|---|---|
| упавший прокси перезапускался без пауз и разряжал батарею | супервизор с экспоненциальной паузой и журналом |
| конфиг на `/storage/emulated/0` недоступен до разблокировки (FBE) | всё хранится в `/data/adb/dnscrypt-proxy` |
| глобальное отключение IPv6 ломало раздачу Wi-Fi ([#7](https://github.com/d3cim/dnscrypt-proxy-android/issues/7)) | IPv6 не отключается, правила ставятся в `late_start` и восстанавливаются после netd |
| файлы оставались после удаления ([#1](https://github.com/d3cim/dnscrypt-proxy-android/issues/1)) | удаление снимает правила, останавливает процесс, восстанавливает Private DNS |
| из перехвата исключался один фиксированный IP | исключения из `bootstrap_resolvers`, `netprobe_address`, `exclude-ips.txt` |
| DNAT на 127.0.0.1 не работал без `route_localnet` | `route_localnet=1` с восстановлением при удалении |
| дубликаты правил при каждом запуске | отдельная цепочка `nat/DNSCRYPT`, проверка `-C` перед вставкой |
| dnscrypt-proxy 2.1.5 (2023) | 2.1.18, включая PQDNSCrypt |

История версий: [CHANGELOG.md](CHANGELOG.md).

## Благодарности

* [Frank Denis (jedisct1)](https://github.com/jedisct1) и участники [DNSCrypt/dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy): прокси, протокол DNSCrypt v2, Anonymized DNSCrypt.
* [DNSCrypt](https://github.com/DNSCrypt): список резолверов `public-resolvers.md` и его подписи minisign.
* [d3cim/dnscrypt-proxy-android](https://github.com/d3cim/dnscrypt-proxy-android): исходная структура Magisk-модуля.
* [topjohnwu](https://github.com/topjohnwu): [Magisk](https://github.com/topjohnwu/Magisk) и [libsu](https://github.com/topjohnwu/libsu).
* [taamarin/box_for_magisk](https://github.com/taamarin/box_for_magisk), [Boxy](https://github.com/skofqq/Boxy) и [magisk-zapret2](https://git.zapret.moe/zapretdiscordyoutube/magisk-zapret2): исходники, по которым проверялась совместимость.
* [DB-IP](https://db-ip.com): база IP to Country Lite (CC BY 4.0), используется приложением.

## Лицензия

[GNU GPL v3](LICENSE.md). Файлы в `config/` распространяются под [лицензией dnscrypt-proxy](config/LICENSE) (ISC).
