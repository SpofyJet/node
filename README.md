# vpn-node-setup

Universal Linux optimizer для VPN-нод (Xray Reality / sing-box / Hysteria2 / WireGuard / AmneziaWG).

Стэк: **XanMod LTS kernel + BBRv3 + tier-aware tuning**. Целевые ОС: Ubuntu 24.04+, Debian 12/13.

> ⚠️ **Ubuntu 22.04 (jammy) не поддерживается** — XanMod не публикует ядра для этого codename (curl-verified: 404). Обнови ОС до 24.04 или используй штатное ядро с BBR (`modprobe tcp_bbr`).

## Что делает

- Ставит **XanMod LTS kernel** (с BBRv3 встроенным)
- Tier-aware sysctl tuning (4 профиля по RAM: 1GB / 2GB / 4-8GB / 8GB+)
- **QUIC buffers** правильно разделены: rmem/wmem_max (потолок setsockopt) поднят под quic-go/Hysteria2; tcp_rmem/tcp_wmem (TCP-автотюн для Reality) не привязаны к rmem_max
- **qdisc fq** + multi-queue для NIC
- **QUIC/UDP buffers** (rmem_max/wmem_max): TIER1 8/8MB, TIER2 16/16MB, TIER3/4 16-32MB — закрывает quic-go (7.5MB) и Hysteria2 (16MB)
- **TCP buffers** (tcp_rmem/tcp_wmem, автотюн): до 32MB на TIER 4; не лимитируется rmem_max
- **TFO=3** (TCP Fast Open) — решает bottleneck 580-630 юзеров на ноду
- **MSS clamp** через nftables (лечит PMTU blackhole у мобильных юзеров)
- **conntrack tuning** под VPN-нагрузку (v5.0.6: tier-aware max + 24h tcp_established)
- **NIC offloads** + RPS + IRQ affinity
- **ulimit nofile** 500000

## Conntrack tier-aware sizing (v5.0.6)

| RAM | conntrack_max | hashsize | Прим. users |
|-----|---------------|----------|-------------|
| ≤1.2GB | 262144 | 65536 | до ~200 |
| ≤2.5GB | **786432** ↑ | 196608 | до ~700 (v5.0.6 bump для запаса на 1000+) |
| ≤8.5GB | 1048576 | 262144 | до ~3000 |
| >8.5GB | **2097152** ↑ | 524288 | до ~6000 (v5.0.6 bump для TIER 4) |

Cost: 1M записей × ~316 байт = ~316MB RAM (4% на 8GB ноде).

## Совместимость

- Не конфликтует с пользовательскими nft-таблицами и UFW (использует свою таблицу `inet vpn_node_mss_clamp`)
- Не трогает security-sysctl (rp_filter, syncookies и т.п.) — если они уже выставлены другим инструментом, vpn-node-setup их не перезапишет

## Установка

```bash
curl -fL https://raw.githubusercontent.com/SpofyJet/node/main/vpn-node-setup.sh | sudo bash -s -- --optimize
```

> ⚠️ Use `curl | sudo bash -s -- ARGS` вместо `bash <(curl ...)` — process
> substitution не работает на OpenVZ/LXC контейнерах. Конструкция `-s --` нужна
> чтобы передать аргументы (`--optimize`) в скрипт через pipe.

После установки скрипт сам:
- определит профиль ноды по RAM
- поставит XanMod LTS если не активен
- применит sysctl + qdisc + NIC tuning
- настроит MSS clamp через nftables (table `inet vpn_node_mss_clamp`)
- предложит reboot если ядро обновилось

## Команды

```bash
sudo vpn-node-setup --optimize    # применить оптимизации (default)
sudo vpn-node-setup --check       # проверить доступную upstream версию
sudo vpn-node-setup --upgrade     # скачать новую версию и применить
sudo vpn-node-setup --rollback    # откатить sysctl/limits/MSS к предыдущей версии
sudo vpn-node-setup --diagnose    # TUI диагностика ноды
```

Или через TUI меню (без аргументов):

```bash
sudo vpn-node-setup
```

## Версии

- **v5.2.0** — LATENCY FIX + KERNEL REPLACE:
  - **CRIT FIX**: `tcp_adv_win_scale` **-2 → 1** (дефолт ядра). `-2` анонсировал окно больше реального буфера → постоянный `tcp_collapse()`/prune на relay (намерено ~59 collapse/сек, TCPRcvCollapsed ~95M) → жжёный softirq + дропы на приёме → у клиентов микро-фризы, просадки, долгая загрузка видео/картинок. BBR делает свой pacing — минусов нет.
  - **FEATURE**: реальная ЗАМЕНА чужого XanMod — после установки LTS purge чужих метапакетов (MAIN/edge/rt) + не-running не-LTS образов (running остаётся fallback до ребута). Под `--dry-run` печатает план purge без удаления. Отключение: `SETUP_NO_KERNEL_REPLACE=1`. Раньше чужая версия оставалась рядом и возвращалась через apt upgrade.
