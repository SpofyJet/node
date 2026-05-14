#!/bin/bash
# ==============================================================================
# attack-forensics.sh v1.0
# Полная диагностика атак на ноду — кто, откуда, когда, чем и сколько.
#
# Использование:
#   sudo bash attack-forensics.sh                    # 24h окно (default)
#   sudo bash attack-forensics.sh --hours 6          # последние 6 часов
#   sudo bash attack-forensics.sh --days 7           # последние 7 дней
#   sudo bash attack-forensics.sh --ip 1.2.3.4       # фокус на конкретный IP
#   sudo bash attack-forensics.sh --port 443         # только трафик на порт
#
# Что собирает:
#   1. Top attackers — кто чаще всего попадал в drop правила
#   2. Drops by reason — кого и за что банили (scanner/threat/syn-flood/etc)
#   3. CrowdSec decisions — кого банил CrowdSec
#   4. SSH brute force — попытки подбора паролей
#   5. shieldnode events.db — детальная статистика
#   6. Timeline атак — когда пики
#   7. Geo/ASN анализ — откуда атакующие
#   8. Recent UFW BLOCKs — что не прошло через UFW
#   9. Connection state — текущие conntrack для подозрительных IP
#  10. Анализ конкретного IP (если задан --ip)
# ==============================================================================

set -o pipefail

# =============================================================================
# Аргументы
# =============================================================================
HOURS=24
TARGET_IP=""
TARGET_PORT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --hours) HOURS="$2"; shift 2 ;;
        --days) HOURS=$(( $2 * 24 )); shift 2 ;;
        --ip) TARGET_IP="$2"; shift 2 ;;
        --port) TARGET_PORT="$2"; shift 2 ;;
        --help|-h)
            grep '^#' "$0" | head -20
            exit 0
            ;;
        *) shift ;;
    esac
done

SINCE_TIME="${HOURS} hours ago"

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

head1() { echo ""; echo -e "${B}${C}╔═══ $* ═══${N}"; }
sub() { echo -e "${B}${M}── $* ──${N}"; }

# =============================================================================
# Banner
# =============================================================================
clear
echo -e "${B}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${B}║          ATTACK FORENSICS — VPN NODE                     ║${N}"
echo -e "${B}╚══════════════════════════════════════════════════════════╝${N}"
echo ""
echo -e "Hostname:   ${C}$(hostname)${N}"
echo -e "Дата:       $(date -u)"
echo -e "Окно:       последние ${HOURS} часов"
[ -n "$TARGET_IP" ] && echo -e "Фокус IP:   ${Y}$TARGET_IP${N}"
[ -n "$TARGET_PORT" ] && echo -e "Фокус port: ${Y}$TARGET_PORT${N}"

# =============================================================================
# 1. SHIELDNODE TOP ATTACKERS
# =============================================================================
head1 "1. TOP ATTACKERS ПО SHIELDNODE EVENTS"

if [ -f /var/lib/shieldnode/events.db ]; then
    sub "Топ-20 источников за окно (по hits)"
    sqlite3 /var/lib/shieldnode/events.db <<SQL 2>/dev/null
.mode column
.headers on
.width 16 8 12 30
SELECT
    ip AS "IP",
    SUM(count) AS "hits",
    reason AS "reason",
    asn AS "ASN/Owner"
FROM events
WHERE timestamp >= datetime('now', '-${HOURS} hours')
GROUP BY ip, reason
ORDER BY SUM(count) DESC
LIMIT 20;
SQL

    echo ""
    sub "Total hits by reason (за окно)"
    sqlite3 /var/lib/shieldnode/events.db <<SQL 2>/dev/null
.mode column
.headers on
.width 25 12 10
SELECT
    reason AS "Reason",
    SUM(count) AS "Total hits",
    COUNT(DISTINCT ip) AS "Unique IPs"
FROM events
WHERE timestamp >= datetime('now', '-${HOURS} hours')
GROUP BY reason
ORDER BY SUM(count) DESC;
SQL

    echo ""
    sub "Уникальные атакующие IPs (за окно)"
    UNIQUE_IPS=$(sqlite3 /var/lib/shieldnode/events.db "SELECT COUNT(DISTINCT ip) FROM events WHERE timestamp >= datetime('now', '-${HOURS} hours');" 2>/dev/null)
    TOTAL_HITS=$(sqlite3 /var/lib/shieldnode/events.db "SELECT SUM(count) FROM events WHERE timestamp >= datetime('now', '-${HOURS} hours');" 2>/dev/null)
    echo "  Unique IPs: $UNIQUE_IPS"
    echo "  Total hits: $TOTAL_HITS"
