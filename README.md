# shieldnode

**DDoS-защита для VPN-нод на уровне ядра.** Один bash-скрипт: `nftables` + `SYNPROXY` + `CrowdSec` + адаптивный conntrack-guard.

Целевые ОС: **Ubuntu 22.04 / 24.04, Debian 12 / 13**. Совместим с любым VPN-стеком (Xray Reality, sing-box, Hysteria2, WireGuard, AmneziaWG) и с UFW. Терминируется отдельно — shieldnode только фильтрует трафик на L3/L4.

---

## Быстрый старт

```bash
curl -fL https://raw.githubusercontent.com/SpofyJet/shield/main/shieldnode.sh | sudo bash
```

> Используй `curl | sudo bash`, **не** `bash <(curl ...)` — process substitution не работает в OpenVZ/LXC.

После установки всё управление — через `sudo guard`.

---

## Что делает

shieldnode закрывает **L3/L4**: режет SYN / UDP / connection-флуд на уровне ядра, защищает conntrack-таблицу от исчерпания (SYNPROXY + conntrack-guard), банит сканеры и известные угрозы по блоклистам, держит SSH под pre-auth rate-limit и переживает **распределённый connect-and-hold флуд** (см. ниже).

Kernel-tuning (BBR, qdisc, сетевые буферы, sizing conntrack) — **не** зона shieldnode, это задача парного скрипта `vpn-node-setup`. shieldnode пишет только свои security-sysctl в `/etc/sysctl.d/90-shieldnode.conf` (rp_filter, syncookies, rfc1337, redirects off, ICMP hardening, UDP/TCP conntrack timeouts). Префикс `90-` позволяет перекрыть значения через `99-*.conf`.

**Чего L3/L4 НЕ закрывает:** перегрузку самого приложения и адаптивный флуд с «живыми» сокетами. Это потолок пакетного фильтра — параллельно ставь лимиты коннектов в xray/remnawave (per-inbound).

---

## Архитектура

Защита идёт слоями в таблице `inet ddos_protect` (hook prerouting):

1. **ct established** — установленные соединения пропускаются сразу.
2. **whitelist** — `manual_whitelist` (mgmt-IP из UFW авто-синком) + `remnawave_nodes` (IP нод флота, авто из панели — см. fleet-sync) + инфраструктура (~220 CIDR CDN/edge: Cloudflare, Google, Akamai, Fastly, Apple, Meta, GitHub, Telegram, Yandex). Whitelist стоит **первым** — админ, mgmt-IP и ноды флота не блокируются ничем.
3. **anti-spoof** — fib reverse-path (single-homed VPS).
4. **TCP flag sanity** — drop XMAS / NULL / SYN+FIN / SYN+RST.
5. **blocklists** — scanner / threat / tor / custom → drop.
6. **SSH pre-auth** — ct=5 + 8/min, ещё до того как пакет дойдёт до sshd.
7. **rate-limits** — conn-flood / newconn / syn / udp с архитектурой **ban-once**. v3.27: при `SHIELD_CGNAT_SAFE=1` (дефолт) превышение per-IP лимита режет только избыточные пакеты (rate-shape) + лог, но **не** эскалирует общий CGNAT-IP в 15-мин blackhole. Опц. глобальный backstop new-conn/с (`SHIELD_GLOBAL_NEWCONN_CEIL`, дефолт off — для не-CGNAT нод против распределённого handshake-флуда).

Изолированно, в **отдельных** nft-таблицах (не трогают `ddos_protect`, откат = удаление таблицы):

- `inet shield_synproxy` — SYNPROXY (защита от conntrack-exhaustion).
- `inet shield_ctguard` — adaptive conntrack-guard + phantom-эвикт (защита от connect-and-hold).

Приоритеты hook'ов согласованы: CrowdSec-bouncer `-200` → ctguard `-160/-159` → ddos_protect `-150/-100`. SYNPROXY перехватывает SYN ещё раньше (`-300`).

---

## conntrack-guard / phantom-защита (v3.26, уточнено в v3.27)

**Проблема — распределённый connect-and-hold флуд.** Сотни IP открывают тысячи TCP-соединений, проходят handshake и **бросают** их. Записи висят в conntrack, приложение (xray) захлёбывается — при этом conntrack-таблица может быть заполнена лишь на 7–20%, так что классический «fill ≥90%» триггер молчит. Per-IP-порог тоже бесполезен: пик атаки (~1800–2300 conn/IP) **пересекается** с легит-CGNAT-потолком (~2200 conn/IP) — счётчиком не разделить.

