#!/usr/bin/env bash
#
# node-audit.sh — глобальный аудит VPN-ноды (read-only)
# Version: 1.0.0
#
# Проверяет ВСЮ систему на недочёты после применения vpn-node-setup.sh
# и shieldnode.sh: ресурсы, kernel/BBR, sysctl drift, сервисы, nftables
# (parse-check + whitelist drift), UFW, conntrack, логи/OOM, время,
# контракт stack.conf. Ничего не меняет — только диагностика.
#
# Использование:
#   sudo bash node-audit.sh              # полный аудит
#   sudo bash node-audit.sh --no-logs    # пропустить скан journal (быстрее)
#   bash node-audit.sh --no-color        # без цветов (лог-файл)
#
# Exit code: 0 = всё OK, 1 = есть WARN, 2 = есть FAIL
#
# Гарантия read-only: скрипт НИЧЕГО не пишет в систему (нет rm/mv/systemctl
# действий, nft только list/-c). Можно запускать в проде в любое время.

# Changelog:
#   1.0.1 — fix: failed units показывали '●' вместо имён (--plain + strip ●);
#           fix: parse-check давал ложный FAIL — 'nft list ruleset | nft -c -f -'
#           падает с EEXIST на существующих table (это add-семантика!). Теперь
#           prepend 'flush ruleset' — транзакция валидируется целиком, -c (check)
#           НИКОГДА не применяет изменения, read-only гарантия сохраняется;
#           add: сумма named counters (nft list counters) в drop-статистике;
#           add: VPN core detection через docker ps (xray/remnawave в контейнере).
#   1.0.2 — add: секция 3.5 MEMORY/IO/DOCKER — проверки тюнинга v5.11.0:
#           THP=madvise (не always), I/O scheduler=none на SSD/virtio,
#           docker daemon.json (live-restore + log rotation).
#   1.0.3 — add: проверки тюнинга v5.12.0 (SSD/NVMe): noatime на /, discard
#           в fstab (WARN — sync TRIM), add_random=0, dirty writeback лимиты;
#           fix: scheduler-check — vd/xvd без rotational-guard (virtio бывает
#           misreport=1, scheduling всё равно делает гипервизор).
#   1.0.4 — add: mmcblk[0-9] (eMMC/SD) в device-паттерны scheduler/add_random
#           (зеркало v5.12.1 compat pass).

set -u
AUDIT_VERSION="1.0.4"

# ─── Опции ────────────────────────────────────────────────────────────────
OPT_LOGS=1
OPT_COLOR=1
for a in "$@"; do
    case "$a" in
        --no-logs)  OPT_LOGS=0 ;;
        --no-color) OPT_COLOR=0 ;;
        -h|--help)
            grep -E '^#( |$)' "$0" | head -20 | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Неизвестная опция: $a (см. --help)" >&2; exit 64 ;;
    esac
done

# ─── Цвета и счётчики ────────────────────────────────────────────────────
if [ "$OPT_COLOR" = "1" ] && [ -t 1 ]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
    C_CYN=$'\033[0;36m'; C_DIM=$'\033[2m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_DIM=""; C_BLD=""; C_RST=""
fi

N_OK=0; N_WARN=0; N_FAIL=0
FAIL_LIST=""; WARN_LIST=""