else
    echo "  events.db отсутствует — нет shieldnode aggregator данных"
fi

# =============================================================================
# 2. NFTABLES DROP COUNTERS
# =============================================================================
head1 "2. NFTABLES DROP COUNTERS (текущие, since reboot)"

if nft list table inet ddos_protect >/dev/null 2>&1; then
    echo ""
    sub "Drop counters"
    nft list table inet ddos_protect 2>/dev/null | \
        grep -A1 "counter " | \
        grep -E "packets|counter" | \
        awk '/counter/{name=$2} /packets/{print "  " name ": " $2 " pkts / " $4 "B"}' | \
        head -20
else
    echo "  ddos_protect table не загружена"
fi

# =============================================================================
# 3. KERNEL DROPS LOG (если включён VERBOSE_LOGS)
# =============================================================================
head1 "3. KERNEL DROPS ИЗ JOURNALD"

sub "Top 20 IPs по [shield:*] прямым drop'ам за ${HOURS}h"
SHIELD_DROPS=$(journalctl -k --since "$SINCE_TIME" 2>/dev/null | grep -E '\[shield:' | grep -oE 'SRC=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sed 's/SRC=//' | sort | uniq -c | sort -rn | head -20)
if [ -n "$SHIELD_DROPS" ]; then
    echo "$SHIELD_DROPS" | awk '{printf "  %-8s drops  %s\n", $1, $2}'
else
    echo "  Нет [shield:*] записей (VERBOSE_LOGS=0 или нет атак)"
fi

echo ""
sub "Top 20 IPs по [UFW BLOCK] за ${HOURS}h"
UFW_DROPS=$(journalctl -k --since "$SINCE_TIME" 2>/dev/null | grep '\[UFW BLOCK\]' | grep -oE 'SRC=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sed 's/SRC=//' | sort | uniq -c | sort -rn | head -20)
if [ -n "$UFW_DROPS" ]; then
    echo "$UFW_DROPS" | awk '{printf "  %-8s drops  %s\n", $1, $2}'
else
    echo "  Нет UFW BLOCK записей"
fi

echo ""
sub "Распределение [shield:*] по причинам"
journalctl -k --since "$SINCE_TIME" 2>/dev/null | grep -oE '\[shield:[a-z_]+\]' | sort | uniq -c | sort -rn | head -10 | sed 's/^/  /'

# =============================================================================
# 4. CROWDSEC DECISIONS
# =============================================================================
head1 "4. CROWDSEC ACTIVE DECISIONS"

if command -v cscli >/dev/null 2>&1; then
    sub "Текущие active decisions"
    DECISIONS=$(timeout 10 cscli decisions list 2>/dev/null)
    if [ -n "$DECISIONS" ]; then
        echo "$DECISIONS" | head -30
    fi
    
    echo ""
    sub "Total decisions count"
    TOTAL_DEC=$(timeout 10 cscli decisions list -o raw 2>/dev/null | tail -n +2 | wc -l)
    echo "  Active: $TOTAL_DEC"
    
    echo ""
    sub "Top scenarios (за ${HOURS}h)"
    timeout 10 cscli alerts list --since "${HOURS}h" -o raw 2>/dev/null | \
        awk -F',' 'NR>1 {print $4}' | sort | uniq -c | sort -rn | head -10 | sed 's/^/  /'
else
    echo "  cscli не установлен"
fi

# =============================================================================
# 5. SSH BRUTE FORCE
# =============================================================================
head1 "5. SSH BRUTE FORCE АТАКИ"

sub "Top 20 SSH attackers за ${HOURS}h"
journalctl --since "$SINCE_TIME" -u ssh 2>/dev/null | \
    grep -E "Failed password|Invalid user|Connection closed.*authenticating|preauth" | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
    sort | uniq -c | sort -rn | head -20 | \
    awk '{printf "  %-8s attempts  %s\n", $1, $2}'

echo ""
sub "Top usernames в SSH brute force"
journalctl --since "$SINCE_TIME" -u ssh 2>/dev/null | \
    grep -oE "Invalid user [a-zA-Z0-9_-]+" | \
    awk '{print $3}' | sort | uniq -c | sort -rn | head -10 | sed 's/^/  /'

echo ""
sub "Успешные SSH входы (для контроля)"
journalctl --since "$SINCE_TIME" -u ssh 2>/dev/null | \
    grep "Accepted" | tail -10 | \
    awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ip=$i; print $1" "$2" "$3" user="$9" from="ip}' | \
    head -10 | sed 's/^/  /'

# =============================================================================
# 6. TIMELINE АТАК
# =============================================================================
head1 "6. TIMELINE АТАК (по часам)"

sub "Атаки по часам за ${HOURS}h"
journalctl -k --since "$SINCE_TIME" 2>/dev/null | \
    grep -E '\[(shield:|UFW BLOCK)' | \
    awk '{print $1" "$2" "$3}' | \
    awk -F: '{print $1":00"}' | \
    sort | uniq -c | tail -30 | \
    awk '{printf "  %-25s %s drops\n", $2" "$3" "$4, $1}'

# =============================================================================
# 7. CURRENT CONNECTIONS
# =============================================================================
head1 "7. ТЕКУЩИЕ ПОДОЗРИТЕЛЬНЫЕ СОЕДИНЕНИЯ"

sub "Top 15 IPs по количеству активных TCP подключений"
ss -tan 2>/dev/null | tail -n +2 | \
    awk '$4 !~ /^127\./ && $5 !~ /^127\./ {split($5, a, ":"); print a[1]}' | \
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | \
    sort | uniq -c | sort -rn | head -15 | \
    awk '{printf "  %-8s conns  %s\n", $1, $2}'

echo ""
sub "TCP states distribution"
ss -tan 2>/dev/null | tail -n +2 | awk '{print $1}' | sort | uniq -c | sort -rn | head -10 | sed 's/^/  /'

echo ""
sub "Conntrack utilization"
CT_COUNT=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null)
CT_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
if [ -n "$CT_COUNT" ] && [ -n "$CT_MAX" ]; then
    CT_PCT=$((CT_COUNT * 100 / CT_MAX))
    echo "  $CT_COUNT / $CT_MAX (${CT_PCT}%)"