**Решение — детект по ЖИВЫМ сокетам (`shieldnode-ctguard`):**

- **Признак фантома:** у источника `conntrack ≫ живых сокетов (ss)`. Атакер бросил соединение → живых сокетов 0; легит держит трафик → `live ≈ conntrack`. Это `acct`-free (не зависит от `nf_conntrack_acct`).
- **Триггер attack-mode (v3.26.4):** `ss-phantom-ratio` (доля conntrack без живого сокета) — это *сигнал*, но attack-mode по фантому входит **только при наличии реального per-source холдера** (источник с conntrack ≥ `SHIELD_CTG_PHANTOM_MIN` и почти нулём живых). Отдельно — EWMA-отклонение new-conn/conntrack и fill-триггер (настоящий L4-флуд). **Важно:** на мобильных/CGNAT-нодах высокий phantom-ratio бывает и у ЛЕГИТА — клиенты бросают конны быстрее, чем `est_to=1800` их реапит, и conntrack≫live у легита тоже. Поэтому ratio сам по себе НЕ объявляет атаку — нужен концентрированный холдер.
- **Ответ:** эвикт источников-фантомов (nft-блок + `conntrack -D`, опц. CrowdSec-бан). Агрегатный кап new-conn на защищаемые порты — **opt-in** через `SHIELD_CTG_AGG_CAP` (0=прямые ноды: эвикт сам справляется, кап на CGNAT-пиках вреден; 1=CDN/мост-ноды, где per-IP-эвикт невозможен). Настоящий rate/fill-флуд капается всегда.
- **CGNAT-safe by design:** эвикт щадит источник при любом из условий — живых сокетов > порога (shared-front/CGNAT), live-доля выше порога, conntrack < `PHANTOM_MIN` (=4000 по умолчанию, выше легит-CGNAT-churn ~2200), или IP в whitelist. Чистый мобильный churn (нет холдера) в attack-mode **не входит вообще** — ни эвикта, ни капа, ни спама.
- **sysctl:** `nf_conntrack_tcp_timeout_established=1800` (брошенные фантомы дохнут за 30 мин вместо 5 суток; живые сессии с keepalive переживают).
- **Производительность:** дешёвый коарс-гейт — дорогой полный дамп `conntrack -L` запускается только если `conntrack ≫ ss_total` (фантом-тяжело) или мы уже в attack-mode. Здоровая busy-нода не платит за дамп каждый тик.
- **Уточнения v3.27:** глобальный кап входит по **скользящему окну** аномалий (`SHIELD_CTG_ANOM_WINDOW`) — атака «вкл/выкл» (pulsing) от капа не уходит, а одиночный легит-всплеск кап НЕ включает. Против **распределённого** connect-and-hold (много IP по чуть-чуть) добавлен 2-й проход эвикта с порогом ниже, но строго при `live==0` (CGNAT с активными юзерами щадится), только в sustained-attack. EWMA не обучается во время аномалии (анти-poison базлайна).

**Раскат — observe → enforce.** По умолчанию `SHIELD_CTG_ENFORCE=1`, но для осторожного ввода на новой ноде поставь `0` (только лог), убедись по `journalctl -t shieldnode-ctguard`, что в кандидатах только атакеры (live=0), затем включи:

```bash
sudo sed -i 's/^SHIELD_CTG_ENFORCE=.*/SHIELD_CTG_ENFORCE=0/' /etc/shieldnode/shieldnode.conf
# наблюдаешь журнал… кандидаты = только атакеры? тогда:
sudo sed -i 's/^SHIELD_CTG_ENFORCE=0/SHIELD_CTG_ENFORCE=1/' /etc/shieldnode/shieldnode.conf
sudo systemctl restart shieldnode-ctguard
```

---

## SYNPROXY

Когда флуд незавершённых SYN забивает conntrack — нода превращается в чёрную дыру (`nf_conntrack: table full`). SYNPROXY это закрывает: SYN перехватывается **до** conntrack, проходит syncookie-хендшейк, запись создаётся только после полного 3-way.

