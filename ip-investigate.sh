#!/bin/bash
# ==============================================================================
# ip-investigate.sh v1.0
# Глубокий анализ одного IP — атакующий он или нет.
#
# Использование:
#   sudo bash ip-investigate.sh <IP>
#   sudo bash ip-investigate.sh 45.148.10.192
#
# Что проверяет:
#   1. WHOIS — кто владелец, страна, ASN, тип сети (hosting/ISP/datacenter)
#   2. Reverse DNS — есть ли PTR запись (легитимные сервисы её имеют)
#   3. Public reputation — AbuseIPDB scoring, Shodan известность
#   4. Локальная история — что делал на нашей ноде
#   5. Pattern analysis — какие порты, как часто, какой паттерн
#   6. ВЕРДИКТ — атакующий с какой confidence
# ==============================================================================

set -o pipefail

IP="$1"
if [ -z "$IP" ]; then
    echo "Использование: sudo bash $0 <IP>"
    echo "Пример: sudo bash $0 45.148.10.192"
    exit 1
fi

if ! echo "$IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Невалидный IP: $IP"
    exit 1
fi

# Colors
if [ -t 1 ]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
    C='\033[0;36m'; B='\033[1m'; D='\033[2m'; N='\033[0m'
else
    R='' G='' Y='' C='' B='' D='' N=''
fi

# Confidence scoring
ATTACK_SCORE=0
LEGITIMATE_SCORE=0
RED_FLAGS=()
GREEN_FLAGS=()

head1() { echo ""; echo -e "${B}${C}═══ $* ═══${N}"; }
flag_red() { RED_FLAGS+=("$1"); ATTACK_SCORE=$((ATTACK_SCORE + ${2:-1})); }
flag_green() { GREEN_FLAGS+=("$1"); LEGITIMATE_SCORE=$((LEGITIMATE_SCORE + ${2:-1})); }

echo -e "${B}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${B}║          IP INVESTIGATION: $IP${N}"
echo -e "${B}╚══════════════════════════════════════════════════════════╝${N}"

# =============================================================================
# 1. WHOIS — owner, country, network type
# =============================================================================
head1 "1. WHOIS / RDAP"

if command -v whois >/dev/null 2>&1; then
    WHOIS_OUTPUT=$(timeout 10 whois "$IP" 2>/dev/null)
    
    COUNTRY=$(echo "$WHOIS_OUTPUT" | grep -iE "^country:" | head -1 | awk -F: '{gsub(/^ +| +$/, "", $2); print $2}')
    ORG=$(echo "$WHOIS_OUTPUT" | grep -iE "^(orgname|org-name|owner|netname):" | head -1 | awk -F: '{gsub(/^ +| +$/, "", $2); print $2}')
    DESCR=$(echo "$WHOIS_OUTPUT" | grep -iE "^descr:" | head -3 | awk -F: '{gsub(/^ +| +$/, "", $2); print $2}' | tr '\n' '; ')
    NETNAME=$(echo "$WHOIS_OUTPUT" | grep -iE "^netname:" | head -1 | awk -F: '{gsub(/^ +| +$/, "", $2); print $2}')
    ABUSE=$(echo "$WHOIS_OUTPUT" | grep -iE "abuse.*email|abuse-mailbox" | head -1)
    
    echo "  Country: $COUNTRY"
    echo "  Network: $NETNAME"
    echo "  Owner:   $ORG"
    echo "  Descr:   $DESCR"
    
    # Hosting/Datacenter detection
    DC_KEYWORDS="hosting|datacenter|server|vps|cloud|dedicated|colo|leaseweb|ovh|hetzner|digitalocean|linode|vultr|aws|azure|gcp|alibaba|tencent"
    if echo "$ORG $DESCR $NETNAME" | grep -qiE "$DC_KEYWORDS"; then
        echo -e "  ${Y}⚠ Hosting/Datacenter network${N}"
        flag_red "Hosting/datacenter network (повышенная вероятность scanner/bot)" 2
    fi
    
    # Known security scanner orgs
    SCANNER_KEYWORDS="shodan|censys|rapid7|qualys|tenable|netcraft|modat|alphabit|onyphe|criminalip|stretchoid|cyberresilience"
    if echo "$ORG $DESCR $NETNAME" | grep -qiE "$SCANNER_KEYWORDS"; then
        echo -e "  ${Y}⚠ Известный security scanner${N}"
        flag_red "Security scanner (не атакует, но не нужен)" 3
    fi
    
    # ISP keywords (legitimate users)
    ISP_KEYWORDS="telecom|broadband|cable|fiber|residential|isp|телеком|provider|wireless|mobile"
    if echo "$ORG $DESCR $NETNAME" | grep -qiE "$ISP_KEYWORDS"; then
        echo -e "  ${G}ℹ ISP/Residential network${N}"
        flag_green "ISP/residential network (может быть legitimate юзер)" 2
    fi
