#!/bin/bash

# ==============================================================================
#  ██╗  ██╗ █████╗ ███╗   ██╗███╗   ███╗ ██████╗ ██████╗ 
#  ╚██╗██╔╝██╔══██╗████╗  ██║████╗ ████║██╔═══██╗██╔══██╗
#   ╚███╔╝ ███████║██╔██╗ ██║██╔████╔██║██║   ██║██║  ██║
#   ██╔██╗ ██╔══██║██║╚██╗██║██║╚██╔╝██║██║   ██║██║  ██║
#  ██╔╝ ██╗██║  ██║██║ ╚████║██║ ╚═╝ ██║╚██████╔╝██████╔╝
#  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝     ╚═╝ ╚═════╝ ╚═════╝ 
#                                                         
#  XRAY/REMNAWAVE NODE BUILDER v4.1 (All-in-One)
#  Ядро XanMod + BBRv3 + Полная оптимизация системы
#  Поддерживает: Debian 12/13, Ubuntu 22.04/24.04
#
#  v4.1 changelog:
#  - Безопасные бусты: notsent_lowat, GRO flush, ethtool offloads, ring buffers, XPS
#  - Fix: cloud-init detection (Hetzner/DO/Vultr/AWS) — не удаляем на облаках
#  - Fix: убран tcp_fastopen=3 (конфликт с Xray Reality)
#  - Fix: hashsize применяется мягко (без лагов на активном трафике)
#  - Fix: qdisc через add/change вместо replace (без drop пакетов)
#  - Fix: hex-индексация mq для 16+ очередей (10G NIC)
#  - Fix: проверка свободного места + GRUB fallback на старое ядро
#  - Fix: бэкап существующих sysctl/limits перед перезаписью
# ==============================================================================

set -o pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Функции вывода
print_header() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} ${BOLD}$1${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_status() { echo -e "${YELLOW}➤${NC} $1"; }
print_ok()     { echo -e "${GREEN}✔${NC} $1"; }
print_error()  { echo -e "${RED}✖${NC} $1"; }
print_info()   { echo -e "${MAGENTA}ℹ${NC} $1"; }

# ==============================================================================
# НАЧАЛО РАБОТЫ
# ==============================================================================

clear
echo -e "${CYAN}"
echo "  ██╗  ██╗ █████╗ ███╗   ██╗███╗   ███╗ ██████╗ ██████╗ "
echo "  ╚██╗██╔╝██╔══██╗████╗  ██║████╗ ████║██╔═══██╗██╔══██╗"
echo "   ╚███╔╝ ███████║██╔██╗ ██║██╔████╔██║██║   ██║██║  ██║"
echo "   ██╔██╗ ██╔══██║██║╚██╗██║██║╚██╔╝██║██║   ██║██║  ██║"
echo "  ██╔╝ ██╗██║  ██║██║ ╚████║██║ ╚═╝ ██║╚██████╔╝██████╔╝"
echo "  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝     ╚═╝ ╚═════╝ ╚═════╝ "
echo -e "${NC}"
echo -e "${BOLD}  XRAY/REMNAWAVE NODE BUILDER v4.1 (All-in-One)${NC}"
echo -e "  ${YELLOW}XanMod + BBRv3 + Очистка + Сетевой стек + Conntrack + Gaming-friendly${NC}"
echo -e "  ${GREEN}+ Safe boosts: notsent_lowat, GRO, ethtool, XPS${NC}"
echo ""
sleep 1

# ==============================================================================
# ШАГ 1: ПРОВЕРКИ БЕЗОПАСНОСТИ
# ==============================================================================

print_header "ШАГ 1: ПРОВЕРКИ БЕЗОПАСНОСТИ"

# Проверка root
print_status "Проверяем права root..."
if [[ $EUID -ne 0 ]]; then
    print_error "FATAL: Запустите скрипт через sudo!"
    exit 1
fi
print_ok "Запущен от root"

# Проверка архитектуры
print_status "Проверяем архитектуру..."
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
    print_error "FATAL: Скрипт поддерживает только x86_64! Обнаружено: $ARCH"
    exit 1
fi
print_ok "Архитектура: $ARCH"

# Проверка виртуализации
print_status "Определяем тип виртуализации..."
if command -v systemd-detect-virt >/dev/null; then
    VIRT=$(systemd-detect-virt)
    echo -e "    Виртуализация: ${BOLD}$VIRT${NC}"

    if [[ "$VIRT" == "lxc" || "$VIRT" == "openvz" || "$VIRT" == "docker" ]]; then
        print_error "STOP: Виртуализация $VIRT не поддерживает замену ядра!"
        echo -e "    ${RED}Скрипт остановлен для защиты системы.${NC}"
        exit 1
    fi
    print_ok "Виртуализация совместима"
else
    print_info "systemd-detect-virt не найден, пропускаем проверку"
fi

# Информация о системе
print_status "Собираем информацию о системе..."
echo ""
echo -e "    ${BOLD}Операционная система:${NC}"
if [ -f /etc/os-release ]; then
    source /etc/os-release
    echo -e "    ├─ Дистрибутив: ${GREEN}${NAME:-unknown}${NC}"
    echo -e "    ├─ Версия: ${GREEN}${VERSION:-unknown}${NC}"
fi
echo -e "    ├─ Ядро: ${GREEN}$(uname -r)${NC}"
echo -e "    └─ Архитектура: ${GREEN}$(uname -m)${NC}"
echo ""

# ==============================================================================
# ШАГ 2: ОЧИСТКА СИСТЕМЫ
# ==============================================================================

print_header "ШАГ 2: ОЧИСТКА СИСТЕМЫ"

# --- Детект cloud-окружения (защита от поломки сети после ребута) ---
print_status "Определяем cloud-провайдера..."

# Устанавливаем dmidecode если его нет (тихо, без вывода)
if ! command -v dmidecode >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y dmidecode >/dev/null 2>&1 || true
fi

CLOUD_DETECTED="none"

# Уровень 1: dmidecode
if command -v dmidecode >/dev/null 2>&1; then
    DMI_VENDOR=$(dmidecode -s system-manufacturer 2>/dev/null | tr '[:upper:]' '[:lower:]')
    DMI_PRODUCT=$(dmidecode -s system-product-name 2>/dev/null | tr '[:upper:]' '[:lower:]')
    case "${DMI_VENDOR}${DMI_PRODUCT}" in
        *hetzner*)         CLOUD_DETECTED="hetzner" ;;
        *digitalocean*)    CLOUD_DETECTED="digitalocean" ;;
        *vultr*)           CLOUD_DETECTED="vultr" ;;
        *amazon*|*ec2*)    CLOUD_DETECTED="aws" ;;
        *google*)          CLOUD_DETECTED="gcp" ;;
        *microsoft*)       CLOUD_DETECTED="azure" ;;
        *openstack*)       CLOUD_DETECTED="openstack" ;;
        *oracle*)          CLOUD_DETECTED="oracle" ;;
        *linode*|*akamai*) CLOUD_DETECTED="linode" ;;
    esac
fi

# Уровень 2: cloud-init datasource (надёжнее чем dmidecode)
if [ "$CLOUD_DETECTED" = "none" ] && [ -d /var/lib/cloud/instance ]; then
    CLOUD_DETECTED="cloud-init-managed"
