# vpn-node-setup

**XRAY/REMNAWAVE NODE BUILDER** — оптимизатор VPN-ноды: ядро **XanMod LTS (BBRv3)**, tier-aware сетевой тюнинг, MSS clamp и встроенная диагностика. Один скрипт, идемпотентный, с самообновлением и откатом.

Заточен под Remnawave / Xray-ноды (VLESS-Reality, xHTTP, Hysteria2/TUIC) в `network_mode: host`.

---

## Что делает

- **Ядро XanMod LTS + BBRv3** — авто-выбор сборки по psABI-уровню CPU (`x64v3/v2/v1`), старое ядро остаётся в GRUB как fallback.
- **Tier-aware sysctl** — буферы, conntrack, somaxconn, TFO, syncookies масштабируются от объёма RAM (не «одни числа на всё»).
- **conntrack** — `max` + `hashsize` по RAM ноды (мелкая VPS под нагрузкой не уходит в OOM ядра).
- **QDISC** — `mq + fq` на multi-queue NIC, `fq` на single-queue; кастомный qdisc (cake/htb) не трогается.
- **RPS/XPS** — размазывает softirq по ядрам (на virtio single-queue это реальный потолок PPS).
- **NIC-бусты** — ring buffers, GRO/GSO/TSO, txqueuelen (через ethtool, безопасно).
- **MSS clamp** — через nftables, против PMTU-блэкхолов на туннелях.
- **zram-swap** — анти-OOM на TIER 1/2 (1–2 GB).
- **Лимиты** — `nofile`/`nproc` до 1M, journald cap, THP off, CPU governor=performance.
- **IPv6 off** — через sysctl, безопасно для активной SSH-сессии (не рвёт коннект посреди прогона).
- **Диагностика** — read-only отчёт о здоровье ноды + опциональное авто-исправление.

---

## Поддерживаемые ОС

| ОС | Статус |
|----|--------|
| Debian 12 (bookworm), 13 (trixie) | ✅ |
| Ubuntu 24.04+ (noble/plucky/…) | ✅ |
| **Ubuntu 22.04 (jammy), 20.04 (focal)** | ❌ **не поддерживается** |

> Ubuntu 22.04/20.04 исключены осознанно: XanMod не публикует для них ядра (404 на `deb.xanmod.org`). Скрипт это проверяет в pre-flight и выходит рано с понятным сообщением, ничего не ломая.

Только `x86_64`. На контейнерах (OpenVZ/LXC) установка ядра автоматически пропускается — они делят ядро хоста.

---

## Установка

Интерактивное меню (TUI):

```bash
curl -fsSL https://raw.githubusercontent.com/SpofyJet/node/main/vpn-node-setup.sh | sudo bash
```