else
    echo "  whois не установлен (sudo apt install whois)"
fi

# =============================================================================
# 2. Reverse DNS (PTR)
# =============================================================================
head1 "2. REVERSE DNS (PTR)"

PTR=$(timeout 5 dig +short -x "$IP" 2>/dev/null | head -1 | sed 's/\.$//')
if [ -n "$PTR" ]; then
    echo "  PTR: $PTR"
    
    # Анализ PTR
    if echo "$PTR" | grep -qiE "scan|probe|crawl|bot|spider"; then
        flag_red "PTR содержит scan/probe/crawl (явный scanner)" 3
    elif echo "$PTR" | grep -qiE "mail|smtp|imap"; then
        flag_green "PTR указывает на mail сервер (вряд ли атакует)" 1
    elif echo "$PTR" | grep -qiE "static|dynamic|residential|home|dhcp"; then
        flag_green "PTR residential/dynamic (вероятно реальный юзер)" 1
    elif echo "$PTR" | grep -qiE "vps|server|host|cloud"; then
        flag_red "PTR указывает на VPS/hosting" 1
    fi
else
    echo -e "  ${Y}Нет PTR записи${N}"
    flag_red "Нет reverse DNS (часто у scanner/bot)" 1
fi

# =============================================================================
# 3. AbuseIPDB / Public reputation
# =============================================================================
head1 "3. PUBLIC REPUTATION"

# Без API можно проверить через curl публичный endpoint
echo "  Проверь вручную:"
echo "    AbuseIPDB:  https://www.abuseipdb.com/check/$IP"
echo "    Shodan:     https://www.shodan.io/host/$IP"
echo "    IPInfo:     https://ipinfo.io/$IP"

# Если есть API ключ AbuseIPDB
if [ -n "${ABUSEIPDB_KEY:-}" ]; then
    SCORE=$(curl -s -G "https://api.abuseipdb.com/api/v2/check" \
        --data-urlencode "ipAddress=$IP" \
        --data-urlencode "maxAgeInDays=90" \
        -H "Key: $ABUSEIPDB_KEY" \
        -H "Accept: application/json" | grep -oE '"abuseConfidenceScore":[0-9]+' | grep -oE '[0-9]+')
    
    if [ -n "$SCORE" ]; then
        echo "  AbuseIPDB Confidence: ${SCORE}%"
        if [ "$SCORE" -gt 75 ]; then
            flag_red "AbuseIPDB ${SCORE}% — известный атакующий" 5
        elif [ "$SCORE" -gt 25 ]; then
            flag_red "AbuseIPDB ${SCORE}% — подозрительный" 3
        elif [ "$SCORE" -eq 0 ]; then
            flag_green "AbuseIPDB 0% — нет жалоб" 1
        fi
    fi
fi

# =============================================================================
# 4. ЛОКАЛЬНАЯ ИСТОРИЯ
# =============================================================================
head1 "4. ЛОКАЛЬНАЯ ИСТОРИЯ НА ЭТОЙ НОДЕ"