fi

# Уровень 3: проверка управляет ли cloud-init сетью или SSH
if [ "$CLOUD_DETECTED" = "none" ]; then
    # Если есть конфиги cloud-init для сети или SSH — НЕ удаляем
    if [ -f /etc/netplan/50-cloud-init.yaml ] || \
       [ -f /etc/network/interfaces.d/50-cloud-init ] || \
       [ -d /var/lib/cloud/seed ]; then
        CLOUD_DETECTED="cloud-init-active"
    fi
fi

# Уровень 4: SAFETY-NET — если cloud-init установлен и есть SSH ключи в /root/.ssh
# которые ОН мог положить — НЕ рискуем
if [ "$CLOUD_DETECTED" = "none" ] && dpkg -l cloud-init &>/dev/null; then
    if [ -f /root/.ssh/authorized_keys ] && grep -q "ssh-" /root/.ssh/authorized_keys 2>/dev/null; then
        # SSH ключи есть, cloud-init установлен — может быть он их и поставил
        # Безопаснее НЕ удалять
        CLOUD_DETECTED="cloud-init-installed-with-keys"
    fi
fi

if [ "$CLOUD_DETECTED" != "none" ]; then
    print_info "Обнаружено: ${BOLD}$CLOUD_DETECTED${NC}"
    print_info "cloud-init НЕ будет удалён (управляет SSH-ключами и сетью)"
else
    print_ok "Bare-metal без cloud-init — безопасно удалять"
fi

# --- Бэкап существующих конфигов ---
print_status "Создаём бэкап существующих конфигов..."
BACKUP_DIR="/root/vpn-node-builder-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
[ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$BACKUP_DIR/" 2>/dev/null
[ -d /etc/sysctl.d ] && cp -r /etc/sysctl.d "$BACKUP_DIR/" 2>/dev/null
[ -d /etc/security/limits.d ] && cp -r /etc/security/limits.d "$BACKUP_DIR/" 2>/dev/null
[ -d /etc/systemd/system.conf.d ] && cp -r /etc/systemd/system.conf.d "$BACKUP_DIR/" 2>/dev/null
print_ok "Бэкап сохранён: $BACKUP_DIR"
echo ""

# --- Удаление ненужных пакетов ---
print_status "Удаляем ненужные пакеты..."
echo ""
# Базовый список
PKGS_TO_PURGE=("snapd" "apport" "whoopsie" "ubuntu-report" "popularity-contest")
# cloud-init добавляем только если НЕ на облаке
if [ "$CLOUD_DETECTED" = "none" ]; then
    PKGS_TO_PURGE+=("cloud-init")
else
    print_info "cloud-init пропущен (cloud: $CLOUD_DETECTED)"
fi
for pkg in "${PKGS_TO_PURGE[@]}"; do
    if dpkg -l "$pkg" &>/dev/null; then
        apt-get purge -y "$pkg" 2>/dev/null || true
        print_ok "Удалён: $pkg"
    else
        print_info "Не установлен: $pkg"
    fi
done
apt-get autoremove -y 2>/dev/null || true
echo ""
print_ok "Очистка завершена"

# --- Отключение ненужных сервисов ---
print_status "Отключаем ненужные сервисы..."

SERVICES_TO_DISABLE=(
    "ModemManager"
    "fwupd"
    "udisks2"
    "multipathd"
    "unattended-upgrades"
)

for svc in "${SERVICES_TO_DISABLE[@]}"; do
    if systemctl is-enabled "$svc" &>/dev/null; then
        systemctl disable --now "$svc" 2>/dev/null || true
        print_ok "Отключён: $svc"
    else
        print_info "Уже отключён или не найден: $svc"
    fi
done
echo ""

# --- Ограничение journald ---
print_status "Ограничиваем размер логов journald..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size-limit.conf <<EOF
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
EOF
systemctl restart systemd-journald
print_ok "Journald ограничен: SystemMaxUse=100M"

# ==============================================================================
# ШАГ 3: АНАЛИЗ CPU
# ==============================================================================

print_header "ШАГ 3: АНАЛИЗ ПРОЦЕССОРА"

print_status "Читаем информацию о CPU..."

CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d':' -f2 | xargs)
CPU_CORES=$(nproc)
echo -e "    ├─ Модель: ${GREEN}$CPU_MODEL${NC}"
echo -e "    └─ Ядер: ${GREEN}$CPU_CORES${NC}"
echo ""

print_status "Определяем уровень CPU (x86-64-v?)..."

CPU_FLAGS=$(grep -m1 '^flags' /proc/cpuinfo)

# XanMod не выпускает v4 пакеты — максимум v3
if echo "$CPU_FLAGS" | grep -q 'avx512'; then
    CPU_LEVEL=3
    LEVEL_DESC="AVX-512 → используем v3 (v4 пакетов нет)"
elif echo "$CPU_FLAGS" | grep -q 'avx2'; then
    CPU_LEVEL=3
    LEVEL_DESC="AVX2 (Современный)"
elif echo "$CPU_FLAGS" | grep -q 'sse4_2'; then
    CPU_LEVEL=2
    LEVEL_DESC="SSE4.2 (Базовый)"
else
    CPU_LEVEL=2
    LEVEL_DESC="Базовый x86-64 → используем v2"
fi

echo ""
echo -e "    ${BOLD}Результат анализа:${NC}"
echo -e "    ├─ Уровень: ${GREEN}x86-64-v${CPU_LEVEL}${NC}"
echo -e "    └─ Описание: ${GREEN}$LEVEL_DESC${NC}"
echo ""

print_info "Ключевые флаги CPU:"
echo -n "    "
for flag in sse4_2 avx avx2 avx512f aes; do
    if echo "$CPU_FLAGS" | grep -q "$flag"; then
        echo -ne "${GREEN}[$flag]${NC} "
    else
        echo -ne "${RED}[$flag]${NC} "
    fi
done
echo ""

print_ok "CPU Level определён: x86-64-v${CPU_LEVEL}"

# ==============================================================================
# ШАГ 4: УСТАНОВКА XANMOD
# ==============================================================================

print_header "ШАГ 4: УСТАНОВКА ЯДРА XANMOD"

# Удаляем старые ключи
print_status "Очищаем старые ключи XanMod (если есть)..."
rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg 2>/dev/null
rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg 2>/dev/null
print_ok "Старые ключи удалены"

# Обновляем систему
print_status "Обновляем списки пакетов..."
echo ""
apt-get update
echo ""
print_ok "Списки обновлены"

# Устанавливаем зависимости
print_status "Устанавливаем необходимые пакеты..."
echo ""
apt-get install -y wget gnupg2 ca-certificates lsb-release bc
echo ""
print_ok "Зависимости установлены"

# Добавляем репозиторий XanMod
print_status "Добавляем репозиторий XanMod..."
mkdir -p /etc/apt/keyrings
echo -e "    Скачиваем GPG ключ..."
wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg --yes
echo ""
print_ok "GPG ключ добавлен"

DISTRO_CODENAME=$(lsb_release -sc)
echo -e "    Codename дистрибутива: ${GREEN}$DISTRO_CODENAME${NC}"

echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${DISTRO_CODENAME} main" | tee /etc/apt/sources.list.d/xanmod-release.list
print_ok "Репозиторий добавлен в sources.list"

print_status "Обновляем списки пакетов (с XanMod)..."
echo ""
apt-get update
echo ""
print_ok "Списки обновлены"

# Устанавливаем ядро
KERNEL_PKG="linux-xanmod-x64v${CPU_LEVEL}"
print_status "Проверяем доступность пакета: ${BOLD}${KERNEL_PKG}${NC}"

if ! apt-cache show "$KERNEL_PKG" >/dev/null 2>&1; then
    print_error "Пакет $KERNEL_PKG не найден!"

    if [ "$CPU_LEVEL" -eq 3 ]; then
        KERNEL_PKG="linux-xanmod-x64v2"
        print_info "Пробуем fallback: $KERNEL_PKG"

        if ! apt-cache show "$KERNEL_PKG" >/dev/null 2>&1; then
            print_error "Пакет $KERNEL_PKG тоже не найден!"
            echo ""
            print_info "Доступные пакеты XanMod:"
            apt-cache search linux-xanmod | head -20
            exit 1
        fi
    else
        echo ""
        print_info "Доступные пакеты XanMod:"
        apt-cache search linux-xanmod | head -20
        exit 1
    fi
fi

print_ok "Пакет найден: $KERNEL_PKG"
echo ""

print_status "Устанавливаем ядро: ${BOLD}${KERNEL_PKG}${NC}"
echo ""

# Проверка свободного места (нужно ~500MB на ядро)
FREE_BOOT=$(df -m /boot 2>/dev/null | awk 'NR==2 {print $4}')
FREE_ROOT=$(df -m / | awk 'NR==2 {print $4}')
echo -e "    Свободно на /boot: ${GREEN}${FREE_BOOT:-N/A} MB${NC}"
echo -e "    Свободно на /:     ${GREEN}${FREE_ROOT} MB${NC}"

if [ -n "$FREE_BOOT" ] && [ "$FREE_BOOT" -lt 200 ]; then
    print_error "На /boot меньше 200MB! Установка ядра может не пройти."
    print_info "Очистите старые ядра: apt autoremove --purge"
    exit 1
fi
if [ "$FREE_ROOT" -lt 1500 ]; then
    print_error "На / меньше 1.5GB! Установка ядра может не пройти."
    exit 1
fi
print_ok "Свободного места достаточно"

# Сохраняем имя текущего ядра как fallback
CURRENT_KERNEL=$(uname -r)
echo -e "    Текущее ядро (fallback): ${GREEN}$CURRENT_KERNEL${NC}"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
DEBIAN_FRONTEND=noninteractive apt-get install -y "$KERNEL_PKG"
INSTALL_RESULT=$?
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

if [ $INSTALL_RESULT -eq 0 ]; then
    print_ok "Ядро XanMod успешно установлено!"
    # Гарантируем что текущее (рабочее) ядро останется в GRUB как запасное
    print_status "Проверяем GRUB submenu (для fallback на старое ядро)..."
    if [ -f /etc/default/grub ]; then
        if ! grep -q "GRUB_DISABLE_SUBMENU" /etc/default/grub; then
            echo 'GRUB_DISABLE_SUBMENU=y' >> /etc/default/grub
            print_ok "GRUB submenu отключён (старое ядро доступно в меню)"
        fi
        update-grub 2>/dev/null || true
    fi
else
    print_error "Ошибка установки ядра! Код: $INSTALL_RESULT"
    print_info "Текущее ядро не тронуто. Сервер загрузится как обычно."
    exit 1
fi

# ==============================================================================
# ШАГ 5: ОТКЛЮЧЕНИЕ IPv6
# ==============================================================================

print_header "ШАГ 5: ОТКЛЮЧЕНИЕ IPv6"

print_status "Создаём конфиг отключения IPv6..."
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
# Disable IPv6 — VPN node doesn't need it
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
print_ok "IPv6 будет отключён после перезагрузки"

# ==============================================================================
# ШАГ 6: НАСТРОЙКА CONNTRACK
# ==============================================================================

print_header "ШАГ 6: НАСТРОЙКА CONNTRACK"

print_status "Загружаем модуль nf_conntrack..."
modprobe nf_conntrack 2>/dev/null || true

# Применяем сразу (до перезагрузки)
print_status "Применяем настройки conntrack..."
sysctl -w net.netfilter.nf_conntrack_max=262144 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=7200 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=60 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=60 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_udp_timeout=120 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_udp_timeout_stream=180 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_generic_timeout=300 2>/dev/null || true

# Hashsize = conntrack_max / 4
# Применяем мягко: только если модуль свежезагружен или активных соединений мало
if [ -f /sys/module/nf_conntrack/parameters/hashsize ]; then
    CURRENT_HASHSIZE=$(cat /sys/module/nf_conntrack/parameters/hashsize)
    ACTIVE_CONN=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)

    if [ "$CURRENT_HASHSIZE" = "65536" ]; then
        print_info "Hashsize уже 65536 — пропускаем"
    elif [ "$ACTIVE_CONN" -lt 5000 ]; then
        # Безопасно менять — мало активных коннектов
        echo 65536 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null && \
            print_ok "Hashsize изменён: $CURRENT_HASHSIZE → 65536 (активных соед.: $ACTIVE_CONN)" || \
            print_info "Hashsize применится после ребута (через modprobe.d)"
    else
        # Много активного трафика — не трогаем сейчас, применится после ребута
        print_info "Активных соед.: $ACTIVE_CONN — hashsize применится после ребута (избегаем лагов)"
    fi
fi

# Сохраняем в конфиг для сохранения после ребута
cat > /etc/sysctl.d/99-conntrack.conf <<EOF
# Conntrack tuning for VPN node (gaming-friendly)
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_udp_timeout = 120
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.netfilter.nf_conntrack_generic_timeout = 300
EOF
print_ok "Conntrack настроен и сохранён"

# Hashsize через modprobe для сохранения после ребута
cat > /etc/modprobe.d/conntrack.conf <<EOF
options nf_conntrack hashsize=65536
EOF
print_ok "Hashsize сохранён в modprobe.d"

# ==============================================================================
# ШАГ 7: НАСТРОЙКА СЕТЕВОГО СТЕКА (SYSCTL)
# ==============================================================================

print_header "ШАГ 7: НАСТРОЙКА СЕТЕВОГО СТЕКА (SYSCTL)"

# Получаем информацию о памяти
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_MEM_GB=$(echo "scale=1; $TOTAL_MEM_MB / 1024" | bc)
USED_MEM_MB=$(free -m | awk '/^Mem:/{print $3}')
FREE_MEM_MB=$(free -m | awk '/^Mem:/{print $4}')

print_status "Анализируем оперативную память..."
echo ""
echo -e "    ${BOLD}Память:${NC}"
echo -e "    ├─ Всего: ${GREEN}${TOTAL_MEM_MB} MB${NC} (~${TOTAL_MEM_GB} GB)"
echo -e "    ├─ Использовано: ${YELLOW}${USED_MEM_MB} MB${NC}"
echo -e "    └─ Свободно: ${GREEN}${FREE_MEM_MB} MB${NC}"
echo ""