Сразу применить оптимизацию без меню:

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/SpofyJet/node/main/vpn-node-setup.sh) --optimize
```

> После установки ядра нужен **reboot** — без него BBRv3 не активируется. Проверка: `uname -r` содержит `xanmod`.

---

## Режимы

| Команда | Назначение |
|---------|------------|
| `--optimize` | Применить оптимизацию (ядро + sysctl + conntrack + qdisc + RPS + NIC + лимиты). |
| `--diagnose` | Read-only отчёт о здоровье ноды. |
| `--diagnose-quick` | Быстрая диагностика. |
| `--diagnose-apply` | Диагностика + применить найденные безопасные фиксы. |
| `--diagnose-no-net` | Диагностика без сетевых проб. |
| `--diagnose-verbose` | Подробный вывод. |
| `--upgrade` | Обновить скрипт до свежей версии (snapshot + поддержка отката). |
| `--rollback` | Откатиться к предыдущей версии после неудачного `--upgrade`. |
| `--check` | Проверить, есть ли новая версия в репозитории. |
| `--diff` | Показать diff текущей версии с репозиторием. |
| `--dry-run` / `-n` | Прогон без изменений (показать, что было бы сделано). |
| `--version` / `-V` | Версия скрипта. |

После первого `--optimize` скрипт копирует себя в `/var/lib/vpn-node-builder/installed.sh` — апгрейд/откат запускаются оттуда:

```bash
sudo bash /var/lib/vpn-node-builder/installed.sh --upgrade
sudo bash /var/lib/vpn-node-builder/installed.sh --rollback
```

---

## Этапы оптимизации

1. Проверки безопасности
2. Очистка системы
3. Анализ CPU (psABI-уровень для выбора сборки XanMod)
4. Установка ядра XanMod LTS + настройка GRUB (старое ядро как fallback, валидация NIC-драйвера)
5. Отключение IPv6 (sysctl, SSH-safe)
6. Conntrack (tier-aware: `max` + `hashsize`)
7. Sysctl-профили (tier-aware буферы/udp_mem)
   - 7.4 zram-swap (TIER 1/2)
   - 7.5 QDISC (mq+fq / fq)
   - 7.6 RPS
   - 7.7 NIC-бусты (ethtool / GRO / XPS / ring buffers)
   - 7.8 MSS clamp (nftables)

Плюс лимиты `nofile`/`nproc`, journald cap, THP off, CPU governor.

---

## Tier-профили (по RAM)

| Tier | RAM | Ориентир по юзерам | Ключевое |
|------|-----|--------------------|----------|
| **TIER 1** | ≤ 1.2 GB | ~200 | минимальные буферы, zram-swap, `overcommit=1` |
| **TIER 2** | ≤ 2.5 GB | ~700 | `rmem/wmem_default` 2 MB, zram-swap |
| **TIER 3** | ≤ 8.5 GB | ~3000 | буферы 8 MB, `conntrack_max` крупнее |
| **TIER 4** | > 8.5 GB | ~6000 | буферы 8 MB, `conntrack_max` 2M |

UDP-буферы (`udp_rmem_min`/`udp_wmem_min`) подняты на всех tier под quic-go/Hysteria2.

---

## Проверка подписи (опционально)

По умолчанию выключена. Можно требовать подпись скрипта при `--upgrade`:

| Переменная | Назначение |
|------------|------------|
| `SETUP_REQUIRE_SIG=1` | Требовать валидную подпись (`.minisig` или `.asc`). |
| `SETUP_MINISIGN_PUBKEY=...` | Публичный ключ minisign. |
| `SETUP_SIG_FINGERPRINT=...` | Отпечаток GPG-ключа. |
| `XANMOD_GPG_KEY_ID=...` | Ключ репозитория XanMod (по умолч. `86F7D09EE734E623`). |

---

## ENV-флаги

| Переменная | По умолч. | Что |
|------------|-----------|-----|
| `SKIP_KERNEL_INSTALL` / `SETUP_NO_KERNEL_REPLACE` | `0` | Пропустить установку ядра XanMod. |
| `SETUP_NO_REBOOT` | `0` | Не предлагать reboot в конце. |
| `SETUP_DISABLE_UNATTENDED` | `1` | Отключить авто-апдейты (`0` — оставить включёнными). |
| `SETUP_NO_ZRAM` | `0` | Не настраивать zram-swap. |
| `SETUP_NO_REMNANODE_LOGROTATE` | `0` | Не трогать logrotate remnanode. |
| `DISABLE_TFO` | `0` | Отключить TCP Fast Open. |
| `DRY_RUN` | `0` | Прогон без изменений (= `--dry-run`). |
| `SCRIPT_REPO_URL` | *(репо)* | Источник для `--upgrade`/`--check`/`--diff`. |

---

## Файлы на диске

Скрипт владеет только своими файлами и не флашит чужие конфиги:

```
/etc/sysctl.d/80-vpn-node-tuning.conf       # основной профиль тюнинга
/etc/sysctl.d/99-conntrack.conf             # tier-aware conntrack
/etc/sysctl.d/99-disable-ipv6.conf          # IPv6 off (если включено)
/etc/security/limits.d/xray-limits.conf     # nofile/nproc
/etc/systemd/system.conf.d/limits.conf      # DefaultLimit* для сервисов
/etc/systemd/journald.conf.d/size-limit.conf
/etc/systemd/system/mss-clamp.service
/etc/systemd/system/nic-tuning.service
/etc/systemd/system/rps-tuning.service
/etc/systemd/system/vpn-zram.service
/etc/modules-load.d/conntrack.conf
/etc/default/grub                           # pin/​сброс default-ядра
/var/lib/vpn-node-builder/                   # installed.sh + snapshots для отката
```

Перед записью старые конфликтующие sysctl-файлы снимаются в `/var/lib/vpn-node-builder/snapshots/` (можно откатить).

---

## После установки

```bash
uname -r                                   # должно содержать xanmod
sysctl net.ipv4.tcp_congestion_control     # bbr (= BBRv3 под XanMod)
sudo bash /var/lib/vpn-node-builder/installed.sh --diagnose
```

---

## Лицензия

MIT. Гарантий нет — это инфраструктурный скрипт, читай перед запуском на проде.
