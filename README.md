# vpn-node-setup

Universal Linux optimizer для VPN-нод (Xray Reality / sing-box / Hysteria2 / WireGuard).

Стэк: **XanMod LTS kernel + BBRv3 + tier-aware tuning**. Целевые ОС: Ubuntu 22.04/24.04, Debian 12/13.

## Что делает

- Ставит **XanMod LTS kernel** (с BBRv3 встроенным)
- Tier-aware sysctl tuning (4 профиля по RAM: 1GB / 2GB / 4-8GB / 8GB+)
- **qdisc fq** + multi-queue для NIC
- **TCP buffers** под BDP (rmem_max до 32MB на TIER 4)
- **TFO=3** (TCP Fast Open) — решает bottleneck 580-630 юзеров на ноду
- **MSS clamp** через nftables (lечит PMTU blackhole у мобильных юзеров)
- **conntrack tuning** под VPN-нагрузку
- **NIC offloads** + RPS + IRQ affinity
- **ulimit nofile** 500000

## Совместимость

- Работает рядом с **shieldnode v3.20.5+** (рекомендуется порядок: shieldnode → vpn-node-setup)
- shieldnode владеет security sysctl (rp_filter, syncookies, etc.) — vpn-node-setup их не трогает с v5.0.4

## Установка

```bash
bash <(curl -sL https://raw.githubusercontent.com/abcproxy70-ops/node/main/vpn-node-setup.sh)
```

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

- **v5.0.5** — HEADLINE FIX: YouTube/streaming freeze. Убран `tcp_notsent_lowat=131072` (вернулся kernel default unlimited). Убран `gro_flush_timeout=50µs` defer (вернулся classic NAPI). Throughput не меняется, periodic stalls устраняются.
- **v5.0.4** — ARCH SIMPLIFICATION (убраны пересечения с shieldnode v3.20.5): удалены 6 дублирующих sysctl, удалён iptables fallback в MSS clamp, atomic nft transaction, ExecStop с `-` префиксом. Critical fixes: DEFAULT_IFACE присваивается (NIC validation), GPG download-first + keyserver fallback. High fixes: `$(date)` → date-only, qdisc guard против htb/cake, `systemctl stop --no-block`, apt-update fail cleanup, `wget --timeout=15`, `*lts*xanmod*` glob, atomic `--upgrade` transaction, patch-level regex.
- **v5.0.3** — HEADLINE FIX: `tcp_fastopen=3` (TFO для TCP клиентов и серверов). Решает bottleneck ~550-630 юзеров на ноду.
- **v5.0.x** — Snapshot-based rollback, TUI menu по default, self-upgrade flow.
- **v4.x** — XanMod LTS migration (с MAIN), tier-aware buffers, NIC бусты (GRO, ethtool, IRQ).

## Лицензия

MIT — см. [LICENSE](./LICENSE).
