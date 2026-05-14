#!/bin/bash
# ==============================================================================
# node-check.sh v1.0
# Универсальная проверка VPN-ноды после upgrade.
#
# Использование:
#   sudo bash node-check.sh                  # полная проверка с 5-мин observation
#   sudo bash node-check.sh --quick          # без 5-мин sleep
#   sudo bash node-check.sh --deep           # + tcpdump на 30s для UDP source analysis
#   sudo bash node-check.sh > check.txt 2>&1 # сохранить вывод
#
# Что проверяет:
#   1. Версии vpn-node-setup + shieldnode
#   2. Sysctl файлы (новые есть, старые удалены)
#   3. Sysctl values (UDP buffer, BBR, conntrack, security)
#   4. Kernel (XanMod)
#   5. NFTables (ddos_protect, vpn_node_mss_clamp)
#   6. Systemd services
#   7. CrowdSec
#   8. UFW
#   9. Network snapshot + UDP growth rate (5 мин)
#   10. Docker/Xray
#   11. Installed files
#   12. UDP memory analysis (global cap, top sockets, processes)
# ==============================================================================

set -o pipefail

# =============================================================================
# Аргументы
# =============================================================================
QUICK_MODE=0
DEEP_MODE=0
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK_MODE=1 ;;
        --deep) DEEP_MODE=1 ;;
        --help|-h)
            grep '^#' "$0" | head -20
            exit 0
            ;;
    esac
done

# =============================================================================
# Colors
# =============================================================================
if [ -t 1 ]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
    C='\033[0;36m'; M='\033[0;35m'; B='\033[1m'
    D='\033[2m'; N='\033[0m'
else
    R='' G='' Y='' C='' M='' B='' D='' N=''
fi

EXPECTED_NODE_VERSION="5.1.0"
EXPECTED_SHIELD_VERSION="3.23.0"

# Счётчики
PASS=0
WARN=0
FAIL=0

# =============================================================================
# Helpers
# =============================================================================
ok()   { echo -e "  ${G}OK${N}     $*"; ((PASS++)); }
warn() { echo -e "  ${Y}WARN${N}   $*"; ((WARN++)); }
fail() { echo -e "  ${R}FAIL${N}   $*"; ((FAIL++)); }
info() { echo -e "  ${D}info${N}   $*"; }
head1() { echo ""; echo -e "${B}${C}== $* ==${N}"; }

# Проверка значения sysctl
check_sysctl() {
    local key="$1"
    local expected="$2"
    local name="${3:-$key}"
    local actual=$(sysctl -n "$key" 2>/dev/null)
    
    if [ -z "$actual" ]; then
        fail "$name = (отсутствует, ожидали $expected)"
        return 1
    fi
    
    # Нормализуем — некоторые sysctl возвращают tab-separated
    local actual_norm=$(echo "$actual" | tr -s '[:space:]' ' ')
    local expected_norm=$(echo "$expected" | tr -s '[:space:]' ' ')
    
    if [ "$actual_norm" = "$expected_norm" ]; then
        ok "$name = $actual_norm"
    else
        fail "$name = $actual_norm (ожидали $expected_norm)"
    fi
}

# Проверка существования файла
check_file() {
    local path="$1"
    local description="${2:-$path}"
    
    if [ -e "$path" ]; then
        ok "$description"
    else
        fail "$description (НЕТ: $path)"
    fi
}

# =============================================================================
# Start
# =============================================================================
clear
echo -e "${B}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${B}║          ПРОВЕРКА VPN-НОДЫ ПОСЛЕ UPGRADE                ║${N}"
echo -e "${B}╚══════════════════════════════════════════════════════════╝${N}"
echo ""
echo -e "Hostname:    ${C}$(hostname)${N}"
echo -e "Дата:        $(date -u)"
echo -e "Mode:        $([ "$QUICK_MODE" = "1" ] && echo "QUICK" || echo "FULL") $([ "$DEEP_MODE" = "1" ] && echo "+ DEEP")"

# Базовая инфа
TOTAL_RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
echo -e "RAM:         ${TOTAL_RAM_MB}MB"
echo -e "Kernel:      $(uname -r)"

