# vpn-node-setup

Bash-скрипт оптимизации VPN-нод (Xray / Reality / Hysteria2 / sing-box / Remnawave / Marzban). Целевые ОС: Debian 12/13, Ubuntu 22.04/24.04.

Стек: **XanMod LTS kernel + BBRv3 + nftables + sysctl tuning + NIC бусты**.

## Возможности

- **XanMod LTS kernel** с BBRv3 (auto-detect x86-64-v1/v2/v3 уровня CPU)
  - Idempotency: если LTS уже установлен — шаг пропускается
  - Detection ранее установленного MAIN-ядра — параллельная установка LTS + warning оператору
- **TCP-стек**: BBR congestion control, fq qdisc, `tcp_notsent_lowat=131072` (anti-bufferbloat)
- **Conntrack**: `nf_conntrack_max=262144`, hashsize=65536, TCP timeouts оптимизированы под Xray
  - UDP timeouts намеренно НЕ выставляются — управляются shieldnode (если установлен)
- **TIER-aware sysctl** по объёму RAM (1GB / 2GB / 4-8GB / 8GB+):
  - TIER 1 (1GB): rmem_max 4MB, overcommit_memory=1, swappiness=20
  - TIER 2 (2GB): rmem_max 16MB
  - TIER 3 (4-8GB): rmem_max 16MB, tcp_adv_win_scale=-2
  - TIER 4 (8GB+): rmem_max 33MB, netdev_max_backlog=32768
- **IPv6 disable** через GRUB cmdline + sysctl fallback (для VPN-нод обычно не нужен)
- **Qdisc multi-queue (mq+fq)** для multi-CPU нод (single-queue → fq fallback)
- **RPS** (Receive Packet Steering) с авто-detect: skip если HW multi-queue ≥ CPUs
- **NIC бусты**: ethtool offloads (GRO/GSO/TSO), GRO flush 50µs + napi_defer, XPS, ring buffers max
- **txqueuelen=10000** для основного интерфейса (защита от TX-drops при пиках на virtio)
- **IRQ affinity** round-robin по CPU (+ irqbalance integration через BANNED_INTERRUPTS)
- **Pre-flight checks**: dpkg integrity, GRUB_TIMEOUT, VMware/Hyper-V detect, fstab дубли, netplan валидация
- **Self-upgrade flow**: команды `--check` / `--upgrade` / `--rollback` / `--diff` (см. ниже)
- **--dry-run** mode: пробежать все pre-flight без apt install ядра

## Установка

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/abcproxy70-ops/node/main/vpn-node-setup.sh)
```

Скрипт сам:
- определит дистрибутив (Debian/Ubuntu) и CPU level
- установит XanMod LTS kernel (если ещё нет)
- настроит sysctl, qdisc, conntrack, лимиты
- создаст `rps-tuning.service` и `nic-tuning.service` (persistent через reboot)
- сохранит снимок настроек в `/root/vpn-node-builder-backup-YYYYMMDD-HHMMSS/`

После завершения — обязательный `reboot` для активации нового ядра.

## Self-upgrade

После первой установки скрипт сохраняется в `/var/lib/vpn-node-builder/installed.sh` и доступен через локальный путь:

```bash
# Проверить новую версию на github (без sudo)
sudo /var/lib/vpn-node-builder/installed.sh --check

# Показать diff между текущей и upstream версией
/var/lib/vpn-node-builder/installed.sh --diff

# Безопасный upgrade: sanity-check + snapshot настроек + запуск новой версии
sudo /var/lib/vpn-node-builder/installed.sh --upgrade

# Откатиться к предыдущей версии (если что-то пошло не так)
sudo /var/lib/vpn-node-builder/installed.sh --rollback

# Версия скрипта
/var/lib/vpn-node-builder/installed.sh --version
```

`--upgrade` делает 5 проверок перед запуском: непустой файл, shebang, не HTML (cloudflare-error-page), version marker, `bash -n` syntax. И snapshot текущих `/etc/sysctl.d/`, `/etc/security/limits.d/`, `rps-tuning.service`, `nic-tuning.service` в `/var/lib/vpn-node-builder/snapshots/` — для возможного `--rollback`.

## Конфигурация

Скрипт работает без конфиг-файла — всё авто-detect'ится.

Repo URL для self-upgrade переопределяется через env:

```bash
SCRIPT_REPO_URL="https://my-fork/vpn-node-setup.sh" sudo /var/lib/vpn-node-builder/installed.sh --check
```

## Параметры запуска

```
sudo bash vpn-node-setup.sh [OPTIONS]

  --dry-run, -n    Показать что будет, без apt install ядра
  --version, -V    Версия скрипта
  --check          Проверить новую версию на github
  --diff           Diff между установленной и upstream версией (использует $PAGER)
  --upgrade        Безопасный upgrade с sanity-check + snapshot
  --rollback       Откатиться к предыдущей версии
  --help, -h       Показать help