ok()   { N_OK=$((N_OK+1));   printf '  %s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$1"; }
warn() { N_WARN=$((N_WARN+1)); WARN_LIST="$WARN_LIST\n  - $1"; printf '  %s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$1"; }
fail() { N_FAIL=$((N_FAIL+1)); FAIL_LIST="$FAIL_LIST\n  - $1"; printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$1"; }
info() { printf '  %s[INFO]%s %s\n' "$C_DIM" "$C_RST" "$1"; }
sect() { printf '\n%s=== %s ===%s\n' "$C_BLD$C_CYN" "$1" "$C_RST"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Активен ли systemd unit (любого типа)
unit_active() { systemctl is-active "$1" >/dev/null 2>&1; }
unit_exists() { systemctl list-unit-files "$1" >/dev/null 2>&1 || systemctl status "$1" >/dev/null 2>&1; }

IS_ROOT=0; [ "$(id -u 2>/dev/null)" = "0" ] && IS_ROOT=1

printf '%s╔══════════════════════════════════════════════════════════╗%s\n' "$C_CYN" "$C_RST"
printf '%s║  node-audit.sh v%s — глобальный аудит VPN-ноды          ║%s\n' "$C_CYN" "$AUDIT_VERSION" "$C_RST"
printf '%s║  read-only: система НЕ изменяется                        ║%s\n' "$C_CYN" "$C_RST"
printf '%s╚══════════════════════════════════════════════════════════╝%s\n' "$C_CYN" "$C_RST"
info "Дата: $(date '+%Y-%m-%d %H:%M:%S %Z')   Host: $(hostname 2>/dev/null)"
[ "$IS_ROOT" = "1" ] || warn "Запущен НЕ от root — часть проверок недоступна (journal, nft, ss)"

# ═══════════════════════════════════════════════════════════════════════════
sect "1. SYSTEM — ресурсы"
# ═══════════════════════════════════════════════════════════════════════════

# uptime + load
UP=$(uptime -p 2>/dev/null || uptime | sed 's/.*up/up/' | cut -d, -f1)
info "Uptime: $UP"
CORES=$(nproc 2>/dev/null || echo 1)
LOAD1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)
LOAD_INT=${LOAD1%.*}
if [ "$LOAD_INT" -gt $((CORES*4)) ]; then fail "Load1=$LOAD1 при $CORES ядрах — система перегружена"
elif [ "$LOAD_INT" -gt $((CORES*2)) ]; then warn "Load1=$LOAD1 при $CORES ядрах — высокая нагрузка"
else ok "Load1=$LOAD1 / $CORES cores"; fi

# RAM
MEM_TOTAL=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
MEM_AVAIL=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
if [ -n "$MEM_TOTAL" ] && [ -n "$MEM_AVAIL" ] && [ "$MEM_TOTAL" -gt 0 ]; then
    AVAIL_PCT=$((MEM_AVAIL*100/MEM_TOTAL))
    MEM_TOTAL_MB=$((MEM_TOTAL/1024)); MEM_AVAIL_MB=$((MEM_AVAIL/1024))
    if [ "$AVAIL_PCT" -lt 5 ]; then fail "RAM: доступно ${MEM_AVAIL_MB}M/${MEM_TOTAL_MB}M (${AVAIL_PCT}%) — почти нет памяти"
    elif [ "$AVAIL_PCT" -lt 10 ]; then warn "RAM: доступно ${MEM_AVAIL_MB}M/${MEM_TOTAL_MB}M (${AVAIL_PCT}%)"
    else ok "RAM: доступно ${MEM_AVAIL_MB}M/${MEM_TOTAL_MB}M (${AVAIL_PCT}%)"; fi
fi

# zram
if [ -e /dev/zram0 ]; then
    Z_ALG=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | grep -oE '\[[a-z0-9-]+\]' | tr -d '[]')
    Z_DATA=$(awk '{print $2}' /sys/block/zram0/mm_stat 2>/dev/null)
    Z_COMPR=$(awk '{print $3}' /sys/block/zram0/mm_stat 2>/dev/null)
    if [ -n "$Z_DATA" ] && [ -n "$Z_COMPR" ] && [ "$Z_COMPR" -gt 0 ] 2>/dev/null; then
        Z_RATIO=$((Z_DATA*100/Z_COMPR))
        ok "zram: algo=${Z_ALG:-?} ratio≈$((Z_RATIO/100)).$((Z_RATIO%100))x"
    else ok "zram: активен (algo=${Z_ALG:-?})"; fi
else
    SWAP_TOTAL=$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null)
    if [ "${SWAP_TOTAL:-0}" -gt 0 ]; then info "zram нет, disk swap: $((SWAP_TOTAL/1024))M"
    else info "zram нет, swap отсутствует"; fi
fi

# disk
for mp in / /var/log; do
    [ -d "$mp" ] || continue
    DP=$(df --output=pcent "$mp" 2>/dev/null | tail -1 | tr -d ' %')
    [ -n "$DP" ] || continue
    if [ "$DP" -ge 95 ]; then fail "Диск $mp занят на ${DP}%"
    elif [ "$DP" -ge 90 ]; then warn "Диск $mp занят на ${DP}%"
    else ok "Диск $mp: ${DP}% занято"; fi
done
# inodes корня
IPCT=$(df --output=ipcent / 2>/dev/null | tail -1 | tr -d ' %')
if [ -n "$IPCT" ] && [ "$IPCT" -ge 90 ] 2>/dev/null; then warn "Inodes / заняты на ${IPCT}%"; fi

# zombies
ZOMB=$(ps aux 2>/dev/null | awk '$8 ~ /^Z/ {n++} END{print n+0}')
if [ "$ZOMB" -gt 0 ]; then warn "Zombie-процессов: $ZOMB"
else ok "Zombie-процессов нет"; fi

# ═══════════════════════════════════════════════════════════════════════════
sect "2. KERNEL / BBR"
# ═══════════════════════════════════════════════════════════════════════════

KREL=$(uname -r 2>/dev/null)
info "Kernel: $KREL"
if echo "$KREL" | grep -qi xanmod; then ok "XanMod kernel"
else info "Не XanMod (возможно доустановка не завершена / требуется reboot)"; fi

if [ -e /var/run/reboot-required ]; then
    warn "Требуется REBOOT (pending kernel update): $(cat /var/run/reboot-required.pkgs 2>/dev/null | head -3 | tr '\n' ' ')"
fi

# live BBR detect (та же эвристика что в shieldnode v3.37.2)
KVER_MAJOR=$(echo "$KREL" | cut -d. -f1); KVER_MINOR=$(echo "$KREL" | cut -d. -f2)
if echo "$KREL" | grep -qi xanmod; then BBR_LIVE="v3 (XanMod backport)"
elif [ "${KVER_MAJOR:-0}" -gt 6 ] 2>/dev/null || { [ "${KVER_MAJOR:-0}" = "6" ] && [ "${KVER_MINOR:-0}" -ge 13 ] 2>/dev/null; }; then BBR_LIVE="v3"
else BBR_LIVE="v1"; fi

CC_NOW=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
if [ "$CC_NOW" = "bbr" ]; then ok "Congestion control: bbr (BBR $BBR_LIVE)"
else fail "Congestion control: ${CC_NOW:-?} — ожидался bbr!"; fi

QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)
if [ "$QDISC" = "fq" ]; then ok "qdisc: fq"
elif [ "$QDISC" = "fq_codel" ]; then info "qdisc: fq_codel (BBR работает, но fq лучше)"
else warn "qdisc: ${QDISC:-?} — ожидался fq"; fi

