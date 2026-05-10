# vpn-node-setup

Универсальный bash-скрипт для VPN-нод (Xray / Reality / Hysteria2 / sing-box / Remnawave / Marzban): **оптимизация + диагностика**. Целевые ОС: Debian 12/13, Ubuntu 22.04/24.04.

Стек: **XanMod LTS kernel + BBRv3 + nftables (MSS clamp) + sysctl tuning + NIC бусты + диагностика через node-diagnostic**.

## Что нового в v5.0

- **TUI меню при запуске**: выбор между оптимизацией и диагностикой
- **MSS clamp через nftables** — решает проблему "потолка ~580-630 пользователей на ноду" (клиенты с нестандартным PMTU не могли установить TCP)
- **Tier-aware conntrack_max** — на больших нодах (8GB+) поднят до 1M записей
- **Диагностика через [node-diagnostic](https://github.com/Case211/node-diagnostic) от Case211** — 23 проверки → Score 0-100 (скачивается с github)
- **Совместимость с [shieldnode](https://github.com/abcproxy70-ops/shield)** проверена: отдельная таблица nft, не пересекается

## Возможности

- **XanMod LTS kernel** с BBRv3 (auto-detect x86-64-v1/v2/v3 уровня CPU)
- **TCP-стек**: BBR congestion control, fq qdisc, `tcp_notsent_lowat=131072`
- **MSS clamp** через nftables (priority -150 на forward+output) — для FORWARD-трафика клиентов с PMTU<1500
- **Conntrack tier-aware** по объёму RAM:
  - TIER 1 (≤1.2GB): max=262144, hashsize=65536
  - TIER 2 (≤2.5GB): max=524288, hashsize=131072
  - TIER 3 (≤8.5GB): max=1048576, hashsize=262144
  - TIER 4 (>8.5GB): max=1048576, hashsize=262144
- **TIER-aware sysctl** по RAM (rmem_max от 4MB до 32MB по тиру)
- **IPv6 disable** через GRUB cmdline + sysctl fallback
- **Qdisc multi-queue (mq+fq)** для multi-CPU нод
- **RPS** с авто-detect: skip если HW multi-queue ≥ CPUs
- **NIC бусты**: ethtool offloads, GRO flush, XPS, ring buffers max, txqueuelen=10000
- **IRQ affinity** round-robin + irqbalance integration
- **Pre-flight checks**: dpkg, GRUB_TIMEOUT, VMware/Hyper-V, fstab, netplan
- **Self-upgrade**: `--check` / `--upgrade` / `--rollback` / `--diff`
- **Диагностика** через скачивание свежего `node-diagnostic.sh` (4 sanity-check'а)
- **--dry-run** mode

## Установка

### С TUI меню (рекомендуется)

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/abcproxy70-ops/node/main/vpn-node-setup.sh)
```

### Прямой запуск (CI / ansible)

```bash
sudo bash vpn-node-setup.sh --optimize    # оптимизация без меню
sudo bash vpn-node-setup.sh --diagnose    # диагностика без меню
```

### Что делает скрипт при оптимизации

- Определит дистрибутив и CPU level
- Установит XanMod LTS kernel (если ещё нет)
- Установит nftables (если отсутствует)
- Настроит sysctl (tier-aware), qdisc, conntrack, MSS clamp, лимиты
- Создаст `rps-tuning.service`, `nic-tuning.service`, `mss-clamp.service`
- Снимок настроек в `/root/vpn-node-builder-backup-YYYYMMDD-HHMMSS/`

После завершения — обязательный `reboot` для активации нового ядра.

## Self-upgrade

```bash
sudo /var/lib/vpn-node-builder/installed.sh --check       # проверить новую версию
sudo /var/lib/vpn-node-builder/installed.sh --upgrade     # безопасный upgrade
sudo /var/lib/vpn-node-builder/installed.sh --rollback    # откат
sudo /var/lib/vpn-node-builder/installed.sh --diagnose    # диагностика
```

`--upgrade` делает 5 проверок перед запуском: непустой, shebang, не HTML, version marker, `bash -n`. Snapshot настроек сохраняется в `/var/lib/vpn-node-builder/snapshots/`.

## Параметры запуска

```
sudo bash vpn-node-setup.sh [OPTIONS]

  (без аргументов, TTY)     TUI меню
  (без аргументов, non-TTY) Оптимизация (backward compat для CI)

  --optimize       Прямая оптимизация без TUI
  --diagnose       Прямая диагностика (node-diagnostic от Case211)
  --dry-run, -n    Показать что будет, без apt install ядра
  --version, -V    Версия скрипта
  --check          Проверить новую версию на github
  --diff           Diff между установленной и upstream
  --upgrade        Безопасный upgrade с sanity-check + snapshot
  --rollback       Откатиться к предыдущей версии
  --help, -h       Help
```

## Совместимость с shieldnode

Скрипт спроектирован совместимо с [shieldnode](https://github.com/abcproxy70-ops/shield):

- **UDP conntrack timeouts** не перетираются — отдаются shieldnode (180/300 для VPN keepalive)
- **MSS clamp** в отдельной nft-таблице `inet vpn_node_mss_clamp` — не пересекается с shieldnode'овскими (`inet ddos_protect`, `inet filter`, `ip/ip6 crowdsec`)
- Forward priority -150 безопасен: shieldnode на forward использует -50 или filter=0, не -150
- TIER 1/2 rmem_max подняты под Hysteria2 BBR throughput
- IPv6 отключение через GRUB cmdline — shieldnode видит и не ставит IPv6 правила

## Что НЕ делает скрипт (намеренно)

- Не устанавливает Xray / sing-box / Hysteria — задача панели
- Не настраивает SSH / firewall — задача shieldnode / UFW
- Не трогает netplan и `/etc/network/interfaces` без необходимости
- Не удаляет cloud-init
- Не использует агрессивные настройки от node-diagnostic:
  - `tcp_fastopen=3` (сломает Xray Reality)
  - `somaxconn=8192` / `tcp_max_syn_backlog=8192` (деградация в 8 раз vs наши 65535)
  - `rmem_max=64MB` (опасно для 1GB ноды)
  - `default_qdisc=cake` (опционально через TUI меню для проблемных пирингов)

## Проверка после reboot

```bash
uname -r                                                              # 'lts' и 'xanmod'
sysctl net.ipv4.tcp_congestion_control                                # bbr
sysctl net.core.default_qdisc                                         # fq
sysctl net.netfilter.nf_conntrack_max                                 # tier-aware
sysctl net.core.rmem_max                                              # tier-aware
ip link show $(ip route|awk '/default/{print $5;exit}') | grep qlen   # qlen 10000
nft list table inet vpn_node_mss_clamp                                # MSS clamp правила
systemctl status rps-tuning.service nic-tuning.service mss-clamp.service --no-pager
```

## Версии

- **v5.0.2** — hotfix для копирования команды после диагностики:
  - **Bugfix**: после `--diagnose` команда `sudo bash <(curl ...) --optimize` обрезалась в терминалах/Telegram (длинная) и работала только в bash. Клиенты копировали кусок → "файл не найден"
  - **Fix**: `installed.sh` теперь сохраняется **рано** (до диагностики/TUI), после первого запуска всегда доступен короткий путь `/var/lib/vpn-node-builder/installed.sh`. Сообщение после diagnose показывает короткую команду как основную
- **v5.0.1** — hotfix для конфликтов с node-diagnostic:
  - **Bugfix**: detect + cleanup `/etc/sysctl.d/99-vpn-tuning.conf` от node-diagnostic с `-a` (содержит опасные `tcp_fastopen=3`, `somaxconn=8192`). Backup в `/var/lib/vpn-node-builder/snapshots/sysctl-cleanup-*/`
  - **Change**: КОНСОЛИДАЦИЯ — все наши sysctl-настройки теперь в одном файле `/etc/sysctl.d/99-vpn-node-tuning.conf` (раньше было два: `99-conntrack.conf` + `99-xray-tuning.conf`). Старые файлы удаляются автоматически
  - **Bugfix**: косметика финального отчёта (hardcoded "262144" → динамический `$CONNTRACK_MAX`)
- **v5.0** — universal script (оптимизация + диагностика):
  - **Add**: TUI меню при запуске (UTF-8 + ASCII fallback)
  - **Add**: ШАГ 7.8 MSS clamp через nftables — решает "потолок 580-630 юзеров"
  - **Change**: ШАГ 6 conntrack tier-aware (262144 → 1048576 для больших нод)
  - **Add**: `--optimize` / `--diagnose` CLI флаги
  - **Add**: режим диагностики через скачивание node-diagnostic от Case211
  - **Add**: pre-flight install nftables
- **v4.13** — CRIT fixes для совместимости с shieldnode + Hysteria2:
  - убраны UDP conntrack timeouts (отдаются shieldnode)
  - TIER 1 rmem_max 2MB → 4MB, TIER 2 8MB → 16MB
  - `vm.overcommit_memory=1` на TIER 1, `txqueuelen=10000`
  - SELF-UPGRADE FLOW (`--check`, `--upgrade`, `--rollback`, `--diff`)
- **v4.12** — переход с XanMod MAIN на LTS branch
- **v4.11** — защита от dpkg-lock с unattended-upgrades
- **v4.10** — упрощение после реальных поломок
- **v4.9** — фикс reboot-проблем на KVM с virtio_net
- **v4.8** — полировка после запусков
- **v4.7** — pre-flight защита от поломок ребута
- **v4.6** — pre-flight проверки сети и fstab
- **v4.5** — убран GPG fingerprint verification
- **v4.4** — IPv6 disable через GRUB cmdline
- **v4.3** — IRQ affinity + irqbalance
- **v4.2** — safety fixes
- **v4.1** — базовые бусты (notsent_lowat, GRO, ethtool, XPS)

## Лицензия

MIT — см. [LICENSE](LICENSE).
