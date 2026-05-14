#!/bin/bash
# ==============================================================================
# baseline-check.sh
# Замер текущего состояния ноды ПЕРЕД upgrade на v5.1.0 / v3.23.0.
# Покажет ровно те метрики которые скрипты улучшают, чтобы потом сравнить.
#
# Использование: sudo bash baseline-check.sh
# ==============================================================================

set -o pipefail

# Colors
if [ -t 1 ]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
    C='\033[0;36m'; B='\033[1m'; D='\033[2m'; N='\033[0m'
else
    R='' G='' Y='' C='' B='' D='' N=''
fi

echo -e "${B}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${B}║   BASELINE CHECK (до upgrade на v5.1.0 / v3.23.0)       ║${N}"
echo -e "${B}╚══════════════════════════════════════════════════════════╝${N}"
echo ""
echo -e "Hostname:    ${C}$(hostname)${N}"
echo -e "Дата:        $(date -u)"
echo -e "RAM:         $(awk '/MemTotal/{printf "%d MB\n", $2/1024}' /proc/meminfo)"
echo -e "Kernel:      $(uname -r)"
echo -e "Uptime:      $(uptime -p)"

echo ""
echo -e "${B}${C}== 1. ТЕКУЩИЕ ВЕРСИИ ==${N}"
NODE_VER=$(cat /var/lib/vpn-node-builder/.version 2>/dev/null || echo "?")
echo "  vpn-node-setup: $NODE_VER"
if command -v guard >/dev/null 2>&1; then
    # Старые guard выводят версию в разных форматах
    SHIELD_VER=$(guard --json 2>/dev/null | grep -oE '"version":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -z "$SHIELD_VER" ] && SHIELD_VER=$(guard 2>/dev/null | grep -oE 'shieldnode v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -z "$SHIELD_VER" ] && SHIELD_VER="? (guard есть, но версию не определить)"
    echo "  shieldnode:     $SHIELD_VER"
else
    echo "  shieldnode:     NOT INSTALLED"
fi

echo ""
echo -e "${B}${C}== 2. SYSCTL — ЧТО ЛЕЧАТ СКРИПТЫ ==${N}"
echo ""
echo -e "${B}UDP buffer (главный fix v5.1.0):${N}"
UDP_RMEM_MIN=$(sysctl -n net.ipv4.udp_rmem_min 2>/dev/null)
UDP_WMEM_MIN=$(sysctl -n net.ipv4.udp_wmem_min 2>/dev/null)
RMEM_DEFAULT=$(sysctl -n net.core.rmem_default 2>/dev/null)
WMEM_DEFAULT=$(sysctl -n net.core.wmem_default 2>/dev/null)
echo "  udp_rmem_min:        $UDP_RMEM_MIN $([ "$UDP_RMEM_MIN" -lt 8388608 ] 2>/dev/null && echo "${R}<<< будет 8388608${N}")"
echo "  udp_wmem_min:        $UDP_WMEM_MIN $([ "$UDP_WMEM_MIN" -lt 8388608 ] 2>/dev/null && echo "${R}<<< будет 8388608${N}")"
echo "  rmem_default:        $RMEM_DEFAULT $([ "$RMEM_DEFAULT" -lt 2097152 ] 2>/dev/null && echo "${R}<<< будет минимум 2MB${N}")"
echo "  wmem_default:        $WMEM_DEFAULT"

echo ""
echo -e "${B}TCP settings (v5.0.5+):${N}"
echo "  tcp_congestion:      $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
echo "  default_qdisc:       $(sysctl -n net.core.default_qdisc 2>/dev/null)"
echo "  tcp_fastopen:        $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null) $([ "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)" != "3" ] && echo "${Y}<<< будет 3${N}")"
echo "  tcp_adv_win_scale:   $(sysctl -n net.ipv4.tcp_adv_win_scale 2>/dev/null) $([ "$(sysctl -n net.ipv4.tcp_adv_win_scale 2>/dev/null)" != "-2" ] && echo "${Y}<<< будет -2${N}")"