# ═══════════════════════════════════════════════════════════════════════════
sect "3. SYSCTL — drift ключевых значений"
# ═══════════════════════════════════════════════════════════════════════════

check_sysctl() { # name expected_min expected_str desc
    local name="$1" vmin="$2" vexact="$3" desc="$4"
    local val; val=$(sysctl -n "$name" 2>/dev/null)
    if [ -z "$val" ]; then info "$desc ($name): параметр отсутствует"; return; fi
    if [ -n "$vexact" ]; then
        if [ "$val" = "$vexact" ]; then ok "$desc = $val"
        else warn "$desc: $val (ожидалось $vexact) — drift от node-setup?"; fi
    else
        if [ "$val" -ge "$vmin" ] 2>/dev/null; then ok "$desc = $val"
        else warn "$desc: $val (ожидалось >= $vmin) — drift от node-setup?"; fi
    fi
}

check_sysctl net.core.rmem_max 16777216 "" "rmem_max"
check_sysctl net.core.wmem_max 16777216 "" "wmem_max"
check_sysctl net.core.somaxconn 4096 "" "somaxconn"
check_sysctl net.ipv4.tcp_max_syn_backlog 8192 "" "tcp_max_syn_backlog"
check_sysctl net.netfilter.nf_conntrack_max 262144 "" "conntrack_max"
KM6=$((KVER_MAJOR*100 + KVER_MINOR))
if [ "$KM6" -ge 603 ]; then
    PLB=$(sysctl -n net.ipv4.tcp_plb_enabled 2>/dev/null)
    if [ "${PLB:-0}" = "1" ]; then ok "tcp_plb_enabled = 1"
    else info "tcp_plb_enabled = ${PLB:-n/a} (kernel >= 6.3, node-setup включает)"; fi
fi
if [ -e /dev/zram0 ]; then
    SW=$(sysctl -n vm.swappiness 2>/dev/null)
    if [ "${SW:-0}" -ge 100 ] 2>/dev/null; then ok "vm.swappiness = $SW (zram-оптимум 180)"
    else warn "vm.swappiness = ${SW:-?} — с zram рекомендуется 180"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
sect "3.5. MEMORY / IO / DOCKER / SSD (тюнинг v5.11.0-v5.12.0)"
# ═══════════════════════════════════════════════════════════════════════════

# --- THP: madvise/never — OK; always — latency-спайки сетевых демонов ---
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    THP_CUR=$(sed -n 's/.*\[\([a-z]*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
    case "$THP_CUR" in
        madvise|never)
            ok "THP = $THP_CUR (v5.11.0: madvise — anti-latency-спайки)"
            [ -f /etc/tmpfiles.d/thp-madvise.conf ] || \
                info "THP persistence: /etc/tmpfiles.d/thp-madvise.conf отсутствует (live-only?)"
            ;;
        always)
            warn "THP = always — latency-спайки xray под нагрузкой; v5.11.0 переводит в madvise" ;;
        *)  info "THP = ${THP_CUR:-?} (нестандартное значение)" ;;
    esac