# CrowdSec
echo ""
echo -e "${D}-- CrowdSec history --${N}"
DECISIONS=$(timeout 5 cscli decisions list -i "$IP" 2>/dev/null | grep -v "^+" | grep -v "^|.\\+|" | wc -l)
ALERTS=$(timeout 5 cscli alerts list -s "$IP" 2>/dev/null | grep -v "^+" | grep -v "^|.\\+|" | wc -l)
echo "  Active decisions: $DECISIONS"
echo "  Past alerts:      $ALERTS"

if [ "$DECISIONS" -gt 0 ]; then
    flag_red "CrowdSec уже забанил" 4
fi
if [ "$ALERTS" -gt 5 ]; then
    flag_red "CrowdSec алёрты $ALERTS раз" 2
fi

# В nft blocklists
echo ""
echo -e "${D}-- В каких nft sets --${N}"
for set in custom_blocklist_v4 threat_blocklist_v4 scanner_blocklist_v4 tor_exit_blocklist_v4 confirmed_attack_v4 suspect_v4 manual_whitelist_v4 infrastructure_v4; do
    if nft list set inet ddos_protect "$set" 2>/dev/null | grep -qE "(^|[^0-9])$IP([^0-9]|$)"; then
        echo "  ✓ $set"
        case "$set" in
            confirmed_attack_v4) flag_red "Уже в confirmed_attack_v4 (повторные нарушения)" 5 ;;
            scanner_blocklist_v4) flag_red "В scanner_blocklist (Shodan/Censys)" 2 ;;
            threat_blocklist_v4) flag_red "В threat_blocklist (Spamhaus/FireHOL)" 4 ;;
            tor_exit_blocklist_v4) flag_red "Tor exit node" 1 ;;
            custom_blocklist_v4) flag_red "В custom blocklist" 2 ;;
            manual_whitelist_v4|infrastructure_v4) flag_green "В whitelist" 5 ;;
        esac
    fi
done

# Drops за последние 24 часа
echo ""
echo -e "${D}-- Drops за 24h (kernel log) --${N}"
SHIELD_DROPS=$(journalctl -k --since "24 hours ago" 2>/dev/null | grep -E "\[shield:" | grep -c "$IP")
UFW_DROPS=$(journalctl -k --since "24 hours ago" 2>/dev/null | grep "\[UFW BLOCK\]" | grep -c "$IP")
echo "  shield drops: $SHIELD_DROPS"
echo "  UFW drops:    $UFW_DROPS"

TOTAL_DROPS=$((SHIELD_DROPS + UFW_DROPS))
if [ "$TOTAL_DROPS" -gt 1000 ]; then
    flag_red "Огромное количество drops ($TOTAL_DROPS за 24h)" 4
elif [ "$TOTAL_DROPS" -gt 100 ]; then
    flag_red "Много drops ($TOTAL_DROPS за 24h)" 2
elif [ "$TOTAL_DROPS" -gt 10 ]; then
    flag_red "Drops ($TOTAL_DROPS за 24h)" 1
fi

# =============================================================================
# 5. PATTERN ANALYSIS
# =============================================================================
head1 "5. PATTERN АНАЛИЗ"