echo ""
echo -e "${B}Shieldnode security (v3.23.0):${N}"
LOG_MARTIANS=$(sysctl -n net.ipv4.conf.all.log_martians 2>/dev/null)
SYNACK=$(sysctl -n net.ipv4.tcp_synack_retries 2>/dev/null)
UDP_STREAM=$(sysctl -n net.netfilter.nf_conntrack_udp_timeout_stream 2>/dev/null)
echo "  log_martians:        $LOG_MARTIANS $([ "$LOG_MARTIANS" = "1" ] && echo "${Y}<<< будет 0 (меньше шума)${N}")"
echo "  tcp_synack_retries:  $SYNACK $([ "$SYNACK" -lt 3 ] 2>/dev/null && echo "${Y}<<< будет 3${N}")"
echo "  udp_timeout_stream:  $UDP_STREAM $([ "$UDP_STREAM" -lt 600 ] 2>/dev/null && echo "${Y}<<< будет 600${N}")"

echo ""
echo -e "${B}Conntrack:${N}"
CT_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
CT_COUNT=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null)
CT_PCT=0
[ "$CT_MAX" -gt 0 ] 2>/dev/null && CT_PCT=$((CT_COUNT * 100 / CT_MAX))
echo "  conntrack_max:       $CT_MAX"
echo "  conntrack_count:     $CT_COUNT (${CT_PCT}% utilization)"
echo "  tcp_established:     $(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null)"

echo ""
echo -e "${B}${C}== 3. SYSCTL ФАЙЛЫ (текущая конфигурация) ==${N}"
echo "Файлы которые мы знаем:"
for f in 80-vpn-node-tuning 90-shieldnode 99-vpn-node-tuning 99-xray-tuning 99-conntrack 99-shieldnode 99-z-udp-fix; do
    if [ -f "/etc/sysctl.d/$f.conf" ]; then
        echo "  ✓ /etc/sysctl.d/$f.conf ($(stat -c '%y' /etc/sysctl.d/$f.conf | cut -d' ' -f1))"
    fi
done

echo ""
echo -e "${B}${C}== 4. NETWORK SNAPSHOT ==${N}"
TCP_SOCKETS=$(ss -tan 2>/dev/null | wc -l)
UDP_SOCKETS=$(ss -uan 2>/dev/null | wc -l)
TCP_ESTAB=$(ss -tan state established 2>/dev/null | wc -l)
echo "  TCP sockets:         $TCP_SOCKETS"
echo "  UDP sockets:         $UDP_SOCKETS"
echo "  TCP established:     $TCP_ESTAB"

# TCP retrans %
TCP_RETRANS_PCT=$(awk '/^Tcp:/{getline; if($11>0) printf "%.2f", $13/$11*100}' /proc/net/snmp 2>/dev/null)
echo "  TCP retrans:         ${TCP_RETRANS_PCT}%"

echo ""
echo -e "${B}${C}== 5. UDP ERRORS — ГЛАВНАЯ МЕТРИКА ==${N}"
echo ""
UDP_LINE=$(awk '/^Udp:/{getline; print}' /proc/net/snmp)
UDP_PKTS=$(echo $UDP_LINE | awk '{print $2}')
UDP_IN_ERR=$(echo $UDP_LINE | awk '{print $3}')
UDP_RCVBUF_ERR=$(echo $UDP_LINE | awk '{print $5}')
UDP_SNDBUF_ERR=$(echo $UDP_LINE | awk '{print $6}')

echo "  Накопленные с момента старта системы:"
echo "    UDP packets in:    $UDP_PKTS"
echo "    UDP InErrors:      $UDP_IN_ERR"
echo "    RcvbufErrors:      $UDP_RCVBUF_ERR  ${R}<<< ВОТ ЭТО ЛЕЧИТ v5.1.0${N}"
echo "    SndbufErrors:      $UDP_SNDBUF_ERR"

echo ""
echo -e "  ${B}${Y}Замеряю скорость роста RcvbufErrors за 60 секунд...${N}"
BEFORE=$UDP_RCVBUF_ERR
T0=$(date +%s)
for i in $(seq 1 6); do
    sleep 10
    ELAPSED=$((i * 10))
    CURRENT=$(awk '/^Udp:/{getline; print $5}' /proc/net/snmp)
    DELTA=$((CURRENT - BEFORE))
    echo -ne "\r  ${ELAPSED}s: +$DELTA errors  ($((DELTA / ELAPSED))/sec)        "
done
echo ""

T1=$(date +%s)
ELAPSED=$((T1 - T0))
DELTA=$((CURRENT - BEFORE))
RATE=$((DELTA / ELAPSED))
RATE_PER_MIN=$((RATE * 60))