- Модуль `shieldnode-synproxy.sh`, таблица `inet shield_synproxy`. Включён по умолчанию (`SHIELD_SYNPROXY=1`).
- Безопасно: ядро не поддерживает → авто-fallback на `ddos_protect`; на стоковых ядрах авто-доустановка `linux-modules-extra-$(uname -r)` (на XanMod встроен); verify mss/wscale живого бэкенда + авто-откат при несовпадении. При неудаче включения — **fail-loud** (v3.27.0): маркер `/var/lib/shieldnode/.synproxy-degraded` + ALERT в install/journald + индикатор `DEGRADED` в `guard` (молча на слабую защиту не падаем).
- **Покрывает и SSH-порт** (v3.27.1, `SHIELD_SYNPROXY_SSH=1`): спуф-SYN на SSH иначе тёк бы conntrack (SSH не в protected-портах → не под synproxy/ctguard-капом). Прозрачно для легит-хендшейков, established SSH не рвётся. Выключить: `SHIELD_SYNPROXY_SSH=0`.
- Требует ядро **≥5.14** + модуль `nf_synproxy`. Переживает ребут. Выключить: `SHIELD_SYNPROXY=0` или `sudo shieldnode-synproxy.sh off`.
- Порты синхронятся с фаерволом (ports-watcher держит `sp_ports` в актуальном состоянии, SSH-порт сохраняется при смене портов).

---

## Лимиты

Рассчитаны на ноду с **500–1000 VPN-клиентами**. Тюнятся в `/etc/shieldnode/limits.conf`.

| Параметр              | Значение               | Обоснование                                  |
| --------------------- | ---------------------- | -------------------------------------------- |
| conn-flood (per-IP)   | ct > 15000             | высокий backstop; точность отдана phantom-слою |
| newconn               | 40000/min, burst 60000 | масс-reconnect 200 юзеров × 50 retry          |
| SYN                   | 2000/sec, burst 3000   | CGNAT 200 юзеров × 1–2 SYN/sec                |
| UDP                   | 10000/sec, burst 20000 | Hysteria2/QUIC 4K + cloud gaming              |
| SSH (per-IP)          | ct=5 + 8/min           | CGNAT-админ + ansible на ≤5 нод               |

Реальные атаки (50k+ SYN/sec, 100k+ соединений) дропаются на уровне ядра. Архитектура **ban-once**: первое нарушение → `suspect` (30 мин наблюдения, без drop), второе → `confirmed` (15 мин drop). Снижает ложные баны CGNAT/мобильных.

> Per-IP `conn-flood` намеренно высокий (15000) — он лишь грубый backstop для одиночных экстремальных холдеров. Распределённый флуд ловит liveness-aware ctguard, а не per-IP-порог.

---

## Блоклисты

- **scanner** — Shodan / Censys / госсканеры РФ.
- **threat** — Spamhaus DROP (JSON `drop_v4.json` + `drop_v6.json`) + FireHOL Level 1 (high-confidence, bogon-фильтр: v4 min /16, v6 min /29). *Feodotracker убран в v3.27.2* — датасет abuse.ch сейчас пуст + введён обязательный `Auth-Key` (с 30.06.2025) + миграция под Spamhaus → отдавал ~0 IP и ломался бы на 401.
- **tor** — Tor exit nodes (опционально, `BLOCK_TOR=1`).
- **custom** — личный список оператора.

**IPv6-блоклисты (v3.27.0+):** у каждого набора есть v6-параллель (`scanner_blocklist_v6`, `threat_blocklist_v6`, `custom_blocklist_v6`, `tor_exit_blocklist_v6`). Апдейтер парсит v6-CIDR из тех же фидов (префикс-флор + bogon/ULA/link-local/multicast/doc-фильтр + структурная валидация), применяет **отдельной nft-транзакцией** (битый v6 не ломает v4) и только если v6-сет существует (backward-compat). Spamhaus `drop_v6.json` реально наполняет `threat_blocklist_v6`. v6 drop-правила активны, только если на ноде есть публичный IPv6 (см. «IPv6» ниже).

**custom** собирается из трёх источников: `lists/custom.txt` (синк с GitHub каждые 6 ч) + `custom-local.txt` (локальные дополнения, не перезаписываются) + auto-promote.

**Auto-promote:** IP с count ≥ 800 за 24 ч (conn/syn/udp-escalate) попадает в `custom-local.txt` навсегда. TTL 90 дней — запись удаляется, если IP не атакует > 30 дней. Перед каждым промоутом — cross-check с CrowdSec whitelist.

---

## IPv6

v6-защита **включается автоматически**, если при установке найден публичный IPv6 (`ip -6 addr show scope global`). Когда включена:

- established v6 пропускается; **v6-блоклисты** (threat/scanner/tor/custom `_v6`) → drop — раньше остального (бьют и SSH-over-v6);
- новые v6-конны на VPN-порты → **DROP** (клиенты идут по v4/CGNAT). Опц. `SHIELD_V6_REJECT=1` → **RST** вместо тихого drop → мгновенный happy-eyeballs fallback на v4 без SYN-timeout;
- SSH-over-v6 под тем же pre-auth rate-limit, что и v4.