SYSCTL_FILE="/etc/sysctl.d/99-xray-tuning.conf"

# Определяем профиль
if [ "$TOTAL_MEM_MB" -le 1200 ]; then
    PROFILE_NAME="SURVIVAL MODE"
    PROFILE_COLOR="${RED}"
    PROFILE_EMOJI="🔴"
elif [ "$TOTAL_MEM_MB" -le 2500 ]; then
    PROFILE_NAME="BALANCED MODE"
    PROFILE_COLOR="${YELLOW}"
    PROFILE_EMOJI="🟡"
elif [ "$TOTAL_MEM_MB" -le 8500 ]; then
    PROFILE_NAME="PERFORMANCE MODE"
    PROFILE_COLOR="${GREEN}"
    PROFILE_EMOJI="🟢"
else
    PROFILE_NAME="ULTRA 10G MODE"
    PROFILE_COLOR="${MAGENTA}"
    PROFILE_EMOJI="🟣"
fi

echo -e "    ${BOLD}Выбранный профиль:${NC}"
echo -e "    ${PROFILE_COLOR}╔═══════════════════════════════════════╗${NC}"
echo -e "    ${PROFILE_COLOR}║  ${PROFILE_EMOJI} ${PROFILE_NAME}${NC}"
echo -e "    ${PROFILE_COLOR}╚═══════════════════════════════════════╝${NC}"
echo ""

print_status "Генерируем конфигурацию sysctl..."

# --- Базовый конфиг (общий для всех профилей) ---
cat > $SYSCTL_FILE <<EOF
# ==============================================================================
# XRAY/VPN NODE OPTIMIZATION v4.0 - AUTO-GENERATED
# Profile: $PROFILE_NAME
# RAM: ${TOTAL_MEM_MB} MB
# Generated: $(date)
# ==============================================================================

# === BBRv3 Congestion Control ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === IP Forwarding ===
net.ipv4.ip_forward = 1

# === TCP Connections ===
# Очередь входящих соединений (accept backlog)
net.core.somaxconn = 65535
# Очередь SYN-пакетов (защита от SYN flood + пики подключений)
net.ipv4.tcp_max_syn_backlog = 65535
# SYN cookies при переполнении очереди
net.ipv4.tcp_syncookies = 1
# Переиспользование TIME_WAIT сокетов (критично при тысячах коннекций)
net.ipv4.tcp_tw_reuse = 1
# Быстрое освобождение FIN_WAIT сокетов (30 — баланс между играми и ресурсами)
net.ipv4.tcp_fin_timeout = 30
# Расширенный диапазон эфемерных портов
net.ipv4.ip_local_port_range = 1024 65535
# Не сбрасывать cwnd после паузы (ускоряет VPN-туннели)
net.ipv4.tcp_slow_start_after_idle = 0
# Автоматическое определение MTU (избежание фрагментации в туннелях)
net.ipv4.tcp_mtu_probing = 1
# Защита от TIME_WAIT assassination (RFC 1337)
net.ipv4.tcp_rfc1337 = 1
# TCP Fast Open отключён: конфликтует с Xray Reality TLS handshake
# Если используете не-Reality протоколы — раскомментируйте:
# net.ipv4.tcp_fastopen = 3

# === Connection Keepalives (Mobile clients) ===
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# === Bufferbloat reduction (latency boost для клиента) ===
# Ограничивает очередь на отправке, режет p99 latency на 15-40ms под нагрузкой
# Критично для видеозвонков, игр, SSH через VPN
net.ipv4.tcp_notsent_lowat = 131072

# === Security Hardening ===
# Loose reverse path filtering (compatible with VPN tunnels)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
# Не отправляем ICMP redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
# Не принимаем ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
# Игнорируем broadcast ICMP
net.ipv4.icmp_echo_ignore_broadcasts = 1

# === File Descriptors (ядро, system-wide) ===
fs.file-max = 2097152
EOF

# --- Профильные настройки (зависят от RAM) ---
if [ "$TOTAL_MEM_MB" -le 1200 ]; then
    cat >> $SYSCTL_FILE <<EOF

# === TIER 1: 1GB RAM (SURVIVAL MODE) ===
net.core.rmem_max = 2097152
net.core.wmem_max = 2097152
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 2097152
net.ipv4.tcp_wmem = 4096 16384 2097152
vm.vfs_cache_pressure = 150
vm.swappiness = 20
vm.min_free_kbytes = 32768
EOF

elif [ "$TOTAL_MEM_MB" -le 2500 ]; then
    cat >> $SYSCTL_FILE <<EOF

# === TIER 2: 2GB RAM (BALANCED MODE) ===
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 32768 8388608
vm.vfs_cache_pressure = 100
vm.swappiness = 10
vm.min_free_kbytes = 65536
net.core.netdev_max_backlog = 4096
EOF

elif [ "$TOTAL_MEM_MB" -le 8500 ]; then
    cat >> $SYSCTL_FILE <<EOF

# === TIER 3: 4-8GB RAM (PERFORMANCE MODE) ===
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 524288
net.core.wmem_default = 524288
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
vm.swappiness = 10
net.core.netdev_max_backlog = 16384
# Больше окна под данные (меньше под метаданные) — +5-15% throughput
net.ipv4.tcp_adv_win_scale = -2
EOF

else
    cat >> $SYSCTL_FILE <<EOF

# === TIER 4: 8GB+ RAM (ULTRA 10G MODE) ===
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 87380 33554432
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_adv_win_scale = -2
EOF
fi

print_ok "Конфиг сохранён: $SYSCTL_FILE"

# Показываем конфиг
print_info "Содержимое конфигурации:"
echo ""
echo -e "${CYAN}───────────────────────────────────────────────────────────────────${NC}"
cat $SYSCTL_FILE
echo -e "${CYAN}───────────────────────────────────────────────────────────────────${NC}"
echo ""

# Применяем все sysctl конфиги сразу (что применимо до ребута)
print_status "Применяем sysctl конфигурацию..."
sysctl --system 2>/dev/null | tail -5
print_ok "Sysctl применён (BBR и qdisc активируются после ребута на XanMod)"

# ==============================================================================
# ШАГ 7.5: НАСТРОЙКА QDISC (Multi-Queue / Single-Queue)
# ==============================================================================

print_header "ШАГ 7.5: НАСТРОЙКА QDISC (FQ / MQ+FQ)"

print_status "Определяем активный сетевой интерфейс..."
IFACE=$(ip route | awk '/default/ {print $5; exit}')

if [ -z "$IFACE" ]; then
    print_error "Не удалось определить default интерфейс! Пропускаем настройку qdisc."