# Определяем TIER (для контекста rmem_default ожидания)
if [ "$TOTAL_RAM_MB" -le 1200 ]; then
    TIER="1 (1GB)"
    EXPECTED_RMEM_DEFAULT="262144"
elif [ "$TOTAL_RAM_MB" -le 2500 ]; then
    TIER="2 (2GB)"
    EXPECTED_RMEM_DEFAULT="2097152"
elif [ "$TOTAL_RAM_MB" -le 8500 ]; then
    TIER="3 (4-8GB)"
    EXPECTED_RMEM_DEFAULT="8388608"
else
    TIER="4 (8GB+)"
    EXPECTED_RMEM_DEFAULT="8388608"
fi
echo -e "TIER:        ${TIER}"

# =============================================================================
# 1. ВЕРСИИ
# =============================================================================
head1 "1. ВЕРСИИ"

# vpn-node-setup версия
NODE_VER="?"
if [ -f /var/lib/vpn-node-builder/.version ]; then
    NODE_VER=$(cat /var/lib/vpn-node-builder/.version)
elif [ -f /etc/sysctl.d/80-vpn-node-tuning.conf ]; then
    NODE_VER=$(grep -oE "v[0-9]+\.[0-9]+\.[0-9]+" /etc/sysctl.d/80-vpn-node-tuning.conf | head -1 | sed 's/^v//')
    info "Версия определена по комменту в 80-vpn-node-tuning.conf"
fi

if [ "$NODE_VER" = "$EXPECTED_NODE_VERSION" ]; then
    ok "vpn-node-setup: v$NODE_VER"
elif [ "$NODE_VER" = "?" ]; then
    fail "vpn-node-setup: не определена"
else
    warn "vpn-node-setup: v$NODE_VER (ожидаем v$EXPECTED_NODE_VERSION)"
fi

# shieldnode версия
SHIELD_VER="?"
if command -v guard >/dev/null 2>&1; then
    SHIELD_VER=$(guard --json 2>/dev/null | grep -oE '"version":"[^"]*"' | head -1 | cut -d'"' -f4)
fi
if [ "$SHIELD_VER" = "?" ] && [ -f /etc/sysctl.d/90-shieldnode.conf ]; then
    SHIELD_VER=$(grep -oE "v[0-9]+\.[0-9]+\.[0-9]+" /etc/sysctl.d/90-shieldnode.conf | head -1 | sed 's/^v//')
    [ -n "$SHIELD_VER" ] && info "Версия определена по комменту в 90-shieldnode.conf"
fi

if [ "$SHIELD_VER" = "$EXPECTED_SHIELD_VERSION" ]; then
    ok "shieldnode: v$SHIELD_VER"
elif [ -z "$SHIELD_VER" ] || [ "$SHIELD_VER" = "?" ]; then
    fail "shieldnode: не определена"
else
    warn "shieldnode: v$SHIELD_VER (ожидаем v$EXPECTED_SHIELD_VERSION)"
fi

# =============================================================================
# 2. SYSCTL ФАЙЛЫ
# =============================================================================
head1 "2. SYSCTL ФАЙЛЫ"

# Должны существовать
check_file "/etc/sysctl.d/80-vpn-node-tuning.conf" "80-vpn-node-tuning.conf"
check_file "/etc/sysctl.d/90-shieldnode.conf" "90-shieldnode.conf"

# Старые не должны существовать
LEGACY_FILES="99-vpn-node-tuning.conf 99-xray-tuning.conf 99-conntrack.conf 99-z-udp-fix.conf 99-shieldnode.conf 99-udp-fix.conf"
for old in $LEGACY_FILES; do
    if [ -f "/etc/sysctl.d/$old" ]; then
        warn "Старый файл найден: /etc/sysctl.d/$old (должен быть удалён)"
    fi
done

# =============================================================================
# 3. KEY SYSCTL VALUES
# =============================================================================
head1 "3. KEY SYSCTL VALUES"