else
    info "THP: kernel без transparent_hugepage — пропуск"
fi

# --- I/O scheduler: none на SSD/virtio (VPS: scheduling делает гипервизор) ---
_IO_BAD=""
_IO_OKN=0
for _bd in /sys/block/vd[a-z] /sys/block/sd[a-z] /sys/block/xvd[a-z] /sys/block/nvme[0-9]n[0-9] /sys/block/mmcblk[0-9]; do
    [ -e "$_bd/queue/scheduler" ] || continue
    # v1.0.3: vd/xvd без rotational-guard (virtio бывает misreport=1,
    # scheduling всё равно делает гипервизор). Реальные HDD (sd) пропускаем.
    case "${_bd##*/}" in
        vd*|xvd*) : ;;
        *) [ "$(cat "$_bd/queue/rotational" 2>/dev/null)" = "1" ] && continue ;;
    esac
    grep -qw none "$_bd/queue/scheduler" 2>/dev/null || continue
    _sc=$(sed -n 's/.*\[\([a-z0-9-]*\)\].*/\1/p' "$_bd/queue/scheduler" 2>/dev/null)
    if [ "$_sc" = "none" ]; then _IO_OKN=$((_IO_OKN+1));
    else _IO_BAD="$_IO_BAD ${_bd##*/}($_sc)"; fi
done
if [ -n "$_IO_BAD" ]; then
    warn "I/O scheduler != none на:$_IO_BAD — v5.11.0 ставит none (VPS)"
elif [ "$_IO_OKN" -gt 0 ]; then
    ok "I/O scheduler = none на $_IO_OKN SSD/virtio дисках"
else
    info "I/O scheduler: подходящих vd/sd/xvd/nvme не найдено"
fi

# --- Docker daemon.json: live-restore + log rotation ---
if have docker || [ -f /etc/docker/daemon.json ]; then
    if [ ! -f /etc/docker/daemon.json ]; then
        warn "docker daemon.json отсутствует — нет log rotation и live-restore (v5.11.0 создаст)"
    else
        _DJ_MISS=""
        grep -q '"live-restore"[[:space:]]*:[[:space:]]*true' /etc/docker/daemon.json 2>/dev/null || _DJ_MISS="live-restore"
        grep -q '"max-size"' /etc/docker/daemon.json 2>/dev/null || _DJ_MISS="$_DJ_MISS log-opts.max-size"
        if [ -z "$_DJ_MISS" ]; then
            ok "docker daemon.json: live-restore + log rotation настроены"
        else
            warn "docker daemon.json: нет${_DJ_MISS} — логи контейнеров могут забить диск (v5.11.0 чинит)"
        fi
    fi
fi

# --- noatime: запись atime при каждом чтении — HDD-эпохи наследие ---
if have findmnt; then
    _ROOT_OPTS=$(findmnt -n -o OPTIONS / 2>/dev/null)
    case ",$_ROOT_OPTS," in
        *,noatime,*) ok "noatime на / (v5.12.0)" ;;
        *) warn "noatime НЕ установлен на / — лишние atime-записи на SSD (v5.12.0 ставит)" ;;
    esac
    # discard в fstab = sync TRIM на каждый delete (latency-спайки)
    if grep -qE '^[[:space:]]*[^#][^ ]*[[:space:]]+[^ ]*[[:space:]]+(ext4|xfs|btrfs|f2fs)[[:space:]]+[^ ]*\bdiscard\b' /etc/fstab 2>/dev/null; then
        warn "fstab содержит discard — sync TRIM на каждый delete; v5.12.0 заменяет на weekly fstrim"
    else
        ok "discard в fstab отсутствует (weekly fstrim — правильный режим)"
    fi
fi

# --- add_random=0 на SSD/NVMe ---
_AR_BAD=""; _AR_OKN=0
for _bd in /sys/block/vd[a-z] /sys/block/sd[a-z] /sys/block/xvd[a-z] /sys/block/nvme[0-9]n[0-9] /sys/block/mmcblk[0-9]; do
    [ -e "$_bd/queue/add_random" ] || continue
    case "${_bd##*/}" in
        vd*|xvd*) : ;;
        *) [ "$(cat "$_bd/queue/rotational" 2>/dev/null)" = "1" ] && continue ;;
    esac
    if [ "$(cat "$_bd/queue/add_random" 2>/dev/null)" = "0" ]; then _AR_OKN=$((_AR_OKN+1));
    else _AR_BAD="$_AR_BAD ${_bd##*/}"; fi