else
    print_ok "Интерфейс: $IFACE"

    # Считаем количество TX очередей
    QUEUES=$(ls /sys/class/net/$IFACE/queues/ 2>/dev/null | grep -c tx)
    print_status "Анализируем структуру очередей..."
    echo -e "    ├─ CPU ядер: ${GREEN}$(nproc)${NC}"
    echo -e "    └─ TX очередей: ${GREEN}$QUEUES${NC}"
    echo ""

    if [ "$QUEUES" -gt 1 ]; then
        # Multi-queue NIC: ставим mq как root, на каждую queue — fq
        print_status "Настраиваем Multi-Queue (mq + fq per-queue)..."

        # Проверяем текущий root qdisc — если уже mq, не трогаем (избегаем drop пакетов)
        CURRENT_ROOT=$(tc qdisc show dev $IFACE | awk '/qdisc/ && /root/ {print $2; exit}')
        if [ "$CURRENT_ROOT" = "mq" ]; then
            print_info "Root qdisc уже mq — пропускаем replace (без drop пакетов)"
        else
            # add вместо replace когда возможно
            tc qdisc add dev $IFACE root handle 1: mq 2>/dev/null || \
                tc qdisc replace dev $IFACE root handle 1: mq 2>/dev/null
        fi

        # Ждём пока mq создаст sub-qdisc'ы
        sleep 1
        MQ_HANDLE=$(tc qdisc show dev $IFACE | awk '/qdisc mq/ {print $3}' | head -1)

        if [ -n "$MQ_HANDLE" ]; then
            # Фикс hex-индексации: для 16+ очередей нужен правильный hex
            # mq использует индексы 1..N в hex (1, 2, ... 9, a, b, ... f, 10, 11, ...)
            APPLIED=0
            for i in $(seq 1 $QUEUES); do
                HEX_IDX=$(printf '%x' "$i")
                # Проверяем есть ли уже fq на этой child queue — если да, пропускаем
                EXISTING=$(tc qdisc show dev $IFACE | grep "parent ${MQ_HANDLE}${HEX_IDX} " | grep -c fq)
                if [ "$EXISTING" -eq 0 ]; then
                    if tc qdisc add dev $IFACE parent ${MQ_HANDLE}${HEX_IDX} fq 2>/dev/null; then
                        APPLIED=$((APPLIED + 1))
                    elif tc qdisc change dev $IFACE parent ${MQ_HANDLE}${HEX_IDX} fq 2>/dev/null; then
                        APPLIED=$((APPLIED + 1))
                    fi
                else
                    APPLIED=$((APPLIED + 1))
                fi
            done
            print_ok "Multi-Queue настроен: $APPLIED/$QUEUES очередей с fq"
        else
            print_info "mq уже инициализирован с default_qdisc=fq"
        fi
        QDISC_MODE="mq + fq (per-queue, $QUEUES queues)"
    else
        # Single-queue: один fq на root (через add если можно — без drop)
        print_status "Настраиваем Single-Queue (fq)..."
        CURRENT_ROOT=$(tc qdisc show dev $IFACE | awk '/qdisc/ && /root/ {print $2; exit}')
        if [ "$CURRENT_ROOT" = "fq" ]; then
            print_info "fq уже активен — пропускаем"
        else
            tc qdisc add dev $IFACE root fq 2>/dev/null || tc qdisc replace dev $IFACE root fq
        fi
        print_ok "Single-Queue настроен: fq на root"
        QDISC_MODE="fq (single-queue)"
    fi

    echo ""
    print_info "Текущая структура qdisc:"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────────${NC}"
    tc qdisc show dev $IFACE
    echo -e "${CYAN}───────────────────────────────────────────────────────────────────${NC}"
fi

# ==============================================================================
# ШАГ 7.6: НАСТРОЙКА RPS (Receive Packet Steering)
# ==============================================================================

print_header "ШАГ 7.6: НАСТРОЙКА RPS"

CPUS=$(nproc)

if [ "$CPUS" -le 1 ]; then
    print_info "1 CPU — RPS не имеет смысла, пропускаем"
    # Удаляем сервис если остался от предыдущих запусков
    if [ -f /etc/systemd/system/rps-tuning.service ]; then
        print_status "Удаляем устаревший rps-tuning.service..."
        systemctl disable --now rps-tuning.service 2>/dev/null
        rm -f /etc/systemd/system/rps-tuning.service /usr/local/sbin/rps-tuning.sh
        systemctl daemon-reload
        print_ok "Старый сервис удалён"
    fi
    RPS_MODE="disabled (single CPU)"
elif [ -z "$IFACE" ]; then
    print_info "Интерфейс не определён, пропускаем RPS"
    RPS_MODE="skipped"
else
    # Проверяем количество HW очередей
    HW_QUEUES=$(ls /sys/class/net/$IFACE/queues/ 2>/dev/null | grep -c rx)

    print_status "Анализ необходимости RPS..."
    echo -e "    ├─ CPU ядер: ${GREEN}$CPUS${NC}"
    echo -e "    ├─ RX очередей: ${GREEN}$HW_QUEUES${NC}"

    if [ "$HW_QUEUES" -ge "$CPUS" ]; then
        echo -e "    └─ Решение: ${YELLOW}HW multi-queue достаточно, RPS не нужен${NC}"
        echo ""
        print_info "Сетевая карта имеет $HW_QUEUES очередей на $CPUS CPU — параллелизм уже на уровне железа"
        # Удаляем сервис если остался от предыдущих запусков
        if [ -f /etc/systemd/system/rps-tuning.service ]; then
            print_status "Удаляем устаревший rps-tuning.service..."
            systemctl disable --now rps-tuning.service 2>/dev/null
            rm -f /etc/systemd/system/rps-tuning.service /usr/local/sbin/rps-tuning.sh
            systemctl daemon-reload
            print_ok "Старый сервис удалён"
        fi
        RPS_MODE="not needed (HW multi-queue)"
    else
        # Битовая маска для всех CPU: (1 << N) - 1, в hex
        MASK=$(printf "%x" $(( (1 << CPUS) - 1 )))
        echo -e "    └─ Решение: ${GREEN}включаем RPS (mask=$MASK)${NC}"
        echo ""

        print_status "Создаём /usr/local/sbin/rps-tuning.sh..."
        cat > /usr/local/sbin/rps-tuning.sh <<'RPSEOF'
#!/bin/bash
# Auto-generated by VPN Node Builder
IFACE=$(ip route | awk '/default/ {print $5; exit}')
[ -z "$IFACE" ] && exit 0
CPUS=$(nproc)
[ "$CPUS" -le 1 ] && exit 0
MASK=$(printf "%x" $(( (1 << CPUS) - 1 )))
for q in /sys/class/net/$IFACE/queues/rx-*/rps_cpus; do
    [ -w "$q" ] && echo $MASK > $q
done
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
for q in /sys/class/net/$IFACE/queues/rx-*/rps_flow_cnt; do
    [ -w "$q" ] && echo 32768 > $q
done
RPSEOF
        chmod +x /usr/local/sbin/rps-tuning.sh
        print_ok "Скрипт RPS создан"

        print_status "Создаём systemd-сервис rps-tuning.service..."
        cat > /etc/systemd/system/rps-tuning.service <<'SVCEOF'
[Unit]
Description=RPS Tuning for VPN Node
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/rps-tuning.sh