fi

# =============================================================================
# 8. NETWORK ANOMALIES
# =============================================================================
head1 "8. СЕТЕВЫЕ АНОМАЛИИ"

sub "UDP errors (накопленные)"
UDP_LINE=$(awk '/^Udp:/{getline; print}' /proc/net/snmp)
echo "$UDP_LINE" | awk '{print "  Pkts="$2" InErrors="$3" RcvbufErrors="$5" SndbufErrors="$6}'

echo ""
sub "TCP anomalies (последние 5 минут)"
BEFORE_TCP=$(awk '/^Tcp:/{getline; print $13}' /proc/net/snmp)
BEFORE_RETRANS_PCT=$(awk '/^Tcp:/{getline; if($11>0) printf "%.2f", $13/$11*100}' /proc/net/snmp)
echo "  TCP retransmissions: ${BEFORE_RETRANS_PCT}% (累積)"

echo ""
sub "SYN flood indicators"
SYN_SENT=$(ss -tan state syn-sent 2>/dev/null | wc -l)
SYN_RECV=$(ss -tan state syn-recv 2>/dev/null | wc -l)
echo "  SYN-SENT: $SYN_SENT"
echo "  SYN-RECV: $SYN_RECV (если >100 — возможен SYN flood)"

# =============================================================================
# 9. ФОКУС НА КОНКРЕТНЫЙ IP (если задан --ip)
# =============================================================================
if [ -n "$TARGET_IP" ]; then
    head1 "9. ДЕТАЛЬНЫЙ АНАЛИЗ $TARGET_IP"
    
    sub "shieldnode events.db"
    if [ -f /var/lib/shieldnode/events.db ]; then
        sqlite3 /var/lib/shieldnode/events.db <<SQL 2>/dev/null
.mode column
.headers on
.width 20 25 12 8
SELECT
    datetime(timestamp) AS "Time",
    reason AS "Reason",
    count AS "Hits",
    asn AS "ASN"
FROM events
WHERE ip = '$TARGET_IP'
  AND timestamp >= datetime('now', '-${HOURS} hours')