echo -e "${B}UDP buffer fix (v5.1.0):${N}"
check_sysctl "net.ipv4.udp_rmem_min" "8388608" "udp_rmem_min"
check_sysctl "net.ipv4.udp_wmem_min" "8388608" "udp_wmem_min"
check_sysctl "net.core.rmem_default" "$EXPECTED_RMEM_DEFAULT" "rmem_default"
check_sysctl "net.core.wmem_default" "$EXPECTED_RMEM_DEFAULT" "wmem_default"

# udp_mem проверяем но без strict expected (зависит от tier)
UDP_MEM=$(sysctl -n net.ipv4.udp_mem 2>/dev/null)
UDP_MEM_MIN=$(echo "$UDP_MEM" | awk '{print $1}')
UDP_MEM_MAX=$(echo "$UDP_MEM" | awk '{print $3}')
UDP_MEM_MAX_MB=$((UDP_MEM_MAX * 4 / 1024))  # pages → MB
if [ -n "$UDP_MEM" ]; then
    ok "udp_mem = $UDP_MEM (~${UDP_MEM_MAX_MB} MB ceiling)"
else
    fail "udp_mem не установлен"
fi

echo ""
echo -e "${B}TCP settings:${N}"
check_sysctl "net.ipv4.tcp_congestion_control" "bbr" "tcp_congestion"
check_sysctl "net.ipv4.tcp_adv_win_scale" "-2" "tcp_adv_win_scale"
check_sysctl "net.ipv4.tcp_fastopen" "3" "tcp_fastopen"
check_sysctl "net.core.default_qdisc" "fq" "default_qdisc"

echo ""
echo -e "${B}Shieldnode (v3.23.0):${N}"
check_sysctl "net.ipv4.conf.all.log_martians" "0" "log_martians.all"
check_sysctl "net.ipv4.conf.default.log_martians" "0" "log_martians.default"
check_sysctl "net.ipv4.tcp_synack_retries" "3" "tcp_synack_retries"
check_sysctl "net.netfilter.nf_conntrack_udp_timeout_stream" "600" "udp_timeout_stream"
check_sysctl "net.netfilter.nf_conntrack_udp_timeout" "180" "udp_timeout"

echo ""
echo -e "${B}Conntrack:${N}"
CONNTRACK_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
CONNTRACK_COUNT=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null)
ok "conntrack_max = $CONNTRACK_MAX"
if [ -n "$CONNTRACK_COUNT" ] && [ -n "$CONNTRACK_MAX" ]; then
    PERCENT=$((CONNTRACK_COUNT * 100 / CONNTRACK_MAX))
    if [ "$PERCENT" -lt 50 ]; then
        ok "conntrack_count = $CONNTRACK_COUNT (${PERCENT}% utilization)"
    elif [ "$PERCENT" -lt 80 ]; then
        warn "conntrack_count = $CONNTRACK_COUNT (${PERCENT}% utilization — повышенная)"
    else
        fail "conntrack_count = $CONNTRACK_COUNT (${PERCENT}% utilization — опасная!)"
    fi
fi
check_sysctl "net.netfilter.nf_conntrack_tcp_timeout_established" "86400" "tcp_established"

echo ""
echo -e "${B}Security (shieldnode):${N}"
check_sysctl "net.ipv4.conf.all.rp_filter" "2" "rp_filter (loose для VPN)"
check_sysctl "net.ipv4.tcp_syncookies" "1" "syncookies"
check_sysctl "net.ipv4.conf.all.send_redirects" "0" "send_redirects"
check_sysctl "net.ipv4.ip_forward" "1" "ip_forward"

# =============================================================================
# 4. KERNEL
# =============================================================================
head1 "4. KERNEL"

KERNEL=$(uname -r)
if echo "$KERNEL" | grep -qE "xanmod"; then
    ok "XanMod ядро активно: $KERNEL"
else
    warn "Не XanMod: $KERNEL (возможно нужен reboot после install)"
fi

BBR_AVAILABLE=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
if echo "$BBR_AVAILABLE" | grep -q "bbr"; then
    ok "BBR доступен: $BBR_AVAILABLE"
else
    fail "BBR не в списке: $BBR_AVAILABLE"
fi