```

## Совместимость с shieldnode

Скрипт спроектирован совместимо с [shieldnode](https://github.com/abcproxy70-ops/shield) DDoS-защитой:
- UDP conntrack timeouts (`nf_conntrack_udp_timeout`, `_stream`) **НЕ** перетираются — отдаются shieldnode (180/300 для VPN keepalive)
- TIER 1/2 rmem_max подняты под Hysteria2 BBR throughput (4MB / 16MB)
- IPv6 отключение делается через GRUB cmdline + sysctl — shieldnode видит это и не пытается ставить IPv6 правила

## Проверка после reboot

```bash
uname -r                                      # должно содержать 'lts' и 'xanmod'
sysctl net.ipv4.tcp_congestion_control        # bbr
sysctl net.core.default_qdisc                 # fq
sysctl net.netfilter.nf_conntrack_max         # 262144
sysctl net.core.rmem_max                      # для 1GB: 4194304, для 2GB: 16777216
ip link show $(ip route|awk '/default/{print $5;exit}') | grep qlen   # qlen 10000
systemctl status rps-tuning.service nic-tuning.service --no-pager     # active (exited)
```

## Версии

- **v4.13** — CRITICAL FIXES для совместимости с shieldnode + Hysteria2:
  - **CRIT-1**: убраны `nf_conntrack_udp_timeout=120` / `_stream=180` из `99-conntrack.conf` и live sysctl. Раньше setup перетирал shieldnode'овские 180/300 (лексикографический порядок sysctl-d 99 > 90), Hysteria2 keepalive рвался у мобильных
  - **CRIT-2**: TIER 1 rmem_max 2MB → 4MB, TIER 2 8MB → 16MB. Hysteria2 (UDP+BBR) требует ≥ 4-16MB чтобы выйти на потолок throughput
  - **Add**: `vm.overcommit_memory=1` на TIER 1 — защита от OOM на 1GB ноде
  - **Add**: `txqueuelen=10000` для основного интерфейса (default 1000 — узкое горлышко на virtio при пиках)
  - **Add**: SELF-UPGRADE FLOW — `--check` / `--upgrade` / `--rollback` / `--diff` с sanity-check (5 проверок) и snapshot настроек
- **v4.12** — переход с XanMod MAIN на LTS branch (production-ready kernel, меньше регрессий, поддержка x86-64-v1, idempotency, `--dry-run` флаг)
- **v4.11** — защита от dpkg-lock конфликта с unattended-upgrades (детектит другой apt-процесс, ждёт до 5 мин)
- **v4.10** — РАДИКАЛЬНОЕ УПРОЩЕНИЕ после реальных поломок на проде:
  - Удалена pre-flight защита по сети, IPv6 disable через GRUB cmdline (трогало boot), детект cloud-провайдера, удаление cloud-init/snapd
  - Оставлены только safe-оптимизации: kernel + BBR + sysctl + qdisc + RPS + NIC бусты + ulimit + journald
- **v4.9** — фикс reboot-проблем на KVM с virtio_net: `systemd-networkd-wait-online`, дедуп `/etc/fstab`, нейтрализация `/etc/netplan/00-installer-config.yaml`, отключение `/etc/network/interfaces` при наличии netplan
- **v4.8** — полировка после реальных запусков: `systemd-networkd-wait-online` override, точная проверка ipv6 модуля в post-reboot инструкциях, проверка `systemctl --failed`
- **v4.7** — расширенные защиты от поломок ребута: dpkg integrity check, GRUB_TIMEOUT минимум 2 сек, VMware/Hyper-V предупреждение, UFW info, post-install validation НОВОГО ядра ДО `update-grub`, `nf_conntrack` autoload через `modules-load.d`
- **v4.6** — pre-flight проверки сети и fstab: netplan валидация, отключение `networking.service` (ifupdown) при конфликте, удаление дублей `/etc/fstab`, очистка zombie cloud-init состояния
- **v4.5** — убран GPG fingerprint verification (XanMod ротирует ключи)
- **v4.4** — IPv6 disable через GRUB cmdline (`ipv6.disable=1`) с автоматическим бэкапом `/etc/default/grub`, парсинг `GRUB_CMDLINE_LINUX_DEFAULT`, gai.conf precedence для IPv4
- **v4.3** — IRQ affinity round-robin (критично для 10G и multi-queue NIC), irqbalance integration через `IRQBALANCE_BANNED_INTERRUPTS`, `fs.inotify.max_user_watches=524288`
- **v4.2** — safety fixes: GPG fingerprint verification XanMod, GRUB обновляется только если grub-pc/grub-efi установлен (не systemd-boot), `sysctl --system` заменён на явный список файлов, journald restart через reload, ring buffers только при 4x+ выгоде, `swappiness=10` во все профили, `vm.min_free_kbytes`, `tcp_timestamps` явно зафиксирован
- **v4.1** — базовые бусты: `notsent_lowat`, GRO flush, ethtool offloads, ring buffers, XPS, cloud-init detection (Hetzner/DO/Vultr/AWS), убран `tcp_fastopen=3` (конфликт с Xray Reality), hashsize мягко (без лагов), qdisc через add/change вместо replace, hex-индексация mq для 16+ очередей

## Что НЕ делает скрипт (намеренно)

- Не устанавливает Xray / sing-box / Hysteria — это отдельная задача панели (Remnawave / Marzban / 3x-ui)
- Не настраивает SSH / firewall — это shieldnode / UFW
- Не трогает `/etc/network/interfaces` если активен netplan (с v4.9)
- Не удаляет cloud-init (с v4.10) — может зависеть SSH ключ Hetzner / DO
- Не агрессивный `netdev_budget=600` — может вызывать softirq starvation на 1-2 vCPU нодах (default 300 безопаснее)
- Не агрессивный `rmem_max=64MB` — может вызвать OOM на 1GB ноде (200 sockets × 64MB = 12GB worst-case)

## Лицензия

MIT — см. [LICENSE](LICENSE).