# Какие порты пытался
echo ""
echo -e "${D}-- Top 10 destination ports от $IP за 24h --${N}"
DPT_LIST=$(journalctl -k --since "24 hours ago" 2>/dev/null | grep "$IP" | grep -oE "DPT=[0-9]+" | sort | uniq -c | sort -rn | head -10)
if [ -n "$DPT_LIST" ]; then
    echo "$DPT_LIST" | sed 's/^/  /'
    
    # Detection: SSH brute force
    SSH_HITS=$(echo "$DPT_LIST" | awk '$2 == "DPT=22"' | awk '{print $1}')
    if [ -n "$SSH_HITS" ] && [ "$SSH_HITS" -gt 50 ]; then
        flag_red "Активный SSH brute force ($SSH_HITS попыток)" 4
    fi
    
    # Detection: port scan (много разных портов)
    UNIQUE_PORTS=$(echo "$DPT_LIST" | wc -l)
    if [ "$UNIQUE_PORTS" -ge 10 ]; then
        flag_red "Port scan ($UNIQUE_PORTS разных портов)" 3
    fi
    
    # Detection: только VPN порты
    VPN_PORTS=$(echo "$DPT_LIST" | grep -cE "DPT=(443|2096|8443|2053|2083|2087)")
    if [ "$VPN_PORTS" -gt 0 ] && [ "$UNIQUE_PORTS" -le 3 ]; then
        echo -e "  ${Y}Только VPN порты — возможно legitimate юзер с устаревшим конфигом${N}"
        flag_green "Только VPN порты (может быть юзер)" 1
    fi
else
    echo "  Нет данных"
fi

# Timing pattern
echo ""
echo -e "${D}-- Timing pattern --${N}"
HITS_BY_HOUR=$(journalctl -k --since "24 hours ago" 2>/dev/null | grep "$IP" | awk '{print $3}' | awk -F: '{print $1}' | sort | uniq -c)
if [ -n "$HITS_BY_HOUR" ]; then
    HOURS_ACTIVE=$(echo "$HITS_BY_HOUR" | wc -l)
    echo "  Активен $HOURS_ACTIVE часов из 24"
    if [ "$HOURS_ACTIVE" -gt 20 ]; then
        flag_red "Активен почти круглосуточно (автоматизированный bot)" 2
    fi
fi

# Активные соединения сейчас
echo ""
echo -e "${D}-- Активные соединения сейчас --${N}"
ACTIVE_CONNS=$(ss -tan 2>/dev/null | grep -c "$IP")
echo "  Активных TCP: $ACTIVE_CONNS"
if [ "$ACTIVE_CONNS" -gt 50 ]; then
    flag_red "Очень много активных соединений ($ACTIVE_CONNS)" 2
fi

# shieldnode events.db
if [ -f /var/lib/shieldnode/events.db ]; then
    echo ""
    echo -e "${D}-- shieldnode events.db --${N}"
    EVENT_COUNT=$(sqlite3 /var/lib/shieldnode/events.db "SELECT SUM(count) FROM events WHERE ip='$IP' AND timestamp >= datetime('now', '-7 days');" 2>/dev/null)
    REASONS=$(sqlite3 /var/lib/shieldnode/events.db "SELECT GROUP_CONCAT(DISTINCT reason) FROM events WHERE ip='$IP' AND timestamp >= datetime('now', '-7 days');" 2>/dev/null)
    if [ -n "$EVENT_COUNT" ] && [ "$EVENT_COUNT" != "" ]; then
        echo "  Events за 7d: $EVENT_COUNT"
        echo "  Reasons: $REASONS"
    fi
fi

# =============================================================================
# 6. ВЕРДИКТ
# =============================================================================
head1 "ВЕРДИКТ"