done
if [ -n "$_AR_BAD" ]; then
    info "add_random=1 на:$_AR_BAD — v5.12.0 отключает (per-I/O entropy overhead)"
elif [ "$_AR_OKN" -gt 0 ]; then
    ok "add_random=0 на $_AR_OKN дисках"
fi

# --- dirty writeback лимиты ---
_DB=$(sysctl -n vm.dirty_background_ratio 2>/dev/null)
_DR=$(sysctl -n vm.dirty_ratio 2>/dev/null)
_DBB=$(sysctl -n vm.dirty_background_bytes 2>/dev/null)
_DB2=$(sysctl -n vm.dirty_bytes 2>/dev/null)
if [ "${_DBB:-0}" -gt 0 ] 2>/dev/null || [ "${_DB2:-0}" -gt 0 ] 2>/dev/null; then
    ok "dirty writeback: bytes-лимиты bg=$(( ${_DBB:-0} / 1048576 ))MB / hard=$(( ${_DB2:-0} / 1048576 ))MB (v5.12.0)"
elif [ "${_DR:-20}" -le 15 ] 2>/dev/null; then
    ok "dirty_ratio = $_DR (background ${_DB:-?}) — в норме"
else
    info "dirty_ratio = ${_DR:-?} (background ${_DB:-?}) — дефолт 20/10; v5.12.0 сглаживает writeback-всплески"
fi

# ═══════════════════════════════════════════════════════════════════════════
sect "4. SERVICES — здоровье"
# ═══════════════════════════════════════════════════════════════════════════

if ! have systemctl; then
    info "systemd недоступен — секция пропущена"
else
    # failed units (v1.0.1: --plain убирает glyph '●' из первой колонки,
    # sed — страховка для старых systemd без --plain)
    FAILED_UNITS=$(systemctl list-units --failed --no-legend --no-pager --plain 2>/dev/null | \
        awk '{print $1}' | sed 's/^●//' | grep -v '^$')
    if [ -n "$FAILED_UNITS" ]; then
        while IFS= read -r fu; do fail "Failed unit: $fu"; done <<< "$FAILED_UNITS"
    else ok "Failed units: нет"; fi

    # xray (имя unit может отличаться)
    XRAY_UNIT=$(systemctl list-units --all --no-legend --no-pager 2>/dev/null | grep -iE 'xray|remnawave|marzban|3x-ui|sing-box' | awk '{print $1}' | head -1)
    if [ -n "$XRAY_UNIT" ]; then
        if unit_active "$XRAY_UNIT"; then ok "VPN core: $XRAY_UNIT active"
        else fail "VPN core: $XRAY_UNIT НЕ активен!"; fi
    elif have docker; then
        # v1.0.1: xray часто в docker (remnawave/marzban node)
        CTR=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'xray|remnawave|marzban|sing-box|3x-ui' | head -1)
        if [ -n "$CTR" ]; then ok "VPN core: docker container '$CTR' running"
        else
            CTR_ANY=$(docker ps --format '{{.Names}}' 2>/dev/null | head -3 | tr '\n' ' ')
            if [ -n "$CTR_ANY" ]; then info "VPN core: systemd unit не найден, docker containers: $CTR_ANY"
            else warn "VPN core: ни systemd unit, ни docker container не найден"; fi
        fi
    else info "VPN core unit не найден (xray/remnawave/marzban/sing-box)"; fi

    # crowdsec + bouncer
    if unit_exists crowdsec.service; then
        if unit_active crowdsec.service; then
            ok "crowdsec: active"
            if unit_exists crowdsec-firewall-bouncer.service; then
                if unit_active crowdsec-firewall-bouncer.service; then ok "crowdsec bouncer: active"
                else fail "crowdsec bouncer: НЕ активен — решения crowdsec не применяются в nft!"; fi
            fi
        else fail "crowdsec: НЕ активен"; fi
    else info "crowdsec: не установлен"; fi

    # endlessh
    if unit_exists endlessh.service; then
        if unit_active endlessh.service; then
            if have ss && ss -tln 2>/dev/null | grep -q ':8022 '; then ok "endlessh: active, слушает :8022"
            else warn "endlessh: active но :8022 не слушается"; fi
        else warn "endlessh: НЕ активен (tarpit не работает)"; fi
        if [ "$OPT_LOGS" = "1" ] && [ "$IS_ROOT" = "1" ]; then
            NS_ERR=$(journalctl -u endlessh.service --since "7 days ago" --no-pager 2>/dev/null | grep -c 'status=226/NAMESPACE' || true)
            [ "${NS_ERR:-0}" -gt 0 ] && warn "endlessh: $NS_ERR падений 226/NAMESPACE за 7д (обнови shieldnode >= 3.37.3)"
        fi
    else info "endlessh: не установлен"; fi

    # ключевые timers
    for t in shieldnode-github-sync.timer shieldnode-events-maintenance.timer fstrim.timer logrotate.timer man-db.timer; do
        if unit_exists "$t"; then
            if unit_active "$t"; then ok "timer: $t"
            else warn "timer: $t не активен"; fi
        fi
    done

    # мусорные сервисы (должны быть выключены node-setup v5.10+)
    GARBAGE_ALIVE=""
    for g in packagekit.service cups.service cups-browsed.service bluetooth.service \
             avahi-daemon.service ModemManager.service thermald.service colord.service \
             accounts-daemon.service switcheroo-control.service bolt.service \
             wpa_supplicant.service motd-news.timer unattended-upgrades.service; do
        if unit_active "$g"; then GARBAGE_ALIVE="$GARBAGE_ALIVE $g"; fi
    done
    if [ -n "$GARBAGE_ALIVE" ]; then warn "Фоновый мусор ещё жив:$GARBAGE_ALIVE (node-setup v5.10+ выключает)"
    else ok "Фоновые мусорные сервисы: выключены"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