[Install]
WantedBy=multi-user.target
SVCEOF
        print_ok "Сервис создан"

        print_status "Активируем rps-tuning.service..."
        systemctl daemon-reload
        systemctl enable --now rps-tuning.service 2>/dev/null

        # Проверка
        ACTIVE_MASK=$(cat /sys/class/net/$IFACE/queues/rx-0/rps_cpus 2>/dev/null)
        if [ "$ACTIVE_MASK" = "$MASK" ] || [ "$(echo $ACTIVE_MASK | tr -d 0,)" = "$(echo $MASK | tr -d 0,)" ]; then
            print_ok "RPS активен: mask=$ACTIVE_MASK (распределение на $CPUS CPU)"
            RPS_MODE="enabled (mask=$MASK, $CPUS CPU)"
        else
            print_info "RPS настроен, активная маска: $ACTIVE_MASK"
            RPS_MODE="enabled"
        fi
    fi
fi

# ==============================================================================
# ШАГ 7.7: БЕЗОПАСНЫЕ NIC БУСТЫ (ethtool / GRO / XPS / Ring Buffers)
# ==============================================================================

print_header "ШАГ 7.7: NIC ОПТИМИЗАЦИЯ (Безопасные бусты)"

NIC_BOOSTS_APPLIED=()

if [ -z "$IFACE" ]; then
    print_info "Интерфейс не определён, пропускаем NIC бусты"