# Reboot required?
if [ -f /var/run/reboot-required ]; then
    warn "Требуется reboot — есть /var/run/reboot-required"
fi

# =============================================================================
# 5. NFTABLES
# =============================================================================
head1 "5. NFTABLES"

echo "Таблицы:"
nft list tables 2>/dev/null | sed 's/^/    /' | head -10

echo ""
if nft list table inet ddos_protect >/dev/null 2>&1; then
    RULE_COUNT=$(nft list table inet ddos_protect 2>/dev/null | grep -cE "^[[:space:]]*(ip|tcp|udp|ct|fib|meta)")
    ok "inet ddos_protect: $RULE_COUNT rules"
    
    # Проверим что counters работают (хоть один растёт)
    THREAT_COUNT=$(nft list counter inet ddos_protect threat_drops_v4 2>/dev/null | grep -oE 'packets [0-9]+' | awk '{print $2}')
    if [ -n "$THREAT_COUNT" ]; then
        ok "threat_drops_v4 counter активен (packets: $THREAT_COUNT)"
    fi
else
    fail "inet ddos_protect отсутствует!"
fi

if nft list table inet vpn_node_mss_clamp >/dev/null 2>&1; then
    MSS_RULES=$(nft list table inet vpn_node_mss_clamp 2>/dev/null | grep -c "mss")
    ok "inet vpn_node_mss_clamp: $MSS_RULES MSS правил"
else
    warn "inet vpn_node_mss_clamp отсутствует (MSS clamp не активен)"
fi

# =============================================================================
# 6. SYSTEMD SERVICES
# =============================================================================
head1 "6. SYSTEMD SERVICES"

REQUIRED_SERVICES=(
    "shieldnode-nftables.service"
    "nic-tuning.service"
    "rps-tuning.service"
)
OPTIONAL_SERVICES=(
    "shieldnode-aggregator.timer"
    "protected-ports-update.timer"
    "shieldnode-cleanup.timer"
    "shieldnode-github-sync.timer"
    "shieldnode-version-check.timer"
)

for svc in "${REQUIRED_SERVICES[@]}"; do
    if systemctl list-unit-files | grep -q "^$svc"; then
        STATE=$(systemctl is-active $svc 2>/dev/null)
        if [ "$STATE" = "active" ]; then
            ok "$svc: $STATE"
        else
            fail "$svc: $STATE (требуется active)"
        fi
    else
        warn "$svc: не установлен"
    fi
done

for svc in "${OPTIONAL_SERVICES[@]}"; do
    if systemctl list-unit-files | grep -q "^$svc"; then
        STATE=$(systemctl is-active $svc 2>/dev/null)
        if [ "$STATE" = "active" ]; then
            ok "$svc: $STATE"
        else
            info "$svc: $STATE"
        fi
    fi
done

# =============================================================================
# 7. CROWDSEC
# =============================================================================
head1 "7. CROWDSEC"

if command -v cscli >/dev/null 2>&1; then
    if systemctl is-active crowdsec --quiet 2>/dev/null; then
        ok "crowdsec.service active"
    else
        fail "crowdsec.service не active"
    fi
    
    if systemctl is-active crowdsec-firewall-bouncer --quiet 2>/dev/null; then
        ok "crowdsec-firewall-bouncer active"
    else
        fail "crowdsec-firewall-bouncer не active"
    fi
    
    DECISIONS=$(timeout 5 cscli decisions list -o raw 2>/dev/null | wc -l)
    info "Active decisions: $DECISIONS"
    
    BOUNCER=$(timeout 5 cscli bouncers list -o raw 2>/dev/null | grep -v "^name" | head -1)
    if [ -n "$BOUNCER" ]; then
        info "Bouncer: $(echo $BOUNCER | cut -d',' -f1)"
    fi
else
    warn "cscli не установлен"
fi

# =============================================================================
# 8. UFW
# =============================================================================
head1 "8. UFW"

if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ok "UFW активен"
        RULES=$(ufw status 2>/dev/null | grep -cE "^[0-9]+/")
        info "Правил: $RULES"
    else
        warn "UFW не активен"
    fi
else
    warn "ufw не установлен"
fi