sect "5. NFTABLES — целостность firewall"
# ═══════════════════════════════════════════════════════════════════════════

if ! have nft || [ "$IS_ROOT" != "1" ]; then
    info "nft недоступен или нет root — секция пропущена"
else
    if nft list table inet ddos_protect >/dev/null 2>&1; then
        ok "table inet ddos_protect: существует"

        # parse-check (v1.0.1): 'nft list ruleset' — add-семантика, повторная
        # загрузка существующих table даёт EEXIST → ложный FAIL. Поэтому
        # prepend 'flush ruleset': транзакция валидируется как полная замена.
        # nft -c (check) только проверяет валидность — изменения НЕ применяются.
        if { echo 'flush ruleset'; nft list ruleset 2>/dev/null; } | nft -c -f - >/dev/null 2>&1; then
            ok "ruleset parse-check: чисто (нет синтаксических ошибок)"
        else
            PC_ERR=$( { echo 'flush ruleset'; nft list ruleset 2>/dev/null; } | nft -c -f - 2>&1 | head -2 | tr '\n' ' ')
            fail "ruleset parse-check ПАДАЕТ: $PC_ERR"
        fi

        # whitelist drift: TRUSTED_IPS из конфига vs manual_whitelist_v4
        if [ -r /etc/shieldnode/shieldnode.conf ]; then
            TI=$(grep -E '^TRUSTED_IPS=' /etc/shieldnode/shieldnode.conf 2>/dev/null | head -1 | sed -E 's/^TRUSTED_IPS="?([^"]*)"?.*/\1/')
            if [ -n "$TI" ]; then
                NFT_WHITE=$(nft list set inet ddos_protect manual_whitelist_v4 2>/dev/null | tr ',' '\n' | grep -oE '^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr -d ' ' | sort -u)
                DRIFT=""
                OLDIFS=$IFS; IFS=', '
                for ip in $TI; do
                    echo "$ip" | grep -qE '^[0-9]+\.' || continue
                    echo "$NFT_WHITE" | grep -qx "$ip" || DRIFT="$DRIFT $ip"
                done
                IFS=$OLDIFS
                if [ -n "$DRIFT" ]; then fail "WHITELIST DRIFT: TRUSTED_IPS отсутствуют в nft:$DRIFT (shieldnode >= 3.37.0 чинит)"
                else ok "Whitelist drift: нет (TRUSTED_IPS ⊂ manual_whitelist_v4)"; fi
            else info "TRUSTED_IPS не задан — drift-проверка пропущена"; fi
        fi

        # размеры blocklist set'ов
        for s in scanner_blocklist_v4 threat_blocklist_v4 custom_blocklist_v4; do
            SZ=$(nft list set inet ddos_protect "$s" 2>/dev/null | tr ',' '\n' | grep -cE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
            if [ "${SZ:-0}" -eq 0 ]; then
                [ "$s" = "custom_blocklist_v4" ] && info "set $s: пуст (нормально если нет custom ban'ов)" \
                    || warn "set $s: ПУСТ — blocklist не загрузился? (systemctl start shieldnode-update@${s%%_blocklist*}.service)"
            else ok "set $s: $SZ элементов"; fi
        done

        # drop counters (инфо): inline счётчики в chain + named counters (v1.0.1)
        DROPS_INLINE=$(nft list chain inet ddos_protect input 2>/dev/null | grep -oE 'counter packets [0-9]+' | awk '{s+=$3} END{print s+0}')
        DROPS_NAMED=$(nft list counters inet ddos_protect 2>/dev/null | grep -oE 'packets [0-9]+' | awk '{s+=$2} END{print s+0}')
        info "ddos_protect counters: ${DROPS_NAMED} pkts (named) + ${DROPS_INLINE} pkts (inline)"
    else
        info "table inet ddos_protect отсутствует — shieldnode не установлен?"
    fi

    # flowtable + hw offload
    if nft list ruleset 2>/dev/null | grep -q 'flowtable'; then
        if nft list ruleset 2>/dev/null | grep -A3 'flowtable' | grep -q 'flags offload'; then
            ok "flowtable: есть, HW offload ВКЛ"
        else ok "flowtable: есть (SW offload)"; fi
    else info "flowtable: не найден (node-setup без flowtable?)"; fi

    # MSS clamp
    if nft list ruleset 2>/dev/null | grep -q 'tcp flags syn.*tcp option maxseg size\|maxseg size set'; then
        ok "MSS clamp: правило присутствует"
    else info "MSS clamp: правило не найдено"; fi
fi

# ═══════════════════════════════════════════════════════════════════════════
sect "6. UFW"
# ═══════════════════════════════════════════════════════════════════════════

if ! have ufw; then
    info "ufw не установлен"
else
    UFW_ST=$(ufw status 2>/dev/null | head -1)
    if echo "$UFW_ST" | grep -qi 'active'; then
        ok "ufw: active"
        if grep -qE '^IPV6=no' /etc/default/ufw 2>/dev/null; then ok "ufw IPV6=no (консистентно с выключенным IPv6)"
        else warn "ufw IPV6 не 'no' — при выключенном IPv6 в системе будут ошибки ip6tables"; fi
        # docker bypass
        if have docker || [ -d /var/lib/docker ]; then
            if grep -qs '"iptables"[[:space:]]*:[[:space:]]*false' /etc/docker/daemon.json 2>/dev/null; then
                ok "docker: iptables=false (не обходит ufw)"
            else warn "docker установлен без iptables=false — контейнеры могут обходить ufw/nft"; fi
        fi
    else
        info "ufw: inactive ($UFW_ST)"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
sect "7. CONNTRACK"
# ═══════════════════════════════════════════════════════════════════════════

CT_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
CT_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
if [ -n "$CT_COUNT" ] && [ -n "$CT_MAX" ] && [ "$CT_MAX" -gt 0 ]; then
    CT_PCT=$((CT_COUNT*100/CT_MAX))
    if [ "$CT_PCT" -ge 90 ]; then fail "conntrack: $CT_COUNT/$CT_MAX (${CT_PCT}%) — таблица почти полна, дропы новых соединений!"
    elif [ "$CT_PCT" -ge 80 ]; then warn "conntrack: $CT_COUNT/$CT_MAX (${CT_PCT}%)"
    else ok "conntrack: $CT_COUNT/$CT_MAX (${CT_PCT}%)"; fi
else info "conntrack: модуль не загружен или счётчики недоступны"; fi

# ═══════════════════════════════════════════════════════════════════════════
sect "8. LOGS — ошибки и OOM"
# ═══════════════════════════════════════════════════════════════════════════

if [ "$OPT_LOGS" = "0" ] || [ "$IS_ROOT" != "1" ] || ! have journalctl; then
    info "Скан journal пропущен (--no-logs / нет root)"
else
    ERR24=$(journalctl -p err --since "24 hours ago" --no-pager -q 2>/dev/null | grep -vc '^--' || true)
    if [ "${ERR24:-0}" -gt 500 ]; then fail "journal: $ERR24 error-строк за 24ч — смотри journalctl -p err"
    elif [ "${ERR24:-0}" -gt 100 ]; then warn "journal: $ERR24 error-строк за 24ч"
    else ok "journal: ${ERR24:-0} error-строк за 24ч"; fi

    OOM7=$(journalctl --since "7 days ago" --no-pager -q 2>/dev/null | grep -ciE 'out of memory|oom-kill|oom_reaper' || true)
    if [ "${OOM7:-0}" -gt 0 ]; then fail "OOM kills за 7д: $OOM7 — памяти не хватает (zram writeback? лимиты xray?)"
    else ok "OOM kills за 7д: нет"; fi

    SEGV7=$(journalctl --since "7 days ago" --no-pager -q 2>/dev/null | grep -ciE 'segfault' || true)
    [ "${SEGV7:-0}" -gt 0 ] && warn "segfault за 7д: $SEGV7"

    STORM=$(journalctl --since "24 hours ago" --no-pager -q 2>/dev/null | grep -c 'Start request repeated too quickly' || true)
    if [ "${STORM:-0}" -gt 0 ]; then warn "Restart-storm за 24ч: $STORM (unit в цикле падений — systemctl --failed)"
    else ok "Restart-storm за 24ч: нет"; fi

    # наши ddos-дропы в логах (инфо об активности атак)
    DDOS24=$(journalctl -k --since "24 hours ago" --no-pager -q 2>/dev/null | grep -c '\[shield:' || true)
    info "nft log [shield:*] за 24ч: ${DDOS24:-0} строк (активность атак/сканеров)"
fi

# ═══════════════════════════════════════════════════════════════════════════
sect "9. TIME SYNC"
# ═══════════════════════════════════════════════════════════════════════════

if have timedatectl; then
    NTP_SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    if [ "$NTP_SYNC" = "yes" ]; then ok "NTP: синхронизировано"
    else
        if unit_active chronyd.service 2>/dev/null || unit_active systemd-timesyncd.service 2>/dev/null; then
            warn "NTP: сервис активен, но синхронизации нет"
        else warn "NTP: не синхронизировано (логи crowdsec/nft будут врать по времени)"; fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
sect "10. CONTRACT — stack.conf"
# ═══════════════════════════════════════════════════════════════════════════

STACK_CONF="/etc/node-profile.d/stack.conf"
if [ -r "$STACK_CONF" ]; then
    ok "stack.conf: найден"
    SC_BBR=$(grep -E '^bbr=' "$STACK_CONF" | cut -d= -f2)
    SC_V6=$(grep -E '^ipv6=' "$STACK_CONF" | cut -d= -f2)
    SC_FT=$(grep -E '^flowtable=' "$STACK_CONF" | cut -d= -f2)
    SC_VER=$(grep -E '^version=' "$STACK_CONF" | head -1 | cut -d= -f2)
    info "  snapshot: version=${SC_VER:-?} bbr=${SC_BBR:-?} ipv6=${SC_V6:-?} flowtable=${SC_FT:-?}"
    # live vs snapshot
    if [ "$CC_NOW" = "bbr" ] && ! echo "${SC_BBR:-}" | grep -q "$BBR_LIVE"; then
        info "  stack.conf bbr='${SC_BBR:-?}' vs live '$BBR_LIVE' — snapshot писался до reboot (норма, shieldnode >= 3.37.2 показывает live)"
    fi
    if [ "$SC_V6" = "disabled" ]; then
        V6_LIVE=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        if [ "$V6_LIVE" = "1" ]; then ok "IPv6: disabled (live = contract)"
        else fail "IPv6: contract=disabled, но live disable_ipv6=${V6_LIVE:-?} — drift!"; fi
    fi
else
    info "stack.conf отсутствует — нода не настроена через vpn-node-setup.sh?"
fi

# ═══════════════════════════════════════════════════════════════════════════
sect "ИТОГ"
# ═══════════════════════════════════════════════════════════════════════════

printf '\n%s────────────────────────────────────────────────────────%s\n' "$C_BLD" "$C_RST"
printf '  %sOK: %d%s   %sWARN: %d%s   %sFAIL: %d%s\n' \
    "$C_GRN" "$N_OK" "$C_RST" "$C_YEL" "$N_WARN" "$C_RST" "$C_RED" "$N_FAIL" "$C_RST"

if [ "$N_FAIL" -gt 0 ]; then
    printf '\n%sFAIL-секции (чинить в первую очередь):%s' "$C_RED" "$C_RST"
    printf '%b\n' "$FAIL_LIST"
    EXIT_CODE=2
elif [ "$N_WARN" -gt 0 ]; then
    printf '\n%sWARN-секции (желательно разобрать):%s' "$C_YEL" "$C_RST"
    printf '%b\n' "$WARN_LIST"
    EXIT_CODE=1
else
    printf '\n%s✔ Недочётов не найдено — нода в порядке.%s\n' "$C_GRN" "$C_RST"
    EXIT_CODE=0
fi
printf '\n'
exit $EXIT_CODE