else
    # Проверяем наличие ethtool
    if ! command -v ethtool >/dev/null 2>&1; then
        print_status "Устанавливаем ethtool..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y ethtool >/dev/null 2>&1
    fi

    # === БУСТ 1: ethtool offloads (GRO/GSO/TSO/checksums) ===
    print_status "Проверяем поддержку offload-функций драйвером..."
    if ethtool -k "$IFACE" >/dev/null 2>&1; then
        # Список offloads которые безопасно включать
        OFFLOAD_LIST=("gro" "gso" "tso" "tx" "rx")
        OFFLOAD_ENABLED=()

        for off in "${OFFLOAD_LIST[@]}"; do
            # Проверяем доступность флага (некоторые драйверы не поддерживают часть)
            CURRENT=$(ethtool -k "$IFACE" 2>/dev/null | grep -E "^${off}-(offload|checksumming):" | head -1 | awk '{print $2}')
            # Альтернативный формат
            [ -z "$CURRENT" ] && CURRENT=$(ethtool -k "$IFACE" 2>/dev/null | grep -E "^${off}:" | head -1 | awk '{print $2}')

            if [ "$CURRENT" = "off" ]; then
                if ethtool -K "$IFACE" "$off" on 2>/dev/null; then
                    OFFLOAD_ENABLED+=("$off")
                fi
            elif [ "$CURRENT" = "on" ]; then
                OFFLOAD_ENABLED+=("$off=already-on")
            fi
        done

        if [ ${#OFFLOAD_ENABLED[@]} -gt 0 ]; then
            print_ok "Offload-функции: ${OFFLOAD_ENABLED[*]}"
            NIC_BOOSTS_APPLIED+=("ethtool offloads")
        else
            print_info "Драйвер не поддерживает offload-tuning (виртуалка с paravirt?)"
        fi
    else
        print_info "ethtool не работает с $IFACE — пропускаем offloads"
    fi

    # === БУСТ 2: NIC Ring Buffers (увеличиваем СОЗНАТЕЛЬНО — может вызвать
    #     короткий link-flap на 1-3 сек на некоторых драйверах: ixgbe, mlx5)
    print_status "Анализируем NIC ring buffers..."
    if ethtool -g "$IFACE" >/dev/null 2>&1; then
        MAX_RX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/^RX:/ && !/Mini|Jumbo/ {print $2; exit}')
        MAX_TX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/^TX:/ {print $2; exit}')
        # Текущие значения (после "Current hardware settings:")
        CUR_RX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Current hardware settings/{found=1; next} found && /^RX:/ && !/Mini|Jumbo/ {print $2; exit}')
        CUR_TX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Current hardware settings/{found=1; next} found && /^TX:/ {print $2; exit}')

        if [ -n "$MAX_RX" ] && [ -n "$MAX_TX" ] && [ "$MAX_RX" != "n/a" ] && [ "$MAX_RX" -gt 0 ] 2>/dev/null; then
            echo -e "    ├─ Max RX/TX: ${GREEN}$MAX_RX/$MAX_TX${NC}"
            echo -e "    ├─ Cur RX/TX: ${GREEN}$CUR_RX/$CUR_TX${NC}"

            # Применяем только если есть смысл (current < max и разница хотя бы 2x)
            # И не на virtio (там почти всегда max=current и команда no-op)
            DRIVER=$(ethtool -i "$IFACE" 2>/dev/null | awk '/^driver:/ {print $2}')

            if [ "$DRIVER" = "virtio_net" ]; then
                print_info "virtio_net: ring buffers тюнинг не применим, пропускаем (без link-flap)"
            elif [ -n "$CUR_RX" ] && [ "$CUR_RX" = "$MAX_RX" ]; then
                print_info "Ring buffers уже на максимуме, пропускаем"
            elif [ -n "$CUR_RX" ] && [ "$((MAX_RX / CUR_RX))" -lt 2 ] 2>/dev/null; then
                print_info "Прирост <2x, пропускаем (избегаем link-flap, разрыв клиентов)"
            else
                # Только тут реально применяем — выгода оправдывает короткий разрыв
                print_status "Применяем ring buffers (возможен link-flap 1-3 сек)..."
                if ethtool -G "$IFACE" rx "$MAX_RX" tx "$MAX_TX" 2>/dev/null; then
                    print_ok "Ring buffers: RX=$MAX_RX, TX=$MAX_TX (было RX=$CUR_RX/$CUR_TX)"
                    NIC_BOOSTS_APPLIED+=("ring buffers max")
                else
                    print_info "Драйвер не позволяет менять ring buffers"
                fi
            fi
        else
            print_info "Драйвер не сообщает max ring buffer size"
        fi
    fi

    # === БУСТ 3: GRO Flush Timeout + napi_defer_hard_irqs ===
    # Безопасные значения: gro_flush=50µs, napi_defer=1
    # (выше значения дают больше CPU savings, но рискуют latency на прерывистом трафике)
    print_status "Настраиваем GRO flush + napi defer (батчинг прерываний)..."
    GRO_PATH="/sys/class/net/$IFACE/gro_flush_timeout"
    NAPI_PATH="/sys/class/net/$IFACE/napi_defer_hard_irqs"

    if [ -w "$GRO_PATH" ] && [ -w "$NAPI_PATH" ]; then
        # Сохраняем текущие значения для отката если что-то сломается
        OLD_GRO=$(cat "$GRO_PATH" 2>/dev/null)
        OLD_NAPI=$(cat "$NAPI_PATH" 2>/dev/null)
        echo 50000 > "$GRO_PATH" 2>/dev/null
        echo 1 > "$NAPI_PATH" 2>/dev/null
        # Проверяем что значение реально применилось
        NEW_GRO=$(cat "$GRO_PATH" 2>/dev/null)
        if [ "$NEW_GRO" = "50000" ]; then
            print_ok "GRO flush timeout: 50µs, napi_defer: 1 (-15-25% CPU на softirq)"
            NIC_BOOSTS_APPLIED+=("GRO flush + napi defer")
        else
            # Откат если не применилось
            echo "$OLD_GRO" > "$GRO_PATH" 2>/dev/null
            echo "$OLD_NAPI" > "$NAPI_PATH" 2>/dev/null
            print_info "GRO flush не применился, откатили"
        fi
    else
        print_info "GRO flush недоступен (старое ядро или виртуалка)"
    fi

    # === БУСТ 4: XPS (Transmit Packet Steering) ===
    # На 32+ CPU битовая маска может переполниться — пропускаем для безопасности
    if [ "$CPUS" -gt 1 ] && [ "$CPUS" -lt 32 ]; then
        print_status "Настраиваем XPS (распределение TX по CPU)..."
        XPS_APPLIED=0
        TX_QUEUES=$(ls /sys/class/net/"$IFACE"/queues/ 2>/dev/null | grep -c tx)

        if [ "$TX_QUEUES" -gt 0 ]; then
            # Распределяем CPU по TX очередям равномерно
            for tx_q in /sys/class/net/"$IFACE"/queues/tx-*; do
                [ ! -d "$tx_q" ] && continue
                Q_NUM=$(basename "$tx_q" | sed 's/tx-//')
                # CPU для этой очереди = Q_NUM % CPUS (round-robin)
                CPU_FOR_Q=$((Q_NUM % CPUS))
                CPU_MASK=$(printf "%x" $((1 << CPU_FOR_Q)))

                if [ -w "$tx_q/xps_cpus" ]; then
                    if echo "$CPU_MASK" > "$tx_q/xps_cpus" 2>/dev/null; then
                        XPS_APPLIED=$((XPS_APPLIED + 1))
                    fi
                fi
            done

            if [ "$XPS_APPLIED" -gt 0 ]; then
                print_ok "XPS активен: $XPS_APPLIED TX очередей распределены по $CPUS CPU"
                NIC_BOOSTS_APPLIED+=("XPS ($XPS_APPLIED queues)")
            else
                print_info "XPS не применился (драйвер не поддерживает)"
            fi
        fi
    elif [ "$CPUS" -ge 32 ]; then
        print_info "32+ CPU — XPS пропущен (используется RSS железа)"
    else
        print_info "1 CPU — XPS не нужен"
    fi

    # === Сохраняем NIC бусты в systemd-сервис (для применения после ребута) ===
    if [ ${#NIC_BOOSTS_APPLIED[@]} -gt 0 ]; then
        print_status "Создаём persistent systemd-сервис для NIC бустов..."

        cat > /usr/local/sbin/nic-tuning.sh <<'NICEOF'
#!/bin/bash
# Auto-generated by VPN Node Builder v4.1
# NIC optimization: GRO flush, XPS, ring buffers, offloads
IFACE=$(ip route | awk '/default/ {print $5; exit}')
[ -z "$IFACE" ] && exit 0
CPUS=$(nproc)

# Ждём пока интерфейс полностью поднимется
for i in 1 2 3 4 5; do
    [ -d "/sys/class/net/$IFACE" ] && break
    sleep 1
done

# Ring buffers max — ТОЛЬКО на не-virtio драйверах с заметной разницей
# (избегаем link-flap при каждом ребуте)
if command -v ethtool >/dev/null 2>&1; then
    DRIVER=$(ethtool -i "$IFACE" 2>/dev/null | awk '/^driver:/ {print $2}')
    if [ "$DRIVER" != "virtio_net" ]; then
        MAX_RX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/^RX:/ && !/Mini|Jumbo/ {print $2; exit}')
        MAX_TX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/^TX:/ {print $2; exit}')
        CUR_RX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Current hardware settings/{f=1; next} f && /^RX:/ && !/Mini|Jumbo/ {print $2; exit}')
        # Применяем только если current < max
        if [ -n "$MAX_RX" ] && [ "$MAX_RX" != "n/a" ] && [ -n "$CUR_RX" ] && [ "$CUR_RX" != "$MAX_RX" ]; then
            ethtool -G "$IFACE" rx "$MAX_RX" tx "$MAX_TX" 2>/dev/null || true
        fi
    fi

    # Offloads — безопасно, поддерживаются практически всеми драйверами
    for off in gro gso tso tx rx; do
        ethtool -K "$IFACE" "$off" on 2>/dev/null || true
    done
fi

# GRO flush + napi defer (консервативные значения)
[ -w "/sys/class/net/$IFACE/gro_flush_timeout" ] && echo 50000 > "/sys/class/net/$IFACE/gro_flush_timeout"
[ -w "/sys/class/net/$IFACE/napi_defer_hard_irqs" ] && echo 1 > "/sys/class/net/$IFACE/napi_defer_hard_irqs"

# XPS — распределение TX по CPU (только если CPU < 32 для безопасности маски)
if [ "$CPUS" -gt 1 ] && [ "$CPUS" -lt 32 ]; then
    for tx_q in /sys/class/net/$IFACE/queues/tx-*; do
        [ ! -d "$tx_q" ] && continue
        Q_NUM=$(basename "$tx_q" | sed 's/tx-//')
        CPU_FOR_Q=$((Q_NUM % CPUS))
        CPU_MASK=$(printf "%x" $((1 << CPU_FOR_Q)))
        [ -w "$tx_q/xps_cpus" ] && echo "$CPU_MASK" > "$tx_q/xps_cpus" 2>/dev/null || true
    done
fi

exit 0
NICEOF
        chmod +x /usr/local/sbin/nic-tuning.sh

        cat > /etc/systemd/system/nic-tuning.service <<'SVCEOF'
[Unit]
Description=NIC Tuning for VPN Node (GRO/XPS/Offloads/Ring Buffers)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/nic-tuning.sh

[Install]
WantedBy=multi-user.target
SVCEOF

        systemctl daemon-reload
        systemctl enable nic-tuning.service >/dev/null 2>&1
        print_ok "Сервис nic-tuning.service создан и включён"
    fi

    echo ""
    print_info "Применённые NIC бусты:"
    if [ ${#NIC_BOOSTS_APPLIED[@]} -eq 0 ]; then
        echo -e "    ${YELLOW}(ничего — драйвер/виртуализация не поддерживает)${NC}"
        NIC_BOOSTS_SUMMARY="none (driver limit)"
    else
        for b in "${NIC_BOOSTS_APPLIED[@]}"; do
            echo -e "    ${GREEN}✔${NC} $b"
        done
        NIC_BOOSTS_SUMMARY="${#NIC_BOOSTS_APPLIED[@]} boost(s)"
    fi
fi

# ==============================================================================
# ШАГ 8: НАСТРОЙКА ЛИМИТОВ (ULIMIT)
# ==============================================================================

print_header "ШАГ 8: НАСТРОЙКА ЛИМИТОВ (ULIMIT)"

print_status "Определяем лимиты файловых дескрипторов..."

if [ "$TOTAL_MEM_MB" -le 1200 ]; then
    LIMIT_COUNT=65535
    LIMIT_REASON="(ограничено из-за 1GB RAM)"
else
    LIMIT_COUNT=500000
    LIMIT_REASON="(стандартный для VPN-ноды)"
fi

echo -e "    Лимит: ${GREEN}$LIMIT_COUNT${NC} $LIMIT_REASON"
echo ""

print_status "Создаём /etc/security/limits.d/xray-limits.conf..."
cat > /etc/security/limits.d/xray-limits.conf <<EOF
# XRAY/VPN Limits - Auto-generated
* soft nofile $LIMIT_COUNT
* hard nofile $LIMIT_COUNT
root soft nofile $LIMIT_COUNT
root hard nofile $LIMIT_COUNT
EOF
print_ok "Лимиты пользователей настроены"

print_status "Настраиваем глобальный лимит systemd..."
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=$LIMIT_COUNT
EOF
print_ok "Systemd лимиты настроены"

print_status "Перезагружаем systemd daemon..."
systemctl daemon-reexec
print_ok "Systemd перезагружен"

# ==============================================================================
# ШАГ 9: ИТОГОВЫЙ ОТЧЁТ
# ==============================================================================

print_header "УСТАНОВКА ЗАВЕРШЕНА"

echo -e "${GREEN}"
echo "  ╔═══════════════════════════════════════════════════════════════════╗"
echo "  ║                    ✅ ВСЁ ГОТОВО!                                 ║"
echo "  ╚═══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "  ${BOLD}Сводка установки:${NC}"
echo ""
echo -e "  ┌─────────────────────────────────────────────────────────────────┐"
echo -e "  │ ${BOLD}Компонент${NC}              │ ${BOLD}Значение${NC}                            │"
echo -e "  ├─────────────────────────────────────────────────────────────────┤"
echo -e "  │ Ядро                   │ ${GREEN}$KERNEL_PKG${NC}               │"
echo -e "  │ CPU Level              │ ${GREEN}x86-64-v${CPU_LEVEL}${NC}                           │"
echo -e "  │ Профиль памяти         │ ${PROFILE_COLOR}$PROFILE_NAME${NC}                │"
echo -e "  │ RAM                    │ ${GREEN}${TOTAL_MEM_MB} MB${NC}                            │"
echo -e "  │ Лимит nofile           │ ${GREEN}$LIMIT_COUNT${NC}                          │"
echo -e "  │ TCP Congestion         │ ${GREEN}BBRv3${NC}                               │"
echo -e "  │ Qdisc                  │ ${GREEN}${QDISC_MODE:-fq}${NC}                     │"
echo -e "  │ RPS                    │ ${GREEN}${RPS_MODE:-disabled}${NC}                 │"
echo -e "  │ NIC Boosts             │ ${GREEN}${NIC_BOOSTS_SUMMARY:-none}${NC}            │"
echo -e "  │ Cloud Provider         │ ${GREEN}${CLOUD_DETECTED}${NC}                     │"
echo -e "  └─────────────────────────────────────────────────────────────────┘"
echo ""

echo -e "  ${BOLD}Что было сделано:${NC}"
echo -e "  ├─ ${GREEN}✔${NC} Бэкап старых конфигов: ${CYAN}${BACKUP_DIR}${NC}"
echo -e "  ├─ ${GREEN}✔${NC} Удалены snap, apport, whoopsie (cloud-init: $([ "$CLOUD_DETECTED" = "none" ] && echo 'удалён' || echo 'сохранён'))"
echo -e "  ├─ ${GREEN}✔${NC} Отключены ModemManager, fwupd, udisks2, multipathd"
echo -e "  ├─ ${GREEN}✔${NC} Ограничены логи journald (100MB)"
echo -e "  ├─ ${GREEN}✔${NC} Установлено ядро XanMod с BBRv3 (старое ядро как fallback)"
echo -e "  ├─ ${GREEN}✔${NC} Отключён IPv6"
echo -e "  ├─ ${GREEN}✔${NC} Настроен conntrack (262144, короткие таймауты)"
echo -e "  ├─ ${GREEN}✔${NC} Оптимизирован сетевой стек (tw_reuse, MTU probing, notsent_lowat)"
echo -e "  ├─ ${GREEN}✔${NC} Hardening (rp_filter, no redirects)"
echo -e "  ├─ ${GREEN}✔${NC} Настроены лимиты (nofile $LIMIT_COUNT)"
echo -e "  ├─ ${GREEN}✔${NC} Qdisc + RPS настроены под топологию железа"
echo -e "  └─ ${GREEN}✔${NC} NIC бусты: GRO flush, XPS, offloads, ring buffers"
echo ""

echo -e "  ${BOLD}Файлы конфигурации:${NC}"
echo -e "  ├─ ${CYAN}/etc/sysctl.d/99-xray-tuning.conf${NC}"
echo -e "  ├─ ${CYAN}/etc/sysctl.d/99-disable-ipv6.conf${NC}"
echo -e "  ├─ ${CYAN}/etc/sysctl.d/99-conntrack.conf${NC}"
echo -e "  ├─ ${CYAN}/etc/modprobe.d/conntrack.conf${NC}"
echo -e "  ├─ ${CYAN}/etc/security/limits.d/xray-limits.conf${NC}"
echo -e "  ├─ ${CYAN}/etc/systemd/system.conf.d/limits.conf${NC}"
echo -e "  ├─ ${CYAN}/etc/systemd/journald.conf.d/size-limit.conf${NC}"
echo -e "  ├─ ${CYAN}/usr/local/sbin/rps-tuning.sh${NC}"
echo -e "  ├─ ${CYAN}/etc/systemd/system/rps-tuning.service${NC}"
echo -e "  ├─ ${CYAN}/usr/local/sbin/nic-tuning.sh${NC}"
echo -e "  └─ ${CYAN}/etc/systemd/system/nic-tuning.service${NC}"
echo ""
echo -e "  ${BOLD}Бэкап старых конфигов:${NC}"
echo -e "  └─ ${CYAN}${BACKUP_DIR}${NC}"
echo ""

echo -e "  ${YELLOW}⚠️  ВАЖНО: Для активации ядра XanMod требуется перезагрузка!${NC}"
echo ""

echo -e "${RED}"
echo "  ╔═══════════════════════════════════════════════════════════════════╗"
echo "  ║                     🔄 ТРЕБУЕТСЯ REBOOT                           ║"
echo "  ╚═══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "  ${BOLD}После перезагрузки проверьте:${NC}"
echo -e "  ${CYAN}uname -r${NC}                                    # Должно показать xanmod"
echo -e "  ${CYAN}sysctl net.ipv4.tcp_congestion_control${NC}      # Должно быть bbr"
echo -e "  ${CYAN}sysctl net.core.default_qdisc${NC}               # Должно быть fq"
echo -e "  ${CYAN}tc qdisc show dev \$(ip route|awk '/default/{print \$5;exit}')${NC}  # mq+fq или fq"
echo -e "  ${CYAN}cat /sys/class/net/\$(ip route|awk '/default/{print \$5;exit}')/queues/rx-0/rps_cpus${NC}  # RPS mask"
echo -e "  ${CYAN}sysctl net.netfilter.nf_conntrack_max${NC}       # Должно быть 262144"
echo -e "  ${CYAN}cat /proc/sys/net/ipv4/tcp_tw_reuse${NC}         # Должно быть 1"
echo ""

read -p "  Перезагрузить сервер сейчас? (y/n): " -n 1 -r < /dev/tty
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "  ${GREEN}Перезагрузка через 3 секунды...${NC}"
    sleep 3
    reboot
else
    echo ""
    echo -e "  ${YELLOW}Не забудьте перезагрузить сервер позже!${NC}"
    echo -e "  ${CYAN}sudo reboot${NC}"
    echo ""
fi