# =============================================================================
# 9. NETWORK SNAPSHOT
# =============================================================================
head1 "9. NETWORK SNAPSHOT"

TCP_SOCKETS=$(ss -tan 2>/dev/null | wc -l)
UDP_SOCKETS=$(ss -uan 2>/dev/null | wc -l)
TCP_ESTAB=$(ss -tan state established 2>/dev/null | wc -l)
info "TCP sockets:       $TCP_SOCKETS"
info "UDP sockets:       $UDP_SOCKETS"
info "TCP established:   $TCP_ESTAB"

# TCP retrans
TCP_RETRANS_PCT=$(awk '/^Tcp:/{getline; if($11>0) printf "%.2f", $13/$11*100}' /proc/net/snmp)
if [ -n "$TCP_RETRANS_PCT" ]; then
    if (( $(echo "$TCP_RETRANS_PCT < 2.5" | bc -l 2>/dev/null) )); then
        ok "TCP retrans: ${TCP_RETRANS_PCT}% (отлично)"
    elif (( $(echo "$TCP_RETRANS_PCT < 5" | bc -l 2>/dev/null) )); then
        ok "TCP retrans: ${TCP_RETRANS_PCT}% (норма для VPN forwarder)"
    elif (( $(echo "$TCP_RETRANS_PCT < 10" | bc -l 2>/dev/null) )); then
        warn "TCP retrans: ${TCP_RETRANS_PCT}% (высоковато — возможен uplink loss)"
    else
        fail "TCP retrans: ${TCP_RETRANS_PCT}% (очень высокий — проблема uplink)"
    fi
fi

# UDP errors snapshot
UDP_ERRORS=$(awk '/^Udp:/{getline; print "  Pkts:"$2" InErr:"$3" RcvbufErr:"$5" SndbufErr:"$6}' /proc/net/snmp)
echo ""
echo -e "${B}UDP errors (накопленные с момента старта):${N}"
echo "$UDP_ERRORS"

# =============================================================================
# 10. UDP MEMORY ANALYSIS
# =============================================================================
head1 "10. UDP MEMORY ANALYSIS"

# Глобальный UDP memory usage из sockstat
SOCKSTAT_UDP=$(grep -E "^UDP[: ]" /proc/net/sockstat 2>/dev/null)
if [ -n "$SOCKSTAT_UDP" ]; then
    UDP_INUSE=$(echo "$SOCKSTAT_UDP" | head -1 | grep -oE "inuse [0-9]+" | awk '{print $2}')
    UDP_MEM_PAGES=$(echo "$SOCKSTAT_UDP" | head -1 | grep -oE "mem [0-9]+" | awk '{print $2}')
    UDP_MEM_USED_KB=$((UDP_MEM_PAGES * 4))
    UDP_MEM_USED_MB=$((UDP_MEM_USED_KB / 1024))
    UDP_MEM_MAX_KB=$((UDP_MEM_MAX * 4))
    UDP_MEM_PCT=0
    [ "$UDP_MEM_MAX_KB" -gt 0 ] && UDP_MEM_PCT=$((UDP_MEM_USED_KB * 100 / UDP_MEM_MAX_KB))
    
    info "UDP sockets in use:    $UDP_INUSE"
    info "UDP memory used:       ${UDP_MEM_USED_MB} MB (${UDP_MEM_USED_KB} KB / $UDP_MEM_PAGES pages)"
    info "UDP memory cap:        $((UDP_MEM_MAX_KB / 1024)) MB ($UDP_MEM_MAX pages)"
    
    if [ "$UDP_MEM_PCT" -lt 50 ]; then
        ok "UDP memory utilization: ${UDP_MEM_PCT}% (норма)"
    elif [ "$UDP_MEM_PCT" -lt 80 ]; then
        warn "UDP memory utilization: ${UDP_MEM_PCT}% (повышенная)"
    else
        fail "UDP memory utilization: ${UDP_MEM_PCT}% (близко к cap — поднимай udp_mem!)"
    fi
fi