echo ""
echo -e "  ${B}Итого за ${ELAPSED}s:${N}"
echo "    Delta:             $DELTA errors"
echo "    Rate:              ${RATE}/sec ($RATE_PER_MIN/min)"
echo ""

if [ "$DELTA" -eq 0 ]; then
    echo -e "  ${G}✓ RcvbufErrors не растут — UDP fix уже применён или нагрузка низкая${N}"
elif [ "$DELTA" -lt 50 ]; then
    echo -e "  ${G}✓ Низкая скорость роста (норма)${N}"
elif [ "$DELTA" -lt 500 ]; then
    echo -e "  ${Y}⚠ Средняя скорость роста (вероятно UDP fix помог бы)${N}"
elif [ "$DELTA" -lt 5000 ]; then
    echo -e "  ${R}!! Высокая скорость — UDP fix должен значительно улучшить${N}"
else
    echo -e "  ${R}!!! ОЧЕНЬ высокая — UDP fix критически нужен${N}"
fi

echo ""
echo -e "${B}${C}== 6. UDP MEMORY ==${N}"
SOCKSTAT_UDP=$(grep -E "^UDP[: ]" /proc/net/sockstat 2>/dev/null | head -1)
if [ -n "$SOCKSTAT_UDP" ]; then
    UDP_INUSE=$(echo "$SOCKSTAT_UDP" | grep -oE "inuse [0-9]+" | awk '{print $2}')
    UDP_MEM_PAGES=$(echo "$SOCKSTAT_UDP" | grep -oE "mem [0-9]+" | awk '{print $2}')
    UDP_MEM_USED_MB=$((UDP_MEM_PAGES * 4 / 1024))
    echo "  UDP sockets in use:  $UDP_INUSE"
    echo "  UDP memory used:     ${UDP_MEM_USED_MB} MB"
fi

echo ""
echo -e "${B}${C}== 7. NFTABLES ==${N}"
if nft list tables 2>/dev/null | grep -q ddos_protect; then
    SHIELD_RULES=$(nft list table inet ddos_protect 2>/dev/null | grep -cE "^[[:space:]]*(ip|tcp|udp|ct|fib|meta)")
    echo "  inet ddos_protect:   $SHIELD_RULES rules"
else
    echo "  inet ddos_protect:   NOT LOADED (shieldnode не активен?)"
fi
if nft list tables 2>/dev/null | grep -q vpn_node_mss_clamp; then
    MSS_RULES=$(nft list table inet vpn_node_mss_clamp 2>/dev/null | grep -c "mss")
    echo "  vpn_node_mss_clamp:  $MSS_RULES MSS rules"
else
    echo "  vpn_node_mss_clamp:  NOT LOADED"
fi

echo ""
echo -e "${B}${C}== 8. DOCKER / NIC ==${N}"
if command -v docker >/dev/null 2>&1; then
    CONTAINERS=$(docker ps --format '{{.Names}}: {{.Status}}' 2>/dev/null | head -3)
    [ -n "$CONTAINERS" ] && echo "$CONTAINERS" | sed 's/^/  /'
fi
IFACE=$(ip route | awk '/default/{print $5; exit}')
if [ -n "$IFACE" ]; then
    DRIVER=$(ethtool -i "$IFACE" 2>/dev/null | awk '/^driver:/{print $2}')
    RX_RING=$(ethtool -g "$IFACE" 2>/dev/null | awk '/^RX:/{print $2; exit}' | grep -v ":")
    COMBINED=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Combined:/{print $2; exit}')
    echo "  NIC:                 $IFACE (driver: $DRIVER)"
    echo "  Ring buffer RX:      $RX_RING"
    echo "  Queues max:          $COMBINED"
fi

echo ""
echo -e "${B}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${B}║                       ИТОГ                                ║${N}"
echo -e "${B}╚══════════════════════════════════════════════════════════╝${N}"
echo ""
echo -e "Сохрани этот вывод. После upgrade на v5.1.0 / v3.23.0 запусти ${C}node-check.sh${N}"
echo "и сравни:"
echo "  - RcvbufErrors growth rate должен сильно упасть"
echo "  - sysctl значения станут правильные"
echo "  - Жёлтые пометки исчезнут"
echo ""
echo "Главная метрика для сравнения:"
echo -e "  ${B}СЕЙЧАС:${N} ${RATE}/sec RcvbufErrors growth"
echo -e "  ${B}ЦЕЛЬ:${N}   < 50/sec"