ORDER BY timestamp DESC
LIMIT 20;
SQL
    fi
    
    echo ""
    sub "В каких nft sets находится"
    for set in custom_blocklist_v4 threat_blocklist_v4 scanner_blocklist_v4 tor_exit_blocklist_v4 confirmed_attack_v4 suspect_v4 manual_whitelist_v4 infrastructure_v4; do
        FOUND=$(nft list set inet ddos_protect $set 2>/dev/null | grep -E "$TARGET_IP")
        if [ -n "$FOUND" ]; then
            echo "  ✓ $set: содержит"
        fi
    done
    
    echo ""
    sub "CrowdSec decisions для $TARGET_IP"
    cscli decisions list -i $TARGET_IP 2>/dev/null
    cscli alerts list -s $TARGET_IP 2>/dev/null | head -10
    
    echo ""
    sub "Kernel log за ${HOURS}h"
    journalctl -k --since "$SINCE_TIME" 2>/dev/null | \
        grep "$TARGET_IP" | tail -20
    
    echo ""
    sub "Активные подключения от $TARGET_IP"
    ss -tan 2>/dev/null | grep "$TARGET_IP" | head -20
    
    echo ""
    sub "Conntrack entries"
    if command -v conntrack >/dev/null 2>&1; then
        conntrack -L 2>/dev/null | grep "$TARGET_IP" | head -10
    fi
    
    echo ""
    sub "GeoIP / ASN info"
    if command -v whois >/dev/null 2>&1; then
        whois "$TARGET_IP" 2>/dev/null | grep -iE "country|netname|org|descr" | head -10 | sed 's/^/  /'
    fi
fi

# =============================================================================
# 10. ФОКУС НА ПОРТ (если задан --port)
# =============================================================================
if [ -n "$TARGET_PORT" ]; then
    head1 "10. АНАЛИЗ ТРАФИКА НА ПОРТ $TARGET_PORT"
    
    sub "Top 20 IPs с подключениями к :$TARGET_PORT"
    ss -tan 2>/dev/null | grep ":$TARGET_PORT " | \
        awk '{split($5, a, ":"); print a[1]}' | \
        sort | uniq -c | sort -rn | head -20 | sed 's/^/  /'
    
    echo ""
    sub "Drops на порт $TARGET_PORT за ${HOURS}h"
    journalctl -k --since "$SINCE_TIME" 2>/dev/null | \
        grep "DPT=$TARGET_PORT " | \
        grep -oE 'SRC=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sed 's/SRC=//' | \
        sort | uniq -c | sort -rn | head -10 | sed 's/^/  /'
fi

# =============================================================================
# 11. РЕКОМЕНДАЦИИ
# =============================================================================
head1 "11. ВЫВОДЫ И РЕКОМЕНДАЦИИ"

# Проверки и предупреждения
WARNINGS=()

# Conntrack
if [ -n "$CT_COUNT" ] && [ -n "$CT_MAX" ] && [ "$CT_PCT" -gt 70 ]; then
    WARNINGS+=("conntrack ${CT_PCT}% — близко к лимиту, рассмотри увеличение")
fi

# SYN flood
if [ "$SYN_RECV" -gt 100 ] 2>/dev/null; then
    WARNINGS+=("SYN-RECV=$SYN_RECV — возможен SYN flood")
fi

# CrowdSec decisions
if [ "$TOTAL_DEC" -gt 50 ] 2>/dev/null; then
    WARNINGS+=("CrowdSec заблокировал $TOTAL_DEC IP — много активных атакующих")
fi

# Recent drops
RECENT_DROPS=$(journalctl -k --since "1 hour ago" 2>/dev/null | grep -cE '\[shield:|UFW BLOCK')
if [ "$RECENT_DROPS" -gt 1000 ]; then
    WARNINGS+=("За последний час $RECENT_DROPS дропов — повышенная активность")
fi

if [ ${#WARNINGS[@]} -eq 0 ]; then
    echo -e "  ${G}✓ Аномалий не обнаружено${N}"
else
    echo -e "  ${Y}Найдены индикаторы атаки:${N}"
    for w in "${WARNINGS[@]}"; do
        echo "    - $w"
    done
fi

echo ""
echo -e "${B}Команды для глубокого анализа:${N}"
echo "  # Анализ конкретного IP"
echo "  sudo bash $0 --ip <IP> --hours $HOURS"
echo ""
echo "  # Анализ конкретного порта"
echo "  sudo bash $0 --port 22 --hours $HOURS"
echo ""
echo "  # Бан подозрительного IP вручную через CrowdSec"
echo "  sudo cscli decisions add --ip <IP> --duration 24h --reason 'manual_ban'"
echo ""
echo "  # Live tcpdump на порт (для активной атаки)"
echo "  sudo tcpdump -i any -nn 'port 443 and tcp[tcpflags] & tcp-syn != 0' -c 100"
echo ""

echo -e "${B}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${B}║  Forensics завершён                                       ║${N}"
echo -e "${B}╚══════════════════════════════════════════════════════════╝${N}"