# Топ-5 UDP сокетов по RecvQ size
echo ""
echo -e "${B}Top 5 UDP sockets по recv-Q size:${N}"
ss -uan 2>/dev/null | sort -k 2 -rn | head -6 | tail -5 | awk '{printf "  RecvQ=%-8s SendQ=%-8s Local=%-25s Peer=%-25s\n", $2, $3, $4, $5}'

# Top processes holding UDP sockets
echo ""
echo -e "${B}Top 5 процессов держащих UDP сокеты:${N}"
ss -uanp 2>/dev/null | grep -oE 'users:\(\("[^"]+",pid=[0-9]+' | awk -F'"' '{print $2}' | sort | uniq -c | sort -rn | head -5 | sed 's/^/  /'

# =============================================================================
# 11. DOCKER / XRAY
# =============================================================================
head1 "11. DOCKER / XRAY"

if command -v docker >/dev/null 2>&1; then
    CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null)
    if [ -n "$CONTAINERS" ]; then
        echo "Контейнеры:"
        docker ps --format "  {{.Names}}: {{.Status}}" 2>/dev/null | head -5
        
        # RemnaNode logs check
        REMNANODE=$(echo "$CONTAINERS" | grep -i remnanode | head -1)
        if [ -n "$REMNANODE" ]; then
            echo ""
            ERRORS=$(docker logs --tail 100 "$REMNANODE" 2>&1 | grep -iE "error|fail|fatal" | grep -v "^$" | head -3)
            if [ -z "$ERRORS" ]; then
                ok "RemnaNode logs: нет ошибок"
            else
                warn "RemnaNode logs содержат ошибки:"
                echo "$ERRORS" | sed 's/^/    /'
            fi
        fi
    else
        info "Docker контейнеры не запущены"
    fi
else
    info "Docker не установлен"
fi

# =============================================================================
# 12. INSTALLED FILES
# =============================================================================
head1 "12. INSTALLED FILES"

check_file "/usr/local/bin/guard" "guard CLI"
check_file "/etc/sysctl.d/80-vpn-node-tuning.conf" "80-vpn-node-tuning.conf"
check_file "/etc/sysctl.d/90-shieldnode.conf" "90-shieldnode.conf"

if [ -d /etc/shieldnode ]; then
    ok "/etc/shieldnode/ существует"
    if [ -f /etc/shieldnode/shieldnode.conf ]; then
        info "  shieldnode.conf: $(wc -l < /etc/shieldnode/shieldnode.conf) строк"
    fi
    if [ -d /etc/shieldnode/lists ]; then
        LIST_FILES=$(ls /etc/shieldnode/lists/ 2>/dev/null | wc -l)
        info "  lists/: $LIST_FILES файлов"
    fi
fi

# =============================================================================
# 13. UDP GROWTH RATE (если не quick)
# =============================================================================
if [ "$QUICK_MODE" = "0" ]; then
    head1 "13. UDP GROWTH RATE (5 минут)"
    info "Замеряю rate RcvbufErrors за 5 минут..."
    info "Ctrl+C прервёт замер, но остальные данные уже выведены."
    
    BEFORE=$(awk '/^Udp:/{getline; print $5}' /proc/net/snmp)
    T0=$(date +%s)
    echo "  BEFORE: $BEFORE at $(date +%H:%M:%S)"
    
    # Прогресс bar за 5 минут
    for i in 1 2 3 4 5; do
        sleep 60
        ELAPSED=$((i * 60))
        echo -ne "\r  Прошло: ${ELAPSED}s / 300s..."
    done
    echo ""
    
    AFTER=$(awk '/^Udp:/{getline; print $5}' /proc/net/snmp)
    T1=$(date +%s)
    DELTA=$((AFTER - BEFORE))
    ELAPSED=$((T1 - T0))
    RATE=$((DELTA / ELAPSED))
    
    echo "  AFTER:  $AFTER at $(date +%H:%M:%S)"
    echo "  Elapsed: ${ELAPSED}s, Delta: $DELTA"
    echo "  Rate: ${RATE}/sec ($((RATE * 60))/min)"
    echo ""
    
    if [ "$DELTA" -eq 0 ]; then
        ok "RcvbufErrors growth = 0 (UDP fix работает идеально)"
    elif [ "$DELTA" -lt 100 ]; then
        ok "RcvbufErrors growth = $DELTA за 5 минут (приемлемо)"
    elif [ "$DELTA" -lt 1000 ]; then
        warn "RcvbufErrors growth = $DELTA за 5 минут (повышенно, но не критично)"
    elif [ "$DELTA" -lt 10000 ]; then
        warn "RcvbufErrors growth = $DELTA за 5 минут (высокий — проверь udp_mem cap)"
    else
        fail "RcvbufErrors growth = $DELTA за 5 минут (СЛИШКОМ ВЫСОКО)"
        echo ""
        echo -e "  ${Y}Возможные решения:${N}"
        echo "  1. Подними udp_mem cap в 2 раза:"
        echo "     cat > /etc/sysctl.d/99-zz-udp-mem-boost.conf <<EOF"
        echo "     net.ipv4.udp_mem = $((UDP_MEM_MIN*2)) $((UDP_MEM_MAX*2*4/3)) $((UDP_MEM_MAX*2))"
        echo "     EOF"
        echo "     sysctl --system"
        echo ""
        echo "  2. Запусти --deep чтобы найти источник UDP трафика"
    fi
