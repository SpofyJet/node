# node — оптимизация VPS под VPN-ноду (Xray / Remnawave)

**v5.10.0** · Debian 12/13 · Ubuntu 24.04+ (jammy/focal не поддерживаются)

Один скрипт: ядро XanMod LTS + BBRv3, тюнинг сетевого стека по профилям RAM,
flow offloading, очистка системы от фонового мусора.

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/SpofyJet/node/main/vpn-node-setup.sh -o vpn-node-setup.sh
sudo bash vpn-node-setup.sh --optimize
sudo reboot   # для перехода на XanMod
```

Обновление до свежей версии (скрипт сам скачает себя с GitHub):

```bash
sudo bash vpn-node-setup.sh --upgrade
```

## Что делает

| Компонент | Эффект |
|---|---|
| **XanMod LTS + BBRv3** | пропускная способность и latency под нагрузкой |
| **Sysctl TIER-профили** | параметры под объём RAM (1GB → 16GB+) |
| **Flowtable (sw + hw offload)** | established-потоки минуя filter-цепочки; на mlx5/bnxt/i40e — оффлоад в силикон NIC |
| **MSS clamp (nftables)** | нет фрагментации в туннелях |
| **UDP buffers 32/64M** | Hysteria2/TUIC на длинных линках |
| **zram (zstd, opt writeback)** | anti-OOM на 1–2GB нодах |
| **IRQ affinity + adaptive coalescing** | меньше jitter под PPS |
| **busy_poll (opt-in)** | −10–30µs latency |
| **Background cleanup** | выключает 100% мусор: packagekit, bluetooth, cups, avahi, thermald, ModemManager, motd-news и др. |
| **unattended-upgrades OFF** | никаких фоновых apt (CPU/IO в случайный момент) |

## Флаги

```
--optimize          прямая оптимизация (для CI/ansible)
--check             проверить новую версию на GitHub
--upgrade           скачать и запустить свежую версию (со snapshot'ом)
--diff              diff установленной и upstream-версии
--rollback          откат после неудачного --upgrade
--diagnose[-quick]  диагностика ноды (node-diagnostic)
--dry-run           показать план без установки ядра
```

## Переменные окружения (opt-in / opt-out)

| Переменная | Дефолт | Что даёт |
|---|---|---|
| `DISABLE_FLOWTABLE=1` | off | не включать flow offloading |
| `DISABLE_HW_FLOW_OFFLOAD=1` | off | только software offload |
| `ENABLE_BUSY_POLL=1` | off | −10–30µs latency ценой CPU spin |
| `SETUP_NO_ZRAM=1` | off | не создавать zram-swap |
| `ZRAM_WRITEBACK_DEV=/dev/sdXN` | off | выгрузка холодных страниц zram на диск |
| `SETUP_DISABLE_BG_SERVICES=0` | on | не трогать фоновые сервисы |
| `SETUP_DISABLE_UNATTENDED=0` | on | оставить авто-обновления apt |
| `SETUP_DISABLE_SNAPD=1` | off | +40–70MB RAM (не на Ubuntu Pro) |
| `SETUP_DISABLE_MTA=1` | off | выключить exim4/postfix |
| `DISABLE_TFO=1` | off | выключить TCP Fast Open |

Changelog — в шапке `vpn-node-setup.sh` (newest-first).
Парный проект: [SpofyJet/shield](https://github.com/SpofyJet/shield) — защита ноды от сканеров/DDoS.