Это **базовая защита (P0-1)**: покрывает VPN-порты, SSH и блоклисты, но **не** произвольные порты / ICMPv6 / общий conntrack — полноценный v6 rate-limit в планах.

> **Важно для «v4-only» нод.** conntrack-таблица **общая для v4 и v6**. Многие провайдеры авто-выдают публичный IPv6, даже если ты «пользуешься только v4» — тогда хост достижим по v6, и v6-флуд грузит **общие** conntrack/CPU/канал (деградация v4 через общий лимит). Базовая v6-защита это не закрывает полностью. Хочешь честно v4-only — **выключи v6 в ядре** (`net.ipv6.conf.all.disable_ipv6=1` + `default.disable_ipv6=1`) или дропай весь v6 на edge. Сначала проверь: `ip -6 addr show scope global`. Детект v6 — в момент install (v6, добавленный позже, не увидится до reinstall).

---

## PCAP-форензика

Always-on rolling capture (SYN-only, 128 байт/пакет) — нумерованный ring-buffer на 1 GB в `/var/log/pcap/`. При скачке > 10k drops/min текущий ring архивируется в `/var/lib/shieldnode/pcap-archive/attack-<TS>/`. Последние ~1 GB трафика всегда на диске — есть что отправить хостеру при DDoS, в том числе по атакам, не задевшим пороги.

---

## CrowdSec

SSH brute-force + community blocklist (~28k IP, stream mode), nftables-bouncer на prerouting (`priority -200`, раньше всех слоёв shieldnode). `TRUSTED_IPS` применяются на parser-level (postoverflow whitelist) — trusted-IP не банятся даже сценариями; поддерживается CIDR. Чужой (foreign) CrowdSec корректно детектится и не патчится.

---

## Remnawave fleet auto-sync (v3.28.0)

Боль ручного whitelist'а: завёл новую ноду — иди обнови `TRUSTED_IPS` на **каждой** ноде флота. Fleet-sync это автоматизирует — даёшь токен панели, и каждая нода в фоне сама узнаёт IP всех остальных нод и держит их в whitelist:

```bash
# при установке (или через guard upgrade)
REMNAWAVE_URL="https://panel.example.com" REMNAWAVE_TOKEN="ey..." \
  curl -fL https://raw.githubusercontent.com/SpofyJet/shield/main/shieldnode.sh | sudo bash
```

Токен — из панели: **Remnawave Settings → API Tokens**.

> **v3.28.1:** на свежей ноде можно вообще ничего не передавать в env — установка **сама спросит**: токен Remnawave (1), вручную IP бриджей (2) или пропустить (3). В `curl|bash` ввод идёт с терминала, токен скрыт. Если нода уже настроена — не переспрашивает. Отключить интерактив: `SHIELD_WL_PROMPT=0`.

Как работает:

- systemd-таймер (дефолт каждые 5 мин) дёргает `GET {URL}/api/nodes` по `Authorization: Bearer`, берёт `address` каждой ноды (IP или домен → резолв через `getent`), валидирует и кладёт в nft-сеты `remnawave_nodes_v4/v6`.
- Эти сеты accept'ятся **сразу после `manual_whitelist`** — ноды флота обходят все лимиты (это свои серверы, не CGNAT → безопасно). По сути авто-версия `TRUSTED_IPS` для нод.
- Новую ноду добавил в панель → все ноды подхватят её на следующем тике. Удалил — уйдёт из whitelist.
- **Fail-safe:** панель недоступна, кривой ответ или 0 валидных IP → текущий whitelist нод **не трогается** (last-known-good). Иначе сбой панели «разбанил» бы весь флот, и ноды начали бы лимитировать трафик друг друга. Применение — **отдельной** nft-транзакцией (битые данные не ломают `ddos_protect`).
- Токен хранится в `/etc/shieldnode/remnawave.env` (root:root **0600**), **не** в `shieldnode.conf`. На `guard upgrade`/reinstall восстанавливается оттуда — заново передавать env не нужно.

Управление:

```bash
SHIELD_REMNAWAVE_SYNC=auto      # вкл, если заданы URL+TOKEN (дефолт); 1=форс; 0=выкл
SHIELD_REMNAWAVE_INTERVAL=5min  # интервал синка
journalctl -t shieldnode-remnawave   # лог синка
```