echo ""
echo -e "${B}RED FLAGS (attack score: $ATTACK_SCORE):${N}"
if [ ${#RED_FLAGS[@]} -eq 0 ]; then
    echo "  (нет)"
else
    for f in "${RED_FLAGS[@]}"; do
        echo -e "  ${R}✗${N} $f"
    done
fi

echo ""
echo -e "${B}GREEN FLAGS (legitimate score: $LEGITIMATE_SCORE):${N}"
if [ ${#GREEN_FLAGS[@]} -eq 0 ]; then
    echo "  (нет)"
else
    for f in "${GREEN_FLAGS[@]}"; do
        echo -e "  ${G}✓${N} $f"
    done
fi

echo ""
NET_SCORE=$((ATTACK_SCORE - LEGITIMATE_SCORE))
echo -e "${B}Net score: $NET_SCORE${N} (attack=$ATTACK_SCORE, legit=$LEGITIMATE_SCORE)"

echo ""
if [ "$NET_SCORE" -ge 8 ]; then
    echo -e "${R}${B}╔══════════════════════════════════════════════════════════╗${N}"
    echo -e "${R}${B}║  ВЕРДИКТ: 100% АТАКУЮЩИЙ — БАНИТЬ НАВСЕГДА                ║${N}"
    echo -e "${R}${B}╚══════════════════════════════════════════════════════════╝${N}"
    echo ""
    echo "Команда:"
    echo "  sudo cscli decisions add --ip $IP --duration 30d --reason 'confirmed_attacker'"
    VERDICT="ATTACK_CERTAIN"
elif [ "$NET_SCORE" -ge 5 ]; then
    echo -e "${R}${B}╔══════════════════════════════════════════════════════════╗${N}"
    echo -e "${R}${B}║  ВЕРДИКТ: ВЫСОКАЯ ВЕРОЯТНОСТЬ АТАКИ — БАНИТЬ              ║${N}"
    echo -e "${R}${B}╚══════════════════════════════════════════════════════════╝${N}"
    echo ""
    echo "Команда:"
    echo "  sudo cscli decisions add --ip $IP --duration 7d --reason 'high_confidence_attack'"
    VERDICT="ATTACK_LIKELY"
elif [ "$NET_SCORE" -ge 2 ]; then
    echo -e "${Y}${B}╔══════════════════════════════════════════════════════════╗${N}"
    echo -e "${Y}${B}║  ВЕРДИКТ: ПОДОЗРИТЕЛЬНЫЙ — БАН НА ИСПЫТАТЕЛЬНЫЙ СРОК      ║${N}"
    echo -e "${Y}${B}╚══════════════════════════════════════════════════════════╝${N}"
    echo ""
    echo "Команда (24 часа для проверки жалоб):"
    echo "  sudo cscli decisions add --ip $IP --duration 24h --reason 'review_suspicious'"
    VERDICT="SUSPICIOUS"
elif [ "$NET_SCORE" -le -3 ]; then
    echo -e "${G}${B}╔══════════════════════════════════════════════════════════╗${N}"
    echo -e "${G}${B}║  ВЕРДИКТ: LEGITIMATE — НЕ ТРОГАТЬ                         ║${N}"
    echo -e "${G}${B}╚══════════════════════════════════════════════════════════╝${N}"
    VERDICT="LEGITIMATE"
else
    echo -e "${C}${B}╔══════════════════════════════════════════════════════════╗${N}"
    echo -e "${C}${B}║  ВЕРДИКТ: НЕОДНОЗНАЧНО — НУЖЕН РУЧНОЙ АНАЛИЗ              ║${N}"
    echo -e "${C}${B}╚══════════════════════════════════════════════════════════╝${N}"
    echo ""
    echo "Рекомендуется проверить вручную AbuseIPDB:"
    echo "  https://www.abuseipdb.com/check/$IP"
    VERDICT="AMBIGUOUS"
fi

echo ""
echo -e "${D}Что делать сейчас:${N}"
case "$VERDICT" in
    ATTACK_CERTAIN|ATTACK_LIKELY)
        echo "  1. Забань командой выше"
        echo "  2. Проверь не было ли legitimate юзеров через этот IP:"
        echo "     ss -tan 2>/dev/null | grep $IP"
        ;;
    SUSPICIOUS)
        echo "  1. 24h бан → подожди → проверь жалобы юзеров"
        echo "  2. Если жалоб нет — extend до 30d"
        ;;
    AMBIGUOUS)
        echo "  1. Проверь AbuseIPDB вручную"
        echo "  2. Если score >50% — бан на 7d"
        echo "  3. Если <25% — оставь как есть"
        ;;
    LEGITIMATE)
        echo "  Ничего не делай. Возможно legitimate юзер с устаревшим VPN config."
        ;;
esac

echo ""
