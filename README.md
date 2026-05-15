# vpn-node-setup

Universal Linux optimizer для VPN-нод (Xray Reality / sing-box / Hysteria2 / WireGuard / AmneziaWG).

Стэк: **XanMod LTS kernel + BBRv3 + tier-aware tuning**. Целевые ОС: Ubuntu 22.04/24.04, Debian 12/13.

## Что делает

- Ставит **XanMod LTS kernel** (с BBRv3 встроенным)
- Tier-aware sysctl tuning (4 профиля по RAM: 1GB / 2GB / 4-8GB / 8GB+)
- **qdisc fq** + multi-queue для NIC
- **TCP buffers** под BDP (rmem_max до 32MB на TIER 4)
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

- Работает рядом с **shieldnode v3.22.0+** (рекомендуется порядок: **vpn-node-setup первым, потом shieldnode** — минимизирует окно потери MSS clamp)
- shieldnode владеет security sysctl (rp_filter, syncookies, etc.) — vpn-node-setup их не трогает с v5.0.4
- vpn-node-setup владеет conntrack_max + TCP timeouts — shieldnode их не трогает

## Установка

```bash
curl -fL https://raw.githubusercontent.com/abcproxy70-ops/node/main/vpn-node-setup.sh | sudo bash -s -- --optimize
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

## Полная установка (vpn-node-setup + shieldnode)

Рекомендуемый порядок:

```bash
# Step 1: vpn-node-setup первым (медленнее, может попросить reboot)
curl -fL https://raw.githubusercontent.com/abcproxy70-ops/node/main/vpn-node-setup.sh | sudo bash -s -- --optimize

# Если попросил reboot — reboot и проверь что новое ядро активно:
# sudo reboot
# uname -r   # должно содержать "xanmod-lts"

# Step 2: shieldnode после reboot (быстро)
curl -fL https://raw.githubusercontent.com/abcproxy70-ops/shield/main/shieldnode.sh | sudo bash

# Verify
sudo guard --once   # дашборд DDoS защиты
sysctl net.netfilter.nf_conntrack_max   # ожидается 262144+ (или больше по tier)
sysctl net.ipv4.tcp_congestion_control  # должно быть bbr
```

**Почему vpn-node-setup первым**: если установка vpn-node-setup потребует
обновления ядра — reboot не нарушит ещё не установленный shieldnode. После
reboot ставим shieldnode на стабильное ядро.

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

- **v5.0.6** — CONNTRACK FIXES для 1000+ юзеров:
  - **TIER 2** (≤2.5GB RAM) conntrack_max 524288 → **786432** (запас на 1500+ юзеров)
  - **TIER 4** (>8.5GB RAM) conntrack_max 1048576 → **2097152** (для 3000+ юзеров на одной ноде, ранее TIER 4 был идентичен TIER 3)
  - **conntrack_tcp_timeout_established** 7200 → **86400** (long-lived TCP: SSH/Telegram MTProto/IMAP IDLE/WebSocket больше не дропается через 2 часа)
  - **TIER 2 vm.overcommit_memory=1** (защита от OOM на пиках на 2GB нодах)
  - Critical fix: installed.sh при `bash <(curl ...)` (был обрезанный файл)
  - Убраны ложные упоминания "tcp_fastopen=3 ломает Reality" в комментах (TFO=3 работает корректно с Reality, разные слои стека)
- **v5.0.5** — HEADLINE FIX: YouTube/streaming freeze. Убран `tcp_notsent_lowat=131072` (вернулся kernel default unlimited). Убран `gro_flush_timeout=50µs` defer (вернулся classic NAPI). Throughput не меняется, periodic stalls устраняются.
- **v5.0.4** — ARCH SIMPLIFICATION (убраны пересечения с shieldnode v3.20.5): удалены 6 дублирующих sysctl, удалён iptables fallback в MSS clamp, atomic nft transaction, ExecStop с `-` префиксом. Critical fixes: DEFAULT_IFACE присваивается (NIC validation), GPG download-first + keyserver fallback.
- **v5.0.3** — HEADLINE FIX: `tcp_fastopen=3` (TFO для TCP клиентов и серверов). Решает bottleneck ~550-630 юзеров на ноду.
- **v5.0.x** — Snapshot-based rollback, TUI menu по default, self-upgrade flow.
- **v4.x** — XanMod LTS migration (с MAIN), tier-aware buffers, NIC бусты (GRO, ethtool, IRQ).

Полная история: https://github.com/abcproxy70-ops/node/commits/main/vpn-node-setup.sh

## Лицензия

MIT — см. [LICENSE](./LICENSE).