`guard` показывает: `fleet-sync active (ноды Remnawave → whitelist: N v4 + M v6, last …)`.

> `TRUSTED_IPS` остаётся для прочих доверенных IP (мониторинг, личный mgmt-IP, не-Remnawave апстримы) — fleet-sync автоматизирует именно ноды флота, не отменяя ручной whitelist.

---

## guard CLI

```bash
sudo guard            # дашборд + интерактивное меню
sudo guard --once     # снимок без меню (cron / мониторинг)
sudo guard --json     # JSON-вывод (Zabbix / Prometheus)
sudo guard upgrade    # re-install с GitHub (auto-snapshot для отката)
sudo guard rollback   # откат к предыдущему снапшоту
sudo guard sync       # синк custom.txt прямо сейчас
sudo guard self-test  # быстрые проверки ноды
```

Дашборд показывает **реальные дропы всех слоёв**, включая `ctguard phantom-evict` и `cap` (отдельная таблица), режим ctguard (normal/**attack**) и `phantom-ratio`, статус SYNPROXY (вкл. `DEGRADED`), conntrack %, блоклисты (вкл. суммарный v6-счётчик), top-attackers с ASN/владельцем. `self-test` проверяет в т.ч. heartbeat ctguard (детект залипшего таймера).

> ASN/владелец для top-attackers резолвится через **Team Cymru whois** (v3.27.2, заменил legacy ipinfo.io: без ключа/квоты, без утечки IP коммерческому geoIP). Нужен пакет `whois` (ставится best-effort; нет → колонка владельца «?», без лагов). Кэш в `events.db`, TTL 7 дней. Это read-only интел для оператора — на блокировки не влияет.

Интерактивное меню: `[2]` CrowdSec bans, `[3]` whitelist, `[6]` recent history, `[7]` top attackers (all-time), `[8]` unban all, `[s]` settings.

---

## Конфигурация

- `/etc/shieldnode/limits.conf` — все лимиты + ручки ctguard (`SHIELD_CTG_ENFORCE`, `SHIELD_CTG_LIVE_FRAC`, `SHIELD_CTG_PHANTOM_RATIO`, `SHIELD_CTG_PHANTOM_MIN`, `SHIELD_CTG_AGG_CAP`, `SHIELD_CTG_ACTIVE_FLOOR`, `SHIELD_CTG_CT_MAX_CEIL`, `SHIELD_CTG_COARSE_MULT`). v3.27: `SHIELD_CGNAT_SAFE` (превышение per-IP лимита режет только избыток, не банит общий CGNAT-IP — дефолт 1), `SHIELD_CTG_ANOM_WINDOW` (анти-pulsing скользящее окно), `SHIELD_GLOBAL_NEWCONN_CEIL` (opt-in глобальный backstop new-conn/с на protected-TCP, дефолт 0 — для НЕ-CGNAT нод), `SHIELD_CTG_CT_RAM_PCT` (потолок авто-роста conntrack от RAM — анти-OOM). Файл sourced'ится с проверкой прав (root:root, 0640).
- `/etc/shieldnode/shieldnode.conf` — фичи: `SHIELD_SYNPROXY`, `SHIELD_SYNPROXY_SSH` (synproxy и для SSH, дефолт 1), `SHIELD_CTGUARD`, `BLOCK_TOR`, `SHIELD_V6_REJECT` (RST вместо drop для v6-TCP на VPN-портах, дефолт 0), `TRUSTED_IPS` (single IP и CIDR), `REMNAWAVE_URL` + `SHIELD_REMNAWAVE_SYNC` (fleet auto-sync; токен — в `remnawave.env`, не здесь), и др.
- `/etc/shieldnode/remnawave.env` (root:root 0600) — `REMNAWAVE_URL` + `REMNAWAVE_TOKEN` для fleet auto-sync (создаётся при install, если передан токен).

После изменения лимитов: `sudo systemctl restart shieldnode-nftables.service` (для nft) и `sudo systemctl restart shieldnode-ctguard` (для ctguard), либо `sudo guard upgrade`.

---

## Удаление

```bash
curl -fL https://raw.githubusercontent.com/SpofyJet/shield/main/shieldnode.sh | sudo bash -s -- --uninstall
```

Удаляет все таблицы (`ddos_protect`, `shield_synproxy`, `shield_ctguard`), юниты, таймеры, state и sysctl-drop-in.

---

## Совместимость

- **UFW** — открытые порты читаются автоматически (inotify path-watcher + catch-all timer).
- **Любой VPN-стек** — терминируется отдельно, shieldnode только фильтрует.
- **Другие nft-таблицы** — мирно сосуществует (свои изолированные таблицы, без `flush ruleset`, UFW не ломается).
- **`vpn-node-setup`** — парный скрипт для kernel-tuning (XanMod/BBRv3); зоны ответственности не пересекаются.

---

## Изменения (последние)

- **v3.28.9** — закрытие остатков из саморевью (2 фикса робастности). (1) `modprobe` в `shieldnode-synproxy.service` был хардкодом `/sbin/modprobe` с `-` → на системах с modprobe в `/usr/sbin` шаг молча пропускался и `nf_synproxy` не грузился при boot (фикс v3.28.7 не срабатывал); теперь поиск через PATH. (2) Интерактивный chooser whitelist читал `/dev/tty` без таймаута → при tty-без-ввода `read` мог зависнуть навечно; добавлен `read -t 300` (по таймауту → «пропустить»). Пункт #3 (gateless main prerouting) сознательно не трогается — гейт на всей цепочке `ddos_protect` снял бы защиту с DNAT-публикуемых портов, а форвардный трафик она и так не ломает (единственный ломатель — synproxy notrack — закрыт в v3.28.4).

- **v3.28.8** — fix полноты `guard rollback` (по итогам аудита install/upgrade). Snapshot был неполным: 7 скриптов из 15 и ноль systemd-юнитов → после rollback synproxy/ctguard/remnawave-sync/auto-promote/cleanup/pcap/mobile-ru и юниты оставались на новой версии (рассинхрон). Плюс nft-restore флашил только `ddos_protect`. Теперь snapshot глобит все `shieldnode-*.sh` + guard, сохраняет/восстанавливает юниты, перед `nft -f` флашит все три таблицы, и на rollback перезапускает synproxy/ctguard. Касается только upgrade/rollback.

- **v3.28.7** — надёжность включения SYNPROXY (3 фикса гонок; симптом — DEGRADED при install/boot, но `shieldnode-synproxy.sh on` вручную включает). (1) `verify_untracked_reaches` давал **ложный откат**: одно окно «SYN есть, счётчик synproxy не растёт» → `disable`, хотя synproxy законно не считает ретрансмиты/уже-tracked SYN. Теперь откат только при **двух** подтверждённых окнах. (2) systemd-сервис делал голый `nft -f` без `modprobe nf_synproxy` → на ядрах с модульным nf_synproxy (стоковые + часть XanMod) после ребута SYNPROXY не вставал; добавлен `ExecStartPre=modprobe`. (3) `enable()` не снимал degraded-маркер при успехе — теперь снимает.

- **v3.28.6** — fix отображения: `All-time history (since —)` на ноде, где событий ещё не было. Дата бралась как `MIN(first_seen)` из events.db → при пустой таблице NULL → прочерк. Теперь при пустой БД `since` = время создания файла events.db (старт трекинга). Только отображение.

- **v3.28.5** — fix отображения: в guard строка `fix:` при `synproxy DEGRADED` печаталась с буквальным `$(uname -r)` (экранированный `$`) вместо реальной версии ядра, и совет `apt install linux-modules-extra-…` неверен для **XanMod** (там `nf_synproxy` встроен, пакета не существует). Теперь подсказка kernel-aware: на XanMod сообщает, что модуль встроен и направляет на `shieldnode-synproxy.sh on` + `dmesg`; на стоковом ядре подставляет реальную версию ядра. Только текст подсказки.

- **v3.28.4** — fix: SYNPROXY ломал форвардный трафик на хосте с панелью. На сервере с Remnawave в Docker нода с control-портом 2223 ушла в offline после апгрейда: 2223 попал в защищаемые порты → правило `notrack` в prerouting цепляло **транзитное** исходящее соединение контейнера панели к удалённой ноде (`panel→node:2223`) и ломало его conntrack/NAT → ответ ноды не возвращался → timeout. (Хост-локальный `nc` работал, т.к. OUTPUT минует prerouting; контейнер — нет.) Фикс: `notrack` теперь только для трафика к **самому хосту** (`fib daddr type local`). Транзит (Docker/панель/роутер) не трогается; защита локальных сервисов как прежде; на обычных нодах поведение не меняется. **Срочный обход без апдейта:** `shieldnode-synproxy.sh off` на панели.

- **v3.28.3** — fix интерактивного выбора. При `guard upgrade` показывался старый вопрос про bridge-IP, а выбора «токен или IP» не было: выбор v3.28.1 и существующий bridge-промпт были **двумя разными** вопросами (на обычной ноде дублировались бы). Теперь это **один** вопрос (старый bridge-промпт заменён выбором 1/2/3), интерактивность определяется по `/dev/tty` и чтение идёт с него → работает И в `guard upgrade`, И в `curl|bash` (раньше в pipe-режиме промпт пропускался). Опрос пропускается, если whitelist нод уже настроен (BRIDGE_IPS/TRUSTED_IPS/`remnawave.env`/токен). **Чтобы выбор появился на нодах — сначала задеплой версию (`deploy-shield.sh`), потом `guard upgrade`.**

- **v3.28.2** — fix отображения: в строке `blocklists` дашборда вокруг счётчика v6 печатался сырой `\033[0;36m…` вместо цвета (цветовые коды попадали в `%s`-аргумент `printf`, где escape не интерпретируется). Вывод переведён на `%b`. Косметика, на защиту не влияет.

- **v3.28.1** — установка теперь **спрашивает интерактивно** (до долгих apt-операций), как whitelist'ить ноды флота: **1)** Remnawave токен (авто-дискавери, рекомендуется), **2)** вручную IP нод/бриджей (`TRUSTED_IPS`), **3)** пропустить. Раньше токен/IP надо было знать заранее и передавать через env/conf. Промпт показывается только на свежей ноде (если уже сконфигурено — env/conf/`remnawave.env`/`TRUSTED_IPS` — пропускается, апгрейды не переспрашивают). В `curl|bash` читает с `/dev/tty`, токен — скрытым вводом, URL валидируется. Headless/CI → тихо пропускается (работает env). Отключить: `SHIELD_WL_PROMPT=0`.

- **v3.28.0** — **Remnawave fleet auto-sync.** Вместо ручного перечисления IP нод/бриджей в `TRUSTED_IPS` на каждой ноде — даёшь токен панели (`REMNAWAVE_URL` + `REMNAWAVE_TOKEN`), и shieldnode в фоне (таймер, дефолт 5 мин) тянет `GET /api/nodes`, резолвит адрес каждой ноды (IP или hostname → `getent`) и держит nft-сеты `remnawave_nodes_v4/v6` в актуальном виде. Новую ноду добавил в панель → все ноды подхватят её сами. Сеты accept'ятся сразу после whitelist (bypass лимитов — это свои серверы, CGNAT-safe). **Fail-safe:** панель недоступна / кривой ответ / 0 валидных IP → текущий whitelist нод НЕ трогаем (last-known-good), применение — отдельной nft-транзакцией. Токен в `/etc/shieldnode/remnawave.env` (root:root 0600), не в `shieldnode.conf`. Включается авто при наличии URL+TOKEN (`SHIELD_REMNAWAVE_SYNC=auto|1|0`). `guard` показывает статус + число нод. Зависимости: `curl`+`jq` (уже есть), резолв — `getent` (без новых пакетов).

- **v3.27.2** — актуализация внешних фидов/API (сам код свежий, но третьи стороны поменялись в 2024–2025). **Feodotracker убран** из `threat` (датасет abuse.ch пуст + обязательный `Auth-Key` с 06.2025 + миграция под Spamhaus). **Spamhaus DROP: txt → JSON** (`drop_v4.json` + `drop_v6.json`; txt у Spamhaus на пути к deprecation) — JSON парсится существующей jq-веткой; `drop_v6.json` теперь наполняет `threat_blocklist_v6`. **ASN-lookup в `guard`: ipinfo.io → Team Cymru whois** (без ключа/квоты, без утечки IP коммерческому geoIP; пакет `whois` best-effort). Удалён мёртвый `SHIELD_CT_EVICT_MIN`. v6 threat-флор /32→/29 (под Spamhaus drop_v6). Рантайм-тулчейн (nftables/conntrack/iproute2/systemd/curl/sqlite3/jq/python3/crowdsec) — актуален, дрейф был только во внешних data-feeds.

- **v3.27.1** — red-team раунд 2, закрыто без риска для CGNAT. **Анти-pulsing**: дебаунс капа переведён со строго-последовательного счётчика на **скользящее окно** (`SHIELD_CTG_ANOM_WINDOW`, ≥N аномалий в окне) — атака «вкл/выкл» больше не уходит от глобального капа; одиночный всплеск по-прежнему кап НЕ включает (анти-FP сохранён). **SYNPROXY покрывает SSH** (`SHIELD_SYNPROXY_SSH=1`) — спуф-SYN на SSH-порт больше не течёт conntrack.

- **v3.27.0** — red-team раунд 1: закрыто 11 дыр без регрессий для CGNAT. **CGNAT-safe rate-shape** (`SHIELD_CGNAT_SAFE=1`): превышение per-IP лимита режет избыток, не банит общий CGNAT-IP. **conntrack анти-OOM**: авто-рост `nf_conntrack_max` ограничен % от RAM (`SHIELD_CTG_CT_RAM_PCT`). **ctguard капает и UDP** в attack-mode (спуф/распределённый UDP). **ctguard CPU-приоритет** понижен (не отбирает CPU у xray под атакой). **Распределённый connect-and-hold**: 2-й проход эвикта (`live==0`, CGNAT щадится). **SYNPROXY fail-loud** (degraded-маркер + `DEGRADED` в guard). **bridge/whitelist-drift advisory** в guard. **IPv6 threat-feeds (#7)**: v6-параллели блоклистов + v6 drop-правила + v6-парсинг апдейтера (отдельной транзакцией). v6 happy-eyeballs (`SHIELD_V6_REJECT`). Опц. глобальный new-conn ceiling (`SHIELD_GLOBAL_NEWCONN_CEIL`, для не-CGNAT). Аггрегатор: cap журнала на тик (анти-OOM).

- **v3.26.5** — авто-апгрейд зависимостей при install/upgrade: управляемые apt-пакеты (nftables, conntrack, iproute2, tcpdump, sqlite3, jq, curl, zstd, xz-utils, `crowdsec` + firewall-bouncer) держатся на последней версии репо (security-патчи). Апгрейд только если репо-версия строго новее (downgrade исключён через `--only-upgrade`). Foreign-CrowdSec не трогается (только подсказка). Заморозить: `SHIELD_UPGRADE_DEPS=0`.

- **v3.26.4** — фикс ложных срабатываний на мобильных/CGNAT-нодах. phantom attack-mode входит **только при реальном per-source холдере** (≥`PHANTOM_MIN`); мобильный churn (conntrack≫live и у легита из-за `est_to`) больше НЕ объявляет атаку. `PHANTOM_MIN` дефолт 500→4000 (выше легит-CGNAT-churn ~2200, ниже атаки 7000+) → `ENFORCE=1` снова безопасен на мобильных нодах. Агрегатный кап теперь **opt-in** (`SHIELD_CTG_AGG_CAP`: 0=прямые, 1=CDN/мост); настоящий rate/fill-флуд капается всегда. `ensure_table` пересоздаёт устаревшую таблицу без `capnew` (фикс WARN-спама «не наложил агрегатный кап» при апгрейде поверх <v3.26). Убран per-tick лог «фантом-холдеров не найдено».
- **v3.26.3** — perf: дешёвый коарс-гейт в ctguard (полный `conntrack -L` дамп только при `conntrack ≫ ss` или attack-mode). Наблюдаемость: guard «Total blocked» + разбивка включают дропы ctguard-слоя; `self-test` проверяет heartbeat ctguard. Конфиг: ручки `SHIELD_CTG_*` выведены в `limits.conf`.
- **v3.26.x** — phantom-детект по **живым сокетам** (`ss` vs conntrack, acct-free) + `ss-phantom-ratio` триггер + conntrack-exhaustion guard. Заменил байтовый детектор (тот при `acct=0` мог масс-эвиктить CGNAT — критфикс). `is_protected` v4/v6, synproxy `sp_ports` auto-merge + синк портов. per-IP conn-flood = высокий backstop 15000.
- **v3.24.0** — SYNPROXY включён по умолчанию; первый модуль conntrack-guard (тогда — только fill-триггер + per-IP-порог; в v3.26 переписан на liveness).
- **v3.23.19** — CRIT FIX агрегатора (lock под `ProtectSystem=strict` падал → статистика замерзала).
- **v3.23.16** — SYNPROXY как изолированный модуль (защита от conntrack-exhaustion).
- **v3.23.15** — security hardening: SQL-inj через journald, bogon-фильтр фидов, оживление auto-promote, RAM-cap агрегатора, SSH/IPv6.
- **v3.23.3** — post-incident (2026-05-24): conn-flood 50k→15k, pcap-capture, auto-promote, CrowdSec scenario.

Полная история: <https://github.com/SpofyJet/shield/commits/main>

---

## Поддержка

Вопросы по установке, тюнингу под нагрузку и кастомные настройки — Telegram **[@SpofySup](https://t.me/SpofySup)**.

---

## Лицензия

MIT — см. [LICENSE](LICENSE).