else
    head1 "13. UDP GROWTH RATE"
    info "Пропущено (--quick режим). Запусти без --quick для замера за 5 минут."
fi

# =============================================================================
# 14. DEEP MODE (опционально)
# =============================================================================
if [ "$DEEP_MODE" = "1" ]; then
    head1 "14. DEEP MODE: tcpdump UDP traffic (30 сек)"
    info "Запускаю tcpdump для анализа UDP трафика..."
    
    if command -v tcpdump >/dev/null 2>&1; then
        echo "  Top UDP destination ports за 30 секунд:"
        timeout 30 tcpdump -i any -nn -q 'udp' 2>/dev/null | \
            awk '{for(i=1;i<=NF;i++) if($i ~ /\.[0-9]+:/) print $i}' | \
            awk -F'.' '{print $NF}' | sed 's/:$//' | \
            sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
    else
        warn "tcpdump не установлен — пропускаю DEEP анализ"
        info "Установи: apt install tcpdump"
    fi
fi

# =============================================================================
# ИТОГ
# =============================================================================
head1 "ИТОГ"

echo -e "  ${G}PASS:${N}  $PASS"
echo -e "  ${Y}WARN:${N}  $WARN"
echo -e "  ${R}FAIL:${N}  $FAIL"
echo ""

if [ "$FAIL" -eq 0 ] && [ "$WARN" -le 2 ]; then
    echo -e "${G}${B}╔══════════════════════════════════════════════════════════╗${N}"
    echo -e "${G}${B}║  Нода в отличном состоянии. Все проверки пройдены.       ║${N}"
    echo -e "${G}${B}╚══════════════════════════════════════════════════════════╝${N}"
    exit 0
elif [ "$FAIL" -eq 0 ]; then
    echo -e "${Y}${B}╔══════════════════════════════════════════════════════════╗${N}"
    echo -e "${Y}${B}║  Нода работает но есть warnings ($WARN). Проверь выше.    ║${N}"
    echo -e "${Y}${B}╚══════════════════════════════════════════════════════════╝${N}"
    exit 0
else
    echo -e "${R}${B}╔══════════════════════════════════════════════════════════╗${N}"
    echo -e "${R}${B}║  Есть проблемы ($FAIL FAIL). Требует внимания.            ║${N}"
    echo -e "${R}${B}╚══════════════════════════════════════════════════════════╝${N}"
    echo ""
    echo "Действия:"
    echo "  - Если 'guard ОТСУТСТВУЕТ' (но кстати v3.23.0 ставит в /usr/local/bin/, не sbin/):"
    echo "      ls /usr/local/bin/guard /usr/local/sbin/guard 2>&1"
    echo "  - Если versions не определены, но sysctl правильный — это OK"
    echo "  - Если UDP errors растут быстро — подними udp_mem cap (см. инструкции выше)"
    echo "  - Полная переустановка: sudo bash clean-reinstall.sh"
    exit 1
fi