- **v5.3.2** — XanMod codename guard + tuning corrections:
  - **FIX**: guard на неподдерживаемый XanMod codename. Curl-verified: jammy (Ubuntu 22.04) и focal (20.04) → 404 на deb.xanmod.org. Раньше: FATAL без понятной причины. Теперь: ранний выход с чётким сообщением.
  - **REVERT**: `tcp_no_metrics_save` убран (ядро: default=0 обычно лучше).
  - **DOC**: MSS clamp эффективен с urезанным egress MTU (WARP/wgcf/PPPoE/5G); на прямом 1500 — inert.
- **v5.3.1** — QUIC buffers + remnanode logrotate:
  - **TUNE**: TIER1 rmem_max/wmem_max 4MB/2MB → **8MB/8MB** (quic-go требует ≥7.5MB; раньше QUIC-send резался в 2MB и quic-go писал "failed to sufficiently increase buffer").
  - **TUNE**: TIER2 wmem_max 8MB → **16MB** (Hysteria2 рекомендует 16MB; rmem_max уже был 16MB).
  - **FEAT**: logrotate для `/var/log/remnanode/*.log` (требование доков Remnawave; copytruncate — Xray держит файл открытым).
- **v5.3.0** — robustness + reliability hardening:
  - **CRIT FIX**: RAM-детект тиров из `/proc/meminfo` (MemTotal) вместо локале-зависимого `free` — защита от mis-tiering на non-English локалях.
  - **CRIT FIX**: CPU без SSE4.2 → v1 ядро (раньше — v2, что = illegal instructions → unbootable).
  - **FIX**: диагностика: клавиша `q` = выход (раньше перехватывалась quick-прогоном).
  - **FIX**: самолечение битого xanmod-репо при повторном запуске после обрыва.
  - **FIX**: `--upgrade` не теряет версию при ребуте внутри новой версии.
  - **FIX**: IRQ affinity через `smp_affinity_list` — корректно на 32+ CPU.
  - **FIX**: multipathd не отключается на multipath-root (анти-кирпич).
  - **FIX**: unattended-upgrades отключение opt-out (`SETUP_DISABLE_UNATTENDED=0`).
  - **FEAT**: zram-swap на TIER1/2 (анти-OOM; 50% RAM / max 512MB / zstd).
  - **FEAT**: ring buffers на физ-NIC через udev (device-add, без per-boot link-flap).
  - **FEAT**: scaffold проверки подписи апдейта (`SETUP_REQUIRE_SIG=1`, выкл по умолчанию).
- **v5.1.1** — REFACTOR + IMPROVEMENTS:
  - **REFACTOR**: sysctl-файл переименован `99-vpn-node-tuning.conf` → **`80-vpn-node-tuning.conf`**. Префикс `80` — базовая полка tuning, любые security-overrides из `90-*.conf` или ad-hoc fixes `99-z-*.conf` корректно перекроют наши значения. Cleanup удаляет legacy `99-` файл при первой установке.
  - **IMPR**: `tcp_adv_win_scale=-2` теперь во всех tier (раньше только TIER 3/4).
  - **IMPR**: ethtool offloads — LRO off (defensive), `rx-udp-gro-forwarding on`.
  - **IMPR**: попытка multi-queue NIC (`combined N`), silent fail на virtio max=1.
- **v5.0.6** — CONNTRACK FIXES для 1000+ юзеров:
  - **TIER 2** (≤2.5GB RAM) conntrack_max 524288 → **786432** (запас на 1500+ юзеров)
  - **TIER 4** (>8.5GB RAM) conntrack_max 1048576 → **2097152** (для 3000+ юзеров на одной ноде, ранее TIER 4 был идентичен TIER 3)
  - **conntrack_tcp_timeout_established** 7200 → **86400** (long-lived TCP: SSH/Telegram MTProto/IMAP IDLE/WebSocket больше не дропается через 2 часа)
  - **TIER 2 vm.overcommit_memory=1** (защита от OOM на пиках на 2GB нодах)
  - Critical fix: installed.sh при `bash <(curl ...)` (был обрезанный файл)
- **v5.0.5** — HEADLINE FIX: YouTube/streaming freeze. Убран `tcp_notsent_lowat=131072` (вернулся kernel default unlimited). Убран `gro_flush_timeout=50µs` defer (вернулся classic NAPI). Throughput не меняется, periodic stalls устраняются.
- **v5.0.4** — ARCH SIMPLIFICATION: удалены 6 дублирующих sysctl, удалён iptables fallback в MSS clamp, atomic nft transaction, ExecStop с `-` префиксом. Critical fixes: DEFAULT_IFACE присваивается (NIC validation), GPG download-first + keyserver fallback.
- **v5.0.3** — HEADLINE FIX: `tcp_fastopen=3` (TFO для TCP клиентов и серверов). Решает bottleneck ~550-630 юзеров на ноду.
- **v5.0.x** — Snapshot-based rollback, TUI menu по default, self-upgrade flow.
- **v4.x** — XanMod LTS migration (с MAIN), tier-aware buffers, NIC бусты (GRO, ethtool, IRQ).

Полная история: https://github.com/SpofyJet/node/commits/main/vpn-node-setup.sh

## Лицензия

MIT — см. [LICENSE](./LICENSE).
