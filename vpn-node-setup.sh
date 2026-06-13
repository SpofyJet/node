#!/bin/bash

# ==============================================================================
#  ██╗  ██╗ █████╗ ███╗   ██╗███╗   ███╗ ██████╗ ██████╗ 
#  ╚██╗██╔╝██╔══██╗████╗  ██║████╗ ████║██╔═══██╗██╔══██╗
#   ╚███╔╝ ███████║██╔██╗ ██║██╔████╔██║██║   ██║██║  ██║
#   ██╔██╗ ██╔══██║██║╚██╗██║██║╚██╔╝██║██║   ██║██║  ██║
#  ██╔╝ ██╗██║  ██║██║ ╚████║██║ ╚═╝ ██║╚██████╔╝██████╔╝
#  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝     ╚═╝ ╚═════╝ ╚═════╝ 
#                                                         
#  XRAY/REMNAWAVE NODE BUILDER v5.3.4 (audit fixes: RPS-mask >32CPU, conntrack est-timeout coord)
#  Ядро XanMod LTS + BBRv3 + Полная оптимизация системы + MSS clamp + Diagnostics
#  Поддерживает: Debian 12/13 (bookworm/trixie), Ubuntu 24.04+ (noble/plucky/…)
#  ВНИМАНИЕ: Ubuntu 22.04 (jammy) и 20.04 (focal) НЕ поддерживаются — XanMod не
#  публикует для них ядра (404 на deb.xanmod.org). Скрипт это проверяет и выходит
#  рано с понятным сообщением (см. guard в ШАГ 4).
#
#  ============================================================================
#  v5.3.4 (audit fixes 2026-06-13):
#  ============================================================================
#  FIX V2  rps_cpus-маска строится запятыми по 32-бит словам (старший первым). Старый
#          одно-токеновый hex ядро отвергало на >32 CPU, а (1<<CPUS) переполнялся при
#          CPUS>=64 → маска "0" = RPS off. Фикс inline + в генерируемом rps-tuning.sh.
#  FIX X1  nf_conntrack_tcp_timeout_established 86400 → 7200, скоординировано с
#          shieldnode (90-shieldnode.conf). Раньше 86400 в 80- молча проигрывал
#          shieldnode-значению по лексикографике (90>80) → итог непредсказуем при
#          совместной установке. Теперь оба пишут 7200 — детерминированно.
#  FIX URL Канонический репо self-update выставлен на SpofyJet/node (был
#          abcproxy70-ops/node) — совпадает с публикацией deploy-node.sh и raw-URL.
#  ============================================================================
#  v5.3.3 (audit fixes по отчёту аудита 2026-06-11):
#  ============================================================================
#  FIX A1  unattended-upgrades теперь отключается РЕАЛЬНО: APT::Periodic=0 +
#          disable apt-daily{,-upgrade}.timer. Disable одного юнита периодику не
#          останавливал — её гонит apt.systemd.daily по таймеру (enablement юнита
#          там не проверяется). При SETUP_DISABLE_UNATTENDED=0 остановленные в
#          pre-flight таймеры стартуются обратно в конце прогона.
#  FIX A2  GRUB_DEFAULT: title-pin на точную версию ставится ТОЛЬКО пока в /boot
#          есть не-LTS xanmod; иначе GRUB_DEFAULT=0 → point-release'ы LTS
#          подхватываются автоматически (раньше пин стейлился навсегда: apt
#          ставил 6.18.36, GRUB продолжал грузить запиннутый 6.18.35).
#  FIX A3  offload-детект: ethtool -k печатает длинные имена — gro/gso/tso
#          никогда не матчились и не включались в runtime. Маппинг short→long.
#  FIX A4  QDISC_MODE при custom qdisc (htb/cake) больше не затирается на
#          "mq + fq" в отчёте; убран ложный "mq уже инициализирован".
#  FIX A5  ШАГ 5 не рубит IPv6 live при активной SSH-сессии по IPv6 (раньше
#          SIGHUP убивал скрипт между установкой ядра и GRUB-пином). Детект:
#          SSH_CONNECTION / ss -6 :22. Конфиг применяется после ребута.
#  FIX A6  pgrep-паттерн ловит /usr/bin/dpkg ('^dpkg' пропускал argv[0] с путём).
#
#  ============================================================================
#  v5.3.2 (XanMod codename guard + tuning corrections по первоисточникам):
#  ============================================================================
#  FIX   guard на неподдерживаемый XanMod codename. Проверено: jammy (Ubuntu 22.04)
#        и focal (20.04) отдают 404 на deb.xanmod.org → раньше FATAL "нет ядра" с
#        мутной причиной. Теперь — ранний выход с понятным сообщением. Header-claim
#        про 22.04 убран (XanMod его не поддерживает).
#  REVERT убрал tcp_no_metrics_save=1 (ядро: default=0 обычно ЛУЧШЕ; не переусердств.)
#  DOC   MSS clamp: уточнено где реально полезен (urезанный egress MTU — WARP/wgcf/
#        PPPoE/5G), на прямом 1500 инертен. default_qdisc=fq перебивает XanMod fq_pie
#        (осознанно, Google рекомендует fq). Подтверждено: `bbr` на XanMod = BBRv3.
#

#  ============================================================================
#  TUNE  TIER1 rmem_max/wmem_max 4MB/2MB → 8MB/8MB — закрывает quic-go (хочет
#        7.5MB) и согласует с udp floor 8MB. Раньше QUIC-send на 1GB резался в 2MB.
#  TUNE  TIER2 wmem_max 8MB → 16MB (симметрия rmem_max; Hysteria2 send).
#  FEAT  +logrotate для /var/log/remnanode (требование доков Remnawave; copytruncate).
#  Примечание: TCP-буферы (Reality) не трогали — TCP-автотюн не лимитится rmem_max.
#  UDP-тюнинг полезен только если в стэке есть UDP-транспорты (Caddy HTTP/3,
#  Hysteria2, TUIC, Xray-QUIC); на чистой Reality (TCP) UDP-блок простаивает.
#
#  ============================================================================
#  v5.3.0 (robustness + reliability hardening) — детали в комментах у каждого фикса:
#  ============================================================================
#  CRIT  RAM-детект тиров из /proc/meminfo, не из локале-зависимого `free` (#1)
#  CRIT  CPU без SSE4.2 → x86-64-v1, не v2 (v2 требует SSE4.2 → иначе не грузится) (#2)
#  FIX   подменю диагностики: 'q' = выход (раньше перехватывалось 'quick') (#3)
#  FIX   самолечение битого xanmod-репо: первый apt-get update не падает фатально (#4)
#  FIX   --upgrade не теряет версию при ребуте внутри новой версии (#6)
#  FIX   IRQ affinity через smp_affinity_list — корректно на 32+ CPU (#12)
#  FIX   multipathd не отключается при root/storage на multipath (#9)
#  FIX   unattended-upgrades — отключение opt-out (SETUP_DISABLE_UNATTENDED=0) (#10)
#  FEAT  zram-swap на TIER1/2 (анти-OOM на 1-2GB) (#13)
#  FEAT  ring buffers на физ-NIC персистятся через udev (без per-boot флапа) (#8)
#  FEAT  опц. проверка подписи апдейта (SETUP_REQUIRE_SIG=1, по умолч. выкл) (#5)
#  MISC  GPG key ID → константа; node-diag детект по содержимому; SC2086 закрыты (#17,#14)
#
#  Полный CHANGELOG: https://github.com/abcproxy70-ops/node/blob/main/CHANGELOG.md
#  Документация:    https://github.com/abcproxy70-ops/node
#
#  ============================================================================
#  Кратко о текущей версии (v5.1.0 — UDP buffer fix):
#  ============================================================================
#  CRIT-3: UDP socket buffer floor fix (главная победа версии).
#    * Добавлены net.ipv4.udp_rmem_min=8MB / udp_wmem_min=8MB на ВСЕХ tier.
#    * Default 4KB per-socket убивал любой высоконагруженный UDP трафик:
#      - QUIC outbound (Xray к Cloudflare/Google/Meta — HTTP/3 на современном вебе)
#      - Caddy HTTP/3 listener (входящие клиенты с Chrome/Safari HTTP/3)
#      - Hysteria2 (если используется в стэке)
#      - WireGuard / Tuic / другие UDP протоколы
#      → kernel RcvbufErrors growth до сотен/час → user-visible медленный
#        QUIC handshake → загруз страниц "тормозит".
#    * Verified в production (causal-violet-pike, 5895 active TCP + 528 UDP):
#      после fix RcvbufErrors growth = 0/30s устойчиво. Источник UDP на
#      тестовой ноде: Caddy HTTP/3 (UDP/443) + 528 Xray outbound QUIC
#      сокетов к CDN-фронтендам (rw-core fd 9XXX).
#
#  CRIT-3: rmem_default / wmem_default подняты (tier-aware).
#    * TIER 1 (1GB): без изменений 262144 — RAM constraint
#    * TIER 2 (2GB): 262144 → 2097152 (2MB) — safe для 2GB ноды
#    * TIER 3 (4-8G): 524288 → 8388608 (8MB) — verified в проде, RAM OK
#    * TIER 4 (8GB+): 1048576 → 8388608 (8MB)
#    * rmem_default — high watermark для autotuning UDP сокетов. Xray не
#      вызывает setsockopt(SO_RCVBUF) → использует default. Старые ~500KB
#      defaults были bottleneck'ом для QUIC bursts несмотря на rmem_max=16MB.
#    * Для TCP не критично — там tcp_rmem[1] управляет (87380 default).
#
#  CRIT-3: udp_mem tier-aware (раньше — kernel autotune; на больших нодах OK,
#    на TIER 1/2 мог быть мал в peak).
#  IMPR: tcp_adv_win_scale=-2 теперь во всех tier (раньше только 3/4).
#  IMPR: ethtool offloads — LRO off (defensive), rx-udp-gro-forwarding on.
#  IMPR: попытка multi-queue NIC (combined N), silent fail на virtio max=1.
#  REFACTOR: sysctl файл 99-vpn-node-tuning.conf → 80-vpn-node-tuning.conf.
#    * Старое имя перебивало shieldnode (90-). Новое ставит базу первой,
#      shieldnode + ad-hoc fixes (99-z-*) override чисто. Cleanup удаляет old.
#
#  Из v5.0.7 (сохранены):
#  - правильное определение LTS XanMod kernel'а по major.minor branches
#  - LTS активен через MAIN-метапакет — корректно обрабатывается
#
#  Из v5.0.6 (сохранены):
#  - installed.sh при `bash <(curl ...)`
#  - conntrack_tcp_timeout=86400 (long-lived TCP)
#  - tier-aware conntrack_max (786k для TIER 2, 2M для TIER 4)
#  - vm.overcommit_memory=1 на TIER 1/2 (anti-OOM)
#  - XanMod LTS + BBRv3 + tier-aware sysctl + MSS clamp
#  - Совместимость с shieldnode v3.23.0+ (security sysctl ownership)
#  - Self-upgrade (--upgrade), rollback (--rollback), diagnose (--diagnose)
#
#  Для применения: sudo bash <(curl -fsSL <URL>) --optimize
#  Для апгрейда:   sudo bash /var/lib/vpn-node-builder/installed.sh --upgrade
# ==============================================================================

set -o pipefail

# ==============================================================================
# v4.12: --dry-run / -n флаг
# Если задан, скрипт НЕ вызывает apt-get install/remove для kernel-пакетов
# (sysctl, лимиты, конфиги создаются как обычно — их можно сразу откатить).
# Это нужно для production-ноды чтобы посмотреть что будет ДО реальной установки.
# ==============================================================================

# v5.0: версия + repo URL для self-upgrade
SCRIPT_VERSION="5.3.4"
SCRIPT_REPO_URL="${SCRIPT_REPO_URL:-https://raw.githubusercontent.com/SpofyJet/node/main/vpn-node-setup.sh}"

# v5.3.0 (fix #17): XanMod signing key ID вынесен в именованную константу.
# Используется как fallback для keyserver когда dl.xanmod.org недоступен.
# Если XanMod сменит ключ — обновить здесь (и сверить отпечаток на dl.xanmod.org).
XANMOD_GPG_KEY_ID="${XANMOD_GPG_KEY_ID:-86F7D09EE734E623}"

# v5.3.0 (fix #5): опциональная проверка подписи скачанного скрипта/диагностики.
# По умолчанию ВЫКЛ — поведение/апгрейды не меняются. Включение и инструкция по
# подписи релизов — в блоке "SIGNING RELEASES" в конце файла.
SETUP_REQUIRE_SIG="${SETUP_REQUIRE_SIG:-0}"
SETUP_SIG_FINGERPRINT="${SETUP_SIG_FINGERPRINT:-}"
SETUP_MINISIGN_PUBKEY="${SETUP_MINISIGN_PUBKEY:-}"
SCRIPT_STATE_DIR="/var/lib/vpn-node-builder"
SCRIPT_INSTALLED_PATH="$SCRIPT_STATE_DIR/installed.sh"
SCRIPT_PREVIOUS_PATH="$SCRIPT_STATE_DIR/previous.sh"
SCRIPT_VERSION_FILE="$SCRIPT_STATE_DIR/.version"

# v5.0 BUGFIX: при запуске через `bash <(curl ...)` или `curl ... | bash`
# переменная $0 равна /dev/fd/63 (или /proc/self/fd/N) — это не путь к
# скрипту, а файловый дескриптор от process substitution. Если показать
# юзеру "sudo bash $0 --optimize" — увидит "sudo bash /dev/fd/63 --optimize"
# который не сработает. Helper возвращает корректную команду для повторного
# запуска: либо installed.sh (если уже установлен), либо canonical curl-one-liner.
v5_self_invocation() {
    # Если скрипт уже установлен через --upgrade или после первого optimize'а —
    # есть стабильный путь /var/lib/vpn-node-builder/installed.sh
    if [ -f "$SCRIPT_INSTALLED_PATH" ]; then
        echo "$SCRIPT_INSTALLED_PATH"
        return 0
    fi
    # Если $0 — реальный файл (не fd, не bash, не process substitution) — используем его
    local self="$0"
    if [ -f "$self" ] && [[ "$self" != /dev/fd/* ]] && [[ "$self" != /proc/self/fd/* ]] && [[ "$self" != "bash" ]] && [[ "$self" != "/bin/bash" ]]; then
        echo "$self"
        return 0
    fi
    # Fallback: canonical curl invocation (для bash <(curl ...) случая)
    echo "<(curl -fsSL ${SCRIPT_REPO_URL})"
}

# v5.3.0 (fix #5): проверка detached-подписи скачанного файла.
#   $1 — путь к файлу, $2 — базовый URL (к нему добавляем .asc / .minisig)
# Возвращает 0 если проверка выключена ИЛИ подпись валидна; 1 если включена,
# но подпись отсутствует/невалидна/не от пиннутого ключа. Дизайн и включение —
# см. блок "SIGNING RELEASES" в конце файла.
v5_verify_signature() {
    local file="$1" base_url="$2"

    # Проверка не запрошена — пропускаем (старое поведение).
    if [ "$SETUP_REQUIRE_SIG" != "1" ]; then
        return 0
    fi

    local tmp_sig
    tmp_sig=$(mktemp -t vpn-node-sig.XXXXXX) || { echo "FATAL: mktemp (sig) failed"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_sig'" RETURN

    # minisign-путь (если задан публичный ключ).
    if [ -n "$SETUP_MINISIGN_PUBKEY" ]; then
        if ! command -v minisign >/dev/null 2>&1; then
            echo "FATAL: SETUP_REQUIRE_SIG=1 + minisign-pubkey задан, но minisign не установлен (apt install minisign)."
            return 1
        fi
        if ! curl -fsSL --max-time 30 --retry 2 "${base_url}.minisig" -o "$tmp_sig" 2>/dev/null || [ ! -s "$tmp_sig" ]; then
            echo "FATAL: detached minisign-подпись (${base_url}.minisig) не скачалась — отказываюсь запускать."
            return 1
        fi
        if minisign -V -p "$SETUP_MINISIGN_PUBKEY" -m "$file" -x "$tmp_sig" >/dev/null 2>&1; then
            echo "✓ minisign-подпись валидна"
            return 0
        fi
        echo "FATAL: minisign-подпись НЕ прошла проверку — файл мог быть подменён."
        return 1
    fi

    # GPG-путь (по пиннингу fingerprint).
    if [ -z "$SETUP_SIG_FINGERPRINT" ]; then
        echo "FATAL: SETUP_REQUIRE_SIG=1, но не задан ни SETUP_SIG_FINGERPRINT (gpg), ни SETUP_MINISIGN_PUBKEY."
        echo "       Заполни одно из них или выключи проверку (SETUP_REQUIRE_SIG=0)."
        return 1
    fi
    if ! command -v gpg >/dev/null 2>&1; then
        echo "FATAL: SETUP_REQUIRE_SIG=1, но gpg не установлен (apt install gnupg)."
        return 1
    fi
    if ! curl -fsSL --max-time 30 --retry 2 "${base_url}.asc" -o "$tmp_sig" 2>/dev/null || [ ! -s "$tmp_sig" ]; then
        echo "FATAL: detached GPG-подпись (${base_url}.asc) не скачалась — отказываюсь запускать."
        return 1
    fi
    # Проверяем подпись И что она сделана именно пиннутым ключом (status-fd parsing).
    local gpg_status
    gpg_status=$(gpg --status-fd 1 --verify "$tmp_sig" "$file" 2>/dev/null)
    if echo "$gpg_status" | grep -q "VALIDSIG" && \
       echo "$gpg_status" | grep -q "VALIDSIG.*${SETUP_SIG_FINGERPRINT}"; then
        echo "✓ GPG-подпись валидна (key ${SETUP_SIG_FINGERPRINT})"
        return 0
    fi
    echo "FATAL: GPG-подпись отсутствует/невалидна/не от пиннутого ключа (${SETUP_SIG_FINGERPRINT})."
    echo "       Файл мог быть подменён (компрометация репо/MITM). Запуск отменён."
    return 1
}

# v5.0: --check логика вынесена в функцию чтобы TUI [u] мог её вызвать
# напрямую без `exec "$0" --check` (которое ломается при запуске через
# `bash <(curl ...)` — в этом случае $0 == bash, который --check не понимает).
v5_do_check() {
    echo "Текущая версия: v${SCRIPT_VERSION}"
    echo "Скачиваю последнюю версию с github..."
    local check_tmp
    check_tmp=$(mktemp -t vpn-node-check.XXXXXX) || { echo "FATAL: mktemp failed"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -f '$check_tmp'" RETURN

    if ! curl -fsSL --max-time 30 --retry 2 "$SCRIPT_REPO_URL" -o "$check_tmp" 2>/dev/null; then
        echo "ERROR: не смог скачать (network/404). URL: $SCRIPT_REPO_URL"
        return 1
    fi
    if [ ! -s "$check_tmp" ]; then
        echo "ERROR: скачанный файл пустой"
        return 1
    fi
    local upstream_ver
    upstream_ver=$(grep -oE 'XRAY/REMNAWAVE NODE BUILDER v[0-9]+\.[0-9]+(\.[0-9]+)?' "$check_tmp" | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
    if [ -z "$upstream_ver" ]; then
        echo "ERROR: не нашёл version marker в скачанном файле — возможно репозиторий повреждён или это не наш скрипт"
        return 1
    fi
    echo "Upstream версия: v${upstream_ver}"
    if [ "$upstream_ver" = "$SCRIPT_VERSION" ]; then
        echo "✓ У вас последняя версия"
    else
        # Простое сравнение MAJOR.MINOR через sort -V
        local newer
        newer=$(printf '%s\n%s\n' "$SCRIPT_VERSION" "$upstream_ver" | sort -V | tail -1)
        if [ "$newer" = "$upstream_ver" ]; then
            echo "▲ Доступна новая версия: v${upstream_ver} (текущая v${SCRIPT_VERSION})"
            echo ""
            local self_path
            self_path=$(v5_self_invocation)
            echo "Запустить upgrade: sudo bash $self_path --upgrade"
            echo "Diff с текущей:    sudo bash $self_path --diff"
        else
            echo "✓ У вас более новая версия (v${SCRIPT_VERSION}) чем upstream (v${upstream_ver})"
        fi
    fi
    return 0
}

DRY_RUN=0
# v5.0: режим работы. Возможные значения:
#   ""        — не задан CLI, выбираем через TUI (или auto-fallback на optimize в non-TTY)
#   optimize  — прямой запуск оптимизации (старое default behaviour v4.13)
#   diagnose  — прямой запуск диагностики
MODE=""

# v5.0: флаги для node-diagnostic. Заполняются из CLI или TUI.
# Передаются напрямую в node-diagnostic через bash "$tmp" "${DIAG_FLAGS[@]}".
DIAG_FLAGS=()

# v5.0: pre-process — отделяем passthrough после `--`.
# Всё что идёт после `--` передаётся напрямую в node-diagnostic.
# Пример: bash setup.sh --diagnose -- -q -a -v
SETUP_ARGS=()
SAW_DOUBLE_DASH=0
for arg in "$@"; do
    if [ "$arg" = "--" ]; then
        SAW_DOUBLE_DASH=1
        continue
    fi
    if [ "$SAW_DOUBLE_DASH" -eq 1 ]; then
        DIAG_FLAGS+=("$arg")
    else
        SETUP_ARGS+=("$arg")
    fi
done
# Если был --, форсируем mode=diagnose (passthrough флаги имеют смысл только там).
if [ "$SAW_DOUBLE_DASH" -eq 1 ] && [ -z "$MODE" ]; then
    MODE="diagnose"
fi

# Заменяем "$@" на отфильтрованные SETUP_ARGS для основного парсера.
set -- "${SETUP_ARGS[@]}"

for arg in "$@"; do
    case "$arg" in
        --dry-run|-n)
            DRY_RUN=1
            ;;
        --optimize)
            if [ -n "$MODE" ] && [ "$MODE" != "optimize" ]; then
                echo "WARN: --optimize переопределяет ранее заданный режим '$MODE'" >&2
            fi
            MODE="optimize"
            ;;
        --diagnose)
            if [ -n "$MODE" ] && [ "$MODE" != "diagnose" ]; then
                echo "WARN: --diagnose переопределяет ранее заданный режим '$MODE'" >&2
            fi
            MODE="diagnose"
            ;;
        # v5.0: пресеты для диагностики (соответствуют флагам node-diagnostic v3.4)
        --diagnose-quick|--quick-diag)
            MODE="diagnose"
            DIAG_FLAGS+=("-q")
            ;;
        --diagnose-apply|--diag-apply)
            MODE="diagnose"
            DIAG_FLAGS+=("-a")
            ;;
        --diagnose-no-net|--diag-no-net)
            MODE="diagnose"
            DIAG_FLAGS+=("--no-net")
            ;;
        --diagnose-dry-run|--diag-dry-run)
            MODE="diagnose"
            DIAG_FLAGS+=("-n")
            ;;
        --diagnose-verbose|--diag-verbose)
            MODE="diagnose"
            DIAG_FLAGS+=("-v")
            ;;
        --version|-V)
            echo "vpn-node-setup v${SCRIPT_VERSION}"
            exit 0
            ;;
        --check)
            # Проверка наличия новой версии. Не требует root.
            # v5.0: тело вынесено в функцию v5_do_check (определена ниже),
            # чтобы TUI выбор [u] мог вызвать её напрямую — без `exec "$0" --check`,
            # который ломается когда $0 указывает на bash (запуск через `bash <(curl ...)`).
            v5_do_check
            exit $?
            ;;
        --diff)
            # Показать diff между установленной и upstream версией. Не требует root.
            if [ ! -f "$SCRIPT_INSTALLED_PATH" ]; then
                echo "ERROR: установленная версия не найдена ($SCRIPT_INSTALLED_PATH)."
                echo "Видимо скрипт ещё не запускался — запустите его обычным образом."
                exit 1
            fi
            DIFF_TMP=$(mktemp -t vpn-node-diff.XXXXXX) || exit 1
            trap 'rm -f "$DIFF_TMP"' EXIT
            if ! curl -fsSL --max-time 30 --retry 2 "$SCRIPT_REPO_URL" -o "$DIFF_TMP" 2>/dev/null; then
                echo "ERROR: download failed"
                exit 1
            fi
            if command -v diff >/dev/null 2>&1; then
                diff -u "$SCRIPT_INSTALLED_PATH" "$DIFF_TMP" | ${PAGER:-less -R}
            else
                echo "diff не установлен — apt install -y diffutils"
            fi
            exit 0
            ;;
        --upgrade)
            # Безопасный upgrade: download → sanity-check → snapshot → exec.
            # Должен запускаться от root (тот же setup'у нужен root).
            if [[ $EUID -ne 0 ]]; then
                echo "FATAL: --upgrade требует sudo"
                exit 1
            fi
            mkdir -p "$SCRIPT_STATE_DIR"

            UPGRADE_TMP=$(mktemp /tmp/vpn-node-upgrade.XXXXXX.sh) || { echo "FATAL: mktemp failed"; exit 1; }
            trap 'rm -f "$UPGRADE_TMP"' EXIT
            echo "Скачиваю $SCRIPT_REPO_URL ..."
            if ! curl -fsSL --max-time 60 --retry 2 "$SCRIPT_REPO_URL" -o "$UPGRADE_TMP"; then
                echo "FATAL: download failed (network/404/TLS). Текущая версия не тронута."
                exit 1
            fi
            # 1) Sanity: непустой
            if [ ! -s "$UPGRADE_TMP" ]; then
                echo "FATAL: скачанный файл пустой. Aborting."
                exit 1
            fi
            # 2) Sanity: shebang
            if ! head -3 "$UPGRADE_TMP" | grep -q '^#!/bin/bash'; then
                echo "FATAL: скачанный файл не bash-скрипт (нет shebang). Aborting."
                echo "Проверь содержимое: head -5 $UPGRADE_TMP"
                exit 1
            fi
            # 3) Sanity: не HTML
            if head -3 "$UPGRADE_TMP" | grep -qiE '<html|<!doctype'; then
                echo "FATAL: скачанный файл — HTML (cloudflare error / github maintenance). Aborting."
                exit 1
            fi
            # 4) Sanity: version marker
            UPSTREAM_VER=$(grep -oE 'XRAY/REMNAWAVE NODE BUILDER v[0-9]+\.[0-9]+(\.[0-9]+)?' "$UPGRADE_TMP" | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
            if [ -z "$UPSTREAM_VER" ]; then
                echo "FATAL: не нашёл version marker — это не наш скрипт. Aborting."
                exit 1
            fi
            # 5) Sanity: bash syntax
            if ! bash -n "$UPGRADE_TMP" 2>/dev/null; then
                echo "FATAL: скачанный скрипт имеет syntax errors. Aborting."
                echo "Проверь: bash -n $UPGRADE_TMP"
                exit 1
            fi
            echo "Sanity checks пройдены. Текущая: v${SCRIPT_VERSION}, upstream: v${UPSTREAM_VER}"

            # 5.5) v5.3.0 (fix #5): проверка detached-подписи (если включена).
            if ! v5_verify_signature "$UPGRADE_TMP" "$SCRIPT_REPO_URL"; then
                echo "FATAL: проверка подписи апдейта провалена. Текущая версия не тронута."
                exit 1
            fi

            # Если версии равны — спросим подтверждение
            if [ "$UPSTREAM_VER" = "$SCRIPT_VERSION" ]; then
                echo ""
                echo "Версии совпадают (v${SCRIPT_VERSION}). Запустить ре-установку всё равно?"
                read -r -p "[y/N]: " ANS
                case "$ANS" in y|Y|yes|YES) ;; *) echo "Отменено."; exit 0 ;; esac
            fi

            # 6) Snapshot для возможного rollback'а
            echo "Сохраняю snapshot текущего состояния..."
            # Сохраняем текущую "установленную" версию как previous (для rollback)
            if [ -f "$SCRIPT_INSTALLED_PATH" ]; then
                cp -a "$SCRIPT_INSTALLED_PATH" "$SCRIPT_PREVIOUS_PATH"
                echo "  ✓ Предыдущая версия сохранена для rollback: $SCRIPT_PREVIOUS_PATH"
            else
                # Первый upgrade: предыдущая версия не известна (скрипт запускался раньше но без --upgrade flow)
                # Сохраняем текущий запущенный файл если возможно
                if [ -f "${BASH_SOURCE[0]}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
                    cp -a "${BASH_SOURCE[0]}" "$SCRIPT_PREVIOUS_PATH"
                    echo "  ✓ Текущий скрипт сохранён как previous: $SCRIPT_PREVIOUS_PATH"
                fi
            fi
            # Sysctl/systemd snapshot
            SNAP_DIR="$SCRIPT_STATE_DIR/snapshots/upgrade-v${SCRIPT_VERSION}-to-v${UPSTREAM_VER}-$(date -u +%Y%m%dT%H%M%SZ)"
            mkdir -p "$SNAP_DIR"
            [ -d /etc/sysctl.d ] && cp -a /etc/sysctl.d "$SNAP_DIR/sysctl.d" 2>/dev/null
            [ -d /etc/security/limits.d ] && cp -a /etc/security/limits.d "$SNAP_DIR/limits.d" 2>/dev/null
            for unit in rps-tuning.service nic-tuning.service; do
                [ -f "/etc/systemd/system/$unit" ] && cp -a "/etc/systemd/system/$unit" "$SNAP_DIR/" 2>/dev/null
            done
            for s in /usr/local/sbin/rps-tuning.sh /usr/local/sbin/nic-tuning.sh; do
                [ -f "$s" ] && cp -a "$s" "$SNAP_DIR/" 2>/dev/null
            done
            # Указатель на последний snapshot для rollback
            echo "$SNAP_DIR" > "$SCRIPT_STATE_DIR/.last_upgrade_snapshot"
            # Чистим старые snapshots (оставляем последние 3)
            ls -1dt "$SCRIPT_STATE_DIR/snapshots"/upgrade-* 2>/dev/null | tail -n +4 | xargs -r rm -rf
            echo "  ✓ Snapshot: $SNAP_DIR"

            # 7) v5.0.4 (fix #52): atomic transaction вместо cp+exec.
            # Раньше: cp UPGRADE_TMP → installed.sh, потом exec installed.sh.
            # Если новая версия падает на dpkg integrity check / sanity check —
            # installed.sh уже указывает на неё, состояние сломано.
            # Теперь: bash UPGRADE_TMP в subprocess, exit code проверяется,
            # cp в installed.sh ТОЛЬКО при success. Минус: родительский процесс
            # остаётся в памяти ~5-15 мин пока optimize идёт. На 1GB ноде +50MB ≈ OK.
            chmod +x "$UPGRADE_TMP"
            echo ""
            echo "▶ Запускаю v${UPSTREAM_VER} (без promotion installed.sh до success)..."
            echo "  Если упадёт — текущая версия (v${SCRIPT_VERSION}) останется активной."
            echo "  Snapshot создан: $SNAP_DIR"
            echo ""
            sleep 2
            # Снимаем trap чтобы UPGRADE_TMP не удалился (он нужен для запуска)
            trap - EXIT
            # v5.0: передаём --optimize новой версии явно. Раньше (v4.13) запускали
            # без аргументов и попадали в default optimize flow. С v5.0 default —
            # TUI меню, и юзер делавший --upgrade неожиданно увидел бы меню вместо
            # автозапущенной оптимизации (регрессия). Поведение --upgrade всегда
            # было "скачать и применить", сохраняем эту семантику.
            # v5.3.0 (fix #6): SETUP_NO_REBOOT=1 — ребёнок НЕ перезагружает сервер сам.
            # Иначе reboot внутри новой версии убивал родителя ДО promote installed.sh →
            # после ребута версия оставалась старой. Reboot предлагает родитель ниже,
            # уже ПОСЛЕ успешного promote.
            if SETUP_NO_REBOOT=1 bash "$UPGRADE_TMP" --optimize; then
                # Success — promote new version в installed.sh
                cp -a "$UPGRADE_TMP" "$SCRIPT_INSTALLED_PATH"
                echo "$UPSTREAM_VER" > "$SCRIPT_VERSION_FILE"
                chmod +x "$SCRIPT_INSTALLED_PATH"
                echo ""
                echo "✓ Upgrade успешен: v${SCRIPT_VERSION} → v${UPSTREAM_VER}"
                echo "  installed.sh обновлён."
                rm -f "$UPGRADE_TMP"
                # v5.3.0 (fix #6): reboot предлагаем здесь, уже ПОСЛЕ promote.
                if [ -f /run/reboot-required ] || [ -f "$SCRIPT_STATE_DIR/.reboot-needed" ]; then
                    rm -f "$SCRIPT_STATE_DIR/.reboot-needed" 2>/dev/null
                    echo ""
                    echo "  ⚠️  Новая версия установила/сменила ядро — нужен reboot для активации."
                    if [ -t 0 ]; then
                        read -r -p "  Перезагрузить сейчас? (y/N): " RB < /dev/tty
                        case "$RB" in y|Y|yes|YES) echo "  Перезагрузка через 3 сек..."; sleep 3; reboot ;; *) echo "  Не забудь: sudo reboot" ;; esac
                    else
                        echo "  Выполни вручную: sudo reboot"
                    fi
                fi
                exit 0
            else
                RC=$?
                echo ""
                echo "✖ Новая версия v${UPSTREAM_VER} завершилась с exit code $RC."
                echo "  installed.sh НЕ обновлён — текущая v${SCRIPT_VERSION} остаётся активной."
                echo "  Snapshot: $SNAP_DIR (на случай если новая версия успела что-то применить)."
                echo "  Для rollback применённых sysctl/limits: sudo bash $SCRIPT_INSTALLED_PATH --rollback"
                rm -f "$UPGRADE_TMP"
                exit $RC
            fi
            ;;
        --rollback)
            if [[ $EUID -ne 0 ]]; then
                echo "FATAL: --rollback требует sudo"
                exit 1
            fi
            if [ ! -f "$SCRIPT_PREVIOUS_PATH" ]; then
                echo "FATAL: previous версия не найдена ($SCRIPT_PREVIOUS_PATH)"
                echo "Rollback возможен только после того как делали --upgrade хотя бы один раз."
                exit 1
            fi
            PREV_VER=$(grep -oE 'XRAY/REMNAWAVE NODE BUILDER v[0-9]+\.[0-9]+(\.[0-9]+)?' "$SCRIPT_PREVIOUS_PATH" | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
            echo "Rollback к v${PREV_VER:-?} из $SCRIPT_PREVIOUS_PATH"
            read -r -p "Подтвердить? [y/N]: " ANS
            case "$ANS" in y|Y|yes|YES) ;; *) echo "Отменено."; exit 0 ;; esac

            # Восстанавливаем sysctl.d/limits.d из последнего snapshot'а
            SNAP_PTR="$SCRIPT_STATE_DIR/.last_upgrade_snapshot"
            if [ -f "$SNAP_PTR" ]; then
                SNAP=$(cat "$SNAP_PTR")
                if [ -n "$SNAP" ] && [ -d "$SNAP" ]; then
                    echo "Восстанавливаю snapshot: $SNAP"
                    [ -d "$SNAP/sysctl.d" ] && cp -a "$SNAP/sysctl.d/." /etc/sysctl.d/
                    [ -d "$SNAP/limits.d" ] && cp -a "$SNAP/limits.d/." /etc/security/limits.d/
                    for unit in rps-tuning.service nic-tuning.service; do
                        [ -f "$SNAP/$unit" ] && cp -a "$SNAP/$unit" "/etc/systemd/system/$unit"
                    done
                    [ -f "$SNAP/rps-tuning.sh" ] && cp -a "$SNAP/rps-tuning.sh" /usr/local/sbin/
                    [ -f "$SNAP/nic-tuning.sh" ] && cp -a "$SNAP/nic-tuning.sh" /usr/local/sbin/
                    sysctl --system >/dev/null 2>&1 || true
                    systemctl daemon-reload 2>/dev/null
                    systemctl restart rps-tuning.service nic-tuning.service 2>/dev/null || true
                    echo "  ✓ sysctl/systemd восстановлены"
                fi
            fi

            # Меняем installed = previous
            cp -a "$SCRIPT_PREVIOUS_PATH" "$SCRIPT_INSTALLED_PATH"
            [ -n "$PREV_VER" ] && echo "$PREV_VER" > "$SCRIPT_VERSION_FILE"
            echo ""
            echo "Rollback завершён. Версия: v${PREV_VER:-?}"
            echo "Запустите скрипт для применения восстановленных правил, либо reboot."
            exit 0
            ;;
        --help|-h)
            # v5.0 BUGFIX: $0 при `bash <(curl ...)` равен /dev/fd/63 — путаем юзера.
            HELP_INVOC=$(v5_self_invocation)
            cat <<HELP
Usage: bash $HELP_INVOC [OPTIONS]

Без аргументов (TTY):     Показать TUI меню (оптимизация / диагностика).
Без аргументов (non-TTY): Запустить оптимизацию (--optimize). Backward compat для CI.

OPTIONS:
  --optimize       Прямой запуск оптимизации без TUI (для CI/ansible).
                   То же что было default behaviour до v5.0.

  --diagnose       Прямой запуск диагностики без TUI.
                   Скачивает node-diagnostic от Case211 с github и запускает его.
                   Полный прогон ~5 мин (23 проверки).

  --diagnose-quick      Быстрый прогон диагностики (~1 мин, без mtr/4-flow/multi-CDN).
  --diagnose-apply      Применить ВСЕ рекомендованные node-diagnostic'ом фиксы
                        без интерактивного запроса (-a). ВНИМАНИЕ: эти фиксы могут
                        конфликтовать с нашим стэком (somaxconn=8192 деградация в
                        8x vs наши 65535, default_qdisc=cake вместо нашего fq).
                        Используй с осторожностью; рекомендуется --optimize вместо.
  --diagnose-no-net     Только локальные проверки, без сетевых тестов.
  --diagnose-dry-run    Показать что было бы применено node-diagnostic'ом, не делать.
  --diagnose-verbose    Детальный режим (-v).

                   Также поддерживается passthrough любых флагов через `--`:
                     bash setup.sh --diagnose -- -q -a
                     bash setup.sh --diagnose -- --no-net -v

  --dry-run, -n    Не устанавливать ядро через apt; только показать что было бы.
                   Sysctl/лимиты применяются как обычно (можно откатить руками).

  --version, -V    Показать версию скрипта (v${SCRIPT_VERSION}).

  --check          Проверить наличие новой версии на github.
                   Не требует sudo. Показывает changelog'и при наличии.

  --diff           Показать diff между установленной и upstream версией.
                   Использует \$PAGER (less по умолчанию).

  --upgrade        Скачать последнюю версию с github и запустить её.
                   Делает sanity-check (shebang/version marker/bash syntax)
                   и snapshot текущих sysctl.d/systemd/limits.d перед запуском.
                   Требует sudo.

  --rollback       Восстановить предыдущую версию (после неудачного --upgrade).
                   Восстанавливает sysctl.d, limits.d, rps-tuning, nic-tuning
                   из snapshot'а сделанного перед последним upgrade.
                   Требует sudo.

  --help, -h       Показать это сообщение.

Examples:
  sudo bash $HELP_INVOC                  # TTY: TUI меню. non-TTY: оптимизация.
  sudo bash $HELP_INVOC --optimize       # Прямая оптимизация без меню (CI/ansible).
  sudo bash $HELP_INVOC --diagnose       # Прямая диагностика без меню.
  sudo bash $HELP_INVOC --dry-run        # Посмотреть что будет
  bash $HELP_INVOC --check               # Проверить новую версию
  sudo bash $HELP_INVOC --upgrade        # Безопасный self-upgrade
  sudo bash $HELP_INVOC --rollback       # Откатиться к предыдущей версии

Environment variables:
  DISABLE_TFO=1    Отключить TCP Fast Open (по умолчанию TFO=3 включён в v5.0.3+).
                   Используй только если нода стоит за CDN/middlebox который
                   может дропать SYN с TFO cookie. Пример:
                     DISABLE_TFO=1 sudo bash $HELP_INVOC --optimize

  SCRIPT_REPO_URL  Переопределить URL для --check/--upgrade.

Repository: $SCRIPT_REPO_URL
HELP
            exit 0
            ;;
    esac
done

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
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
print_warn()   { echo -e "${YELLOW}⚠${NC} $1"; }

# ==============================================================================
# v5.0: TUI MENU + MODE DISPATCH
# ==============================================================================

# Detect Unicode/UTF-8 capability for box-drawing & emoji.
# Fallback на ASCII если терминал не UTF-8 (старые tmux, dumb terminal, raw serial).
v5_detect_unicode() {
    local cm
    cm=$(locale charmap 2>/dev/null || echo "")
    if [[ "$cm" =~ [Uu][Tt][Ff]-?8 ]] || [[ "${LANG:-}" =~ [Uu][Tt][Ff]-?8 ]] || [[ "${LC_ALL:-}" =~ [Uu][Tt][Ff]-?8 ]]; then
        return 0
    fi
    return 1
}

# Detect TTY (interactive). non-TTY (CI, ansible, `echo "" | bash setup.sh`)
# → fallback на --optimize behaviour (backward compat с v4.13).
v5_is_tty() {
    [ -t 0 ] && [ -t 1 ]
}

# Diagnostic runner: скачивает свежий node-diagnostic от Case211 и запускает.
# Не копируем 1700+ строк в наш скрипт — Case211 поддерживает его отдельно,
# мы получаем обновления автоматически.
#
# v5.0: поддерживает passthrough флагов в node-diagnostic через global $DIAG_FLAGS
# (массив). Заполняется из CLI (--diagnose-quick, --diagnose-apply etc) или
# из TUI-подменю (v5_show_diag_submenu).
#
# Доступные флаги node-diagnostic v3.4:
#   -q, --quick    Быстрый прогон ~1 мин (без mtr/4-flow/multi-CDN/services/...)
#   -a             Применить ВСЕ рекомендованные фиксы без вопросов
#   -n, --dry-run  Показать что было бы применено, не делать
#   --no-net       Только локальные проверки (без сетевых тестов)
#   -v             Детальный режим
diag_run() {
    local diag_url="${NODE_DIAG_URL:-https://raw.githubusercontent.com/Case211/node-diagnostic/main/node-diagnostic.sh}"
    local tmp
    tmp=$(mktemp /tmp/node-diagnostic-XXXXXX.sh) || { print_error "mktemp failed"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    print_status "Скачиваю node-diagnostic с github..."
    if ! curl -fsSL --max-time 60 --retry 2 "$diag_url" -o "$tmp"; then
        print_error "Не удалось скачать node-diagnostic. Проверь интернет."
        print_info "URL: $diag_url"
        return 1
    fi

    # Sanity-check (как в --upgrade flow):
    if [ ! -s "$tmp" ]; then
        print_error "Скачанный файл пустой"
        return 1
    fi
    if head -3 "$tmp" | grep -qiE '<html|<!doctype'; then
        print_error "Получен HTML вместо bash (возможно captive portal или 404 page)"
        return 1
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        print_error "Bash syntax error в скачанном файле — отказываюсь запускать"
        return 1
    fi
    if ! grep -q "NODE DIAGNOSTIC\|node-diagnostic" "$tmp"; then
        print_error "Не похоже на node-diagnostic (content marker не найден)"
        return 1
    fi

    # v5.3.0 (fix #5): проверка detached-подписи node-diagnostic (если включена).
    # node-diagnostic — сторонний скрипт (Case211); подписать его своим ключом
    # можно только если ты сам зеркалишь его и кладёшь .asc/.minisig рядом.
    if ! v5_verify_signature "$tmp" "$diag_url"; then
        print_error "Проверка подписи node-diagnostic провалена — отказываюсь запускать."
        return 1
    fi

    chmod +x "$tmp"
    if [ ${#DIAG_FLAGS[@]} -gt 0 ]; then
        print_ok "node-diagnostic прошёл sanity-check, запускаю с флагами: ${DIAG_FLAGS[*]}"
    else
        print_ok "node-diagnostic прошёл sanity-check, запускаю (полный прогон)..."
    fi
    echo ""
    bash "$tmp" "${DIAG_FLAGS[@]}"
    local rc=$?
    echo ""
    print_info "Диагностика завершена (exit code: $rc)"
    return $rc
}

# v5.0 (Вариант A): подменю диагностики после выбора [2] в главном меню.
# Заполняет global $DIAG_FLAGS на основе выбора пользователя.
v5_show_diag_submenu() {
    local use_unicode=0
    v5_detect_unicode && use_unicode=1

    clear 2>/dev/null || true
    echo ""
    if [ "$use_unicode" = "1" ]; then
        echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}          ${BOLD}🔍 Режим диагностики${NC}                                 ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}          node-diagnostic от Case211                              ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${BOLD}Выбери режим прогона:${NC}"
        echo ""
        echo -e "    ${GREEN}[1]${NC} 🐢 ${BOLD}Полный прогон${NC} (~5 мин)        23 проверки + Score 0-100  ${YELLOW}рекомендуется${NC}"
        echo -e "    ${GREEN}[2]${NC} ⚡ ${BOLD}Быстрый прогон${NC} (~1 мин)       Без mtr/4-flow/multi-CDN/services"
        echo -e "    ${GREEN}[3]${NC} 🔌 ${BOLD}Только локальные${NC}              Без сетевых тестов (off-line диагностика)"
        echo -e "    ${YELLOW}[4]${NC} 📋 ${BOLD}Dry-run${NC}                       Показать что было бы применено, не делать"
        echo -e "    ${RED}[5]${NC} 🚀 ${BOLD}Auto-apply${NC} (опасно!)          Применить ВСЕ рекомендованные фиксы без вопросов"
        echo ""
        echo -e "    ${MAGENTA}[b]${NC} Назад в главное меню"
        echo -e "    ${RED}[q]${NC} Выход"
    else
        # ASCII fallback
        echo "+================================================================+"
        echo "|         Diagnostic mode                                        |"
        echo "|         node-diagnostic by Case211                             |"
        echo "+================================================================+"
        echo ""
        echo "  Choose diagnostic mode:"
        echo ""
        echo "    [1] Full run (~5 min)         23 checks + Score 0-100  [recommended]"
        echo "    [2] Quick run (~1 min)        Skips mtr/4-flow/multi-CDN/services"
        echo "    [3] Local only                No network tests"
        echo "    [4] Dry-run                   Show what would be applied"
        echo "    [5] Auto-apply (dangerous!)   Apply ALL recommended fixes without asking"
        echo ""
        echo "    [b] Back to main menu"
        echo "    [q] Quit"
    fi
    echo ""

    if [ "$use_unicode" = "1" ]; then
        echo -e "  ${YELLOW}⚠${NC}  ${BOLD}Auto-apply${NC} использует node-diagnostic'овские фиксы напрямую."
        echo -e "     Они могут конфликтовать с нашим стэком (somaxconn=8192 деградация в"
        echo -e "     8x vs наши 65535, default_qdisc=cake вместо fq, rmem_max=64MB"
        echo -e "     лишний для tier-aware профилей)."
        echo -e "     Если хочешь применить ${BOLD}наши${NC} оптимизации после диагностики —"
        echo -e "     запусти потом ${CYAN}--optimize${NC} (вариант [1] в главном меню)."
    else
        echo "  WARN: Auto-apply uses node-diagnostic's fixes directly."
        echo "        They may conflict with our stack (somaxconn=8192 = 8x degradation,"
        echo "        default_qdisc=cake instead of fq)."
        echo "        For safe optimization use --optimize after diagnostic."
    fi
    echo ""

    local choice=""
    while true; do
        read -r -p "  > " choice < /dev/tty
        case "${choice,,}" in
            1|full|f)
                # Полный прогон — без флагов
                return 0
                ;;
            2|quick)
                # v5.3.0 (fix #3): убран алиас 'q' — он перехватывал клавишу выхода
                # (паттерн q|quit|exit ниже никогда не срабатывал). Быстрый прогон: 2/quick.
                DIAG_FLAGS+=("-q")
                return 0
                ;;
            3|local|no-net|nonet)
                DIAG_FLAGS+=("--no-net")
                return 0
                ;;
            4|dry|dry-run|n)
                DIAG_FLAGS+=("-n")
                return 0
                ;;
            5|apply|auto|a)
                # Доп подтверждение для auto-apply (это опасный режим)
                echo ""
                if [ "$use_unicode" = "1" ]; then
                    echo -e "  ${RED}⚠${NC}  Auto-apply ${BOLD}применит ВСЕ${NC} рекомендованные фиксы node-diagnostic'а"
                    echo -e "     без интерактивного запроса. Это может включать опасные для нашего"
                    echo -e "     стэка настройки (somaxconn=8192, default_qdisc=cake, rmem_max=64MB)."
                else
                    echo "  WARN: Auto-apply will apply ALL fixes without interactive prompt."
                    echo "        May include settings dangerous for our stack."
                fi
                echo ""
                read -r -p "  Точно продолжить с auto-apply? [yes/N]: " confirm < /dev/tty
                case "${confirm,,}" in
                    yes|y)
                        DIAG_FLAGS+=("-a")
                        return 0
                        ;;
                    *)
                        echo "  Auto-apply отменён, возвращаюсь в подменю..."
                        sleep 1
                        v5_show_diag_submenu
                        return $?
                        ;;
                esac
                ;;
            b|back)
                MODE=""
                return 1
                ;;
            q|quit|exit)
                MODE="quit"
                return 1
                ;;
            "")
                echo "  Введи цифру: 1, 2, 3, 4, 5, b, q"
                ;;
            *)
                echo "  Неверный выбор: '$choice'. Доступно: 1-5, b, q"
                ;;
        esac
    done
}

# TUI меню. Возвращает выбранный режим через global var $MODE.
# Поддерживает UTF-8 + ASCII fallback.
v5_show_tui() {
    local use_unicode=0
    v5_detect_unicode && use_unicode=1

    clear 2>/dev/null || true
    echo ""
    if [ "$use_unicode" = "1" ]; then
        echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}          ${BOLD}VPN NODE BUILDER v${SCRIPT_VERSION}${NC}                                  ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}          Оптимизация + диагностика VPN-ноды                      ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${BOLD}Что делаем?${NC}"
        echo ""
        echo -e "    ${GREEN}[1]${NC} 🛠  ${BOLD}Оптимизировать ноду${NC}     XanMod kernel + BBR + sysctl + MSS clamp"
        echo -e "    ${YELLOW}[2]${NC} 🔍 ${BOLD}Провести диагностику${NC}    node-diagnostic от Case211 (23 проверки → Score)"
        echo ""
        echo -e "    ${MAGENTA}[u]${NC} 🔄 Проверить обновление    Сравнить с github (--check)"
        echo -e "    ${RED}[q]${NC} Выход"
    else
        # ASCII fallback
        echo "+================================================================+"
        echo "|          VPN NODE BUILDER v${SCRIPT_VERSION}                                  |"
        echo "|          Optimize + diagnose VPN node                          |"
        echo "+================================================================+"
        echo ""
        echo "  What to do?"
        echo ""
        echo "    [1] Optimize node       XanMod kernel + BBR + sysctl + MSS clamp"
        echo "    [2] Run diagnostic      node-diagnostic by Case211 (23 checks)"
        echo ""
        echo "    [u] Check for updates   Compare with github (--check)"
        echo "    [q] Quit"
    fi
    echo ""

    local choice=""
    while true; do
        read -r -p "  > " choice < /dev/tty
        case "${choice,,}" in
            1|optimize|opt|o)
                MODE="optimize"
                return 0
                ;;
            2|diagnose|diag|d)
                MODE="diagnose"
                # v5.0 (Вариант A): после выбора [2] показываем под-меню
                # с режимами диагностики (full / quick / local / dry-run / auto-apply).
                # Под-меню заполняет $DIAG_FLAGS. Если юзер выбрал [b] — MODE
                # сбрасывается, главное меню показывается снова.
                if v5_show_diag_submenu; then
                    return 0
                else
                    # [b] back или [q] quit из подменю
                    if [ "$MODE" = "quit" ]; then
                        return 0
                    fi
                    # Иначе — show_tui снова
                    v5_show_tui
                    return $?
                fi
                ;;
            u|upgrade|update|check)
                MODE="check"
                return 0
                ;;
            q|quit|exit|"")
                if [ -z "$choice" ]; then
                    # Empty enter — re-prompt вместо exit
                    echo "  Введи цифру: 1, 2, u или q"
                    continue
                fi
                MODE="quit"
                return 0
                ;;
            *)
                echo "  Неверный выбор: '$choice'. Доступно: 1, 2, u, q"
                ;;
        esac
    done
}

# v5.0 dispatcher: применяется ДО основного flow оптимизации.
# Если MODE задан через CLI (--optimize / --diagnose) — используем его.
# Иначе — TUI (если TTY) или fallback на optimize (non-TTY = backward compat).

# v5.0.1 BUGFIX: устанавливаем installed.sh РАНО (до диагностики/TUI/optimize).
# Раньше installed.sh создавался только в конце optimize (строка ~3137), и после
# diagnose файла не было — v5_self_invocation() возвращала длинный curl-one-liner,
# который клиенты не могли скопировать корректно (обрезалось в терминале/telegram).
# Теперь после первого же запуска короткий путь /var/lib/vpn-node-builder/installed.sh
# доступен для повторных вызовов (--check, --upgrade, повторный --optimize и т.д.).
if [ -f "${BASH_SOURCE[0]}" ] && [ -r "${BASH_SOURCE[0]}" ] && [ "$(id -u)" = "0" ]; then
    # Только если запускаемся из реального файла (не из process substitution
    # /dev/fd/N) и от root — нет смысла копировать /dev/fd/63.
    case "${BASH_SOURCE[0]}" in
        /dev/fd/*|/proc/self/fd/*)
            # v5.0.6 CRITICAL FIX: при запуске через `bash <(curl ...)` BASH_SOURCE
            # это FIFO (pipe). К моменту достижения этой строки bash УЖЕ потребил
            # значительную часть скрипта из pipe — `cat /dev/fd/N` прочтёт ТОЛЬКО
            # остаток (от ~текущей строки до конца), а не весь скрипт.
            # Результат: installed.sh был обрезанным → повторные запуски через
            # короткий путь падали с syntax error или incomplete script.
            # Fix: скачиваем upstream версию заново через curl.
            mkdir -p "$SCRIPT_STATE_DIR" 2>/dev/null
            if command -v curl >/dev/null 2>&1 && \
               curl -fsSL --max-time 30 --retry 2 "$SCRIPT_REPO_URL" -o "$SCRIPT_INSTALLED_PATH.tmp" 2>/dev/null && \
               [ -s "$SCRIPT_INSTALLED_PATH.tmp" ] && \
               head -1 "$SCRIPT_INSTALLED_PATH.tmp" | grep -q '^#!/bin/bash'; then
                mv "$SCRIPT_INSTALLED_PATH.tmp" "$SCRIPT_INSTALLED_PATH"
                echo "$SCRIPT_VERSION" > "$SCRIPT_VERSION_FILE" 2>/dev/null
                chmod 0644 "$SCRIPT_INSTALLED_PATH" "$SCRIPT_VERSION_FILE" 2>/dev/null
            else
                # Если download не удался — НЕ создаём битый installed.sh из cat fd.
                rm -f "$SCRIPT_INSTALLED_PATH.tmp" 2>/dev/null
            fi
            ;;
        *)
            mkdir -p "$SCRIPT_STATE_DIR" 2>/dev/null
            cp -a "${BASH_SOURCE[0]}" "$SCRIPT_INSTALLED_PATH" 2>/dev/null
            echo "$SCRIPT_VERSION" > "$SCRIPT_VERSION_FILE" 2>/dev/null
            chmod 0644 "$SCRIPT_INSTALLED_PATH" "$SCRIPT_VERSION_FILE" 2>/dev/null
            ;;
    esac
fi

if [ -z "$MODE" ]; then
    if v5_is_tty; then
        v5_show_tui
    else
        # non-TTY (CI, ansible, pipe) → backward compat: запускаем оптимизацию
        MODE="optimize"
    fi
fi

case "$MODE" in
    diagnose)
        # Диагностика → запускаем node-diagnostic от Case211 → exit.
        # После завершения юзер сам решит запускать оптимизацию или нет.
        diag_run
        diag_rc=$?
        if [ $diag_rc -eq 0 ]; then
            echo ""
            print_info "Чтобы применить НАШИ оптимизации (vpn-node-setup v${SCRIPT_VERSION}):"
            echo ""
            # v5.0.1: даём ВСЕГДА вариант через installed.sh — он сохранён
            # перед dispatcher'ом (см. блок выше). Это короткая команда которая
            # работает в любом shell и не обрезается при копировании.
            if [ -f "$SCRIPT_INSTALLED_PATH" ]; then
                echo -e "    ${BOLD}${GREEN}sudo bash $SCRIPT_INSTALLED_PATH --optimize${NC}"
                echo ""
                echo -e "    ${DIM}Альтернатива (если installed.sh потерян):${NC}"
                echo -e "    ${DIM}  sudo bash <(curl -fsSL ${SCRIPT_REPO_URL}) --optimize${NC}"
            else
                # installed.sh не сохранился (не root? read-only fs?) — fallback на curl
                echo -e "    ${BOLD}${GREEN}sudo bash <(curl -fsSL ${SCRIPT_REPO_URL}) --optimize${NC}"
                echo ""
                print_warn "ВАЖНО: команда содержит '<(...)' — process substitution."
                print_warn "Работает ТОЛЬКО в bash (не в sh, dash). Копируй ЦЕЛИКОМ, включая скобки."
            fi
            echo ""
            print_warn "node-diagnostic'овские fix_sysctl/fix_mss/fix_rps/fix_ring НЕ применять напрямую —"
            print_warn "они конфликтуют с нашим стэком (somaxconn=8192 деградация в 8 раз vs наши"
            print_warn "65535, default_qdisc=cake вместо fq, rmem_max=64MB лишний для tier-aware профилей)."
        fi
        exit $diag_rc
        ;;
    check)
        # Из TUI выбран [u] — вызываем функцию напрямую (см. v5_do_check выше).
        # Не используем `exec "$0" --check` — ломается при `bash <(curl ...)`
        # потому что $0 в этом случае == bash, а bash не знает --check.
        v5_do_check
        exit $?
        ;;
    quit)
        echo ""
        echo "  Выход. Запусти повторно когда нужно."
        echo ""
        exit 0
        ;;
    optimize)
        # Падаем дальше в основной flow оптимизации (ШАГ 1 .. ШАГ 9 ниже)
        :
        ;;
    *)
        print_error "Неизвестный режим: '$MODE'"
        exit 1
        ;;
esac

# ==============================================================================
# v5.0: MSS CLAMP HELPERS (используются в ШАГ 7.8)
# ==============================================================================

# Detect присутствие shieldnode для информационного сообщения о приоритетах.
# Не модифицирует ничего — только читает.
v5_shieldnode_detected() {
    [ -f /etc/sysctl.d/90-shieldnode.conf ] || \
        systemctl is-active --quiet shieldnode-nftables 2>/dev/null || \
        systemctl is-active --quiet vpn-node-ddos-protect 2>/dev/null || \
        nft list tables 2>/dev/null | grep -qE 'inet ddos_protect'
}

# Получить версию nft в формате "1.0" (major.minor).
v5_nft_version() {
    nft --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+' | head -1 | tr -d 'v'
}

# Сравнить семвер: возвращает 0 если $1 >= $2.
v5_ver_ge() {
    [ "$1" = "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" ]
}

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
echo -e "${BOLD}  XRAY/REMNAWAVE NODE BUILDER v5.3.3 (Universal: Optimize + Diagnose)${NC}"
echo -e "  ${YELLOW}XanMod LTS + BBRv3 + Очистка + Сетевой стек + Conntrack + Gaming-friendly${NC}"
echo -e "  ${GREEN}+ Safe boosts: notsent_lowat, GRO, ethtool, XPS, IRQ affinity, MSS clamp${NC}"
echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "  ${MAGENTA}${BOLD}*** DRY-RUN MODE: ядро НЕ будет установлено через apt ***${NC}"
    echo ""
fi
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
    OS_NAME=$(grep '^NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
    OS_VERSION=$(grep '^VERSION=' /etc/os-release | cut -d= -f2 | tr -d '"')
    echo -e "    ├─ Дистрибутив: ${GREEN}${OS_NAME:-unknown}${NC}"
    echo -e "    ├─ Версия: ${GREEN}${OS_VERSION:-unknown}${NC}"
fi
echo -e "    ├─ Ядро: ${GREEN}$(uname -r)${NC}"
echo -e "    └─ Архитектура: ${GREEN}$(uname -m)${NC}"
echo ""

# Инициализируем BACKUP_DIR заранее (используется в pre-flight шагах ниже)
BACKUP_DIR="/root/vpn-node-builder-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

# ==============================================================================
# ШАГ 1.5: PRE-FLIGHT CHECKS (минимальный, без правок сети)
# ==============================================================================

print_header "ШАГ 1.5: PRE-FLIGHT ПРОВЕРКИ"

# v4.10: радикально упрощено после поломок на WaiCore.
# Принцип: ничего не правим автоматически в сети/netplan/fstab/cloud-init.
# Только проверяем критичные вещи и предупреждаем — пусть админ решает сам.

# --- Проверка 0: dpkg integrity (КРИТИЧНО для установки ядра) ---
# Если dpkg в битом состоянии — установка XanMod упадёт посреди процесса
# и оставит систему в нерабочем состоянии. Лучше остановиться здесь.
print_status "Проверяем целостность dpkg (apt database)..."

DPKG_AUDIT_OUT=$(dpkg --audit 2>&1)
if [ -n "$DPKG_AUDIT_OUT" ]; then
    print_warn "dpkg обнаружил незавершённые операции:"
    echo "$DPKG_AUDIT_OUT" | head -10 | sed 's/^/    /'
    echo ""
    print_status "Пытаюсь восстановить через 'dpkg --configure -a'..."
    if dpkg --configure -a 2>&1 | tail -20; then
        DPKG_AUDIT_OUT=$(dpkg --audit 2>&1)
        if [ -n "$DPKG_AUDIT_OUT" ]; then
            print_error "dpkg всё ещё в битом состоянии"
            print_error "Прерывание установки — установка ядра упадёт и сделает хуже"
            print_info "Решите проблему вручную:"
            print_info "  1. dpkg --configure -a"
            print_info "  2. apt-get install -f"
            print_info "  3. Если упорно битый файл: rm /var/lib/dpkg/updates/*"
            exit 1
        fi
        print_ok "dpkg восстановлен"
    fi
else
    print_ok "dpkg в порядке"
fi
echo ""

# --- Проверка: apt/dpkg lock (защита от unattended-upgrades) ---
# v4.11: реальная проблема. unattended-upgrades может работать параллельно и
# держать /var/lib/dpkg/lock-frontend. Установка XanMod падает с ошибкой:
#   "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process X"
#
# Решение: останавливаем unattended-upgrades + apt-daily через systemctl stop
# (НЕ kill -9 — это сломало бы dpkg), ждём корректного завершения активной
# транзакции до 5 минут.
# Безопасно: stop, не disable. Сервисы вернутся при следующем boot или при
# необходимости вручную можно запустить обратно через systemctl start.

print_status "Останавливаю автоматические apt-сервисы (защита от dpkg-lock)..."

# Список сервисов которые могут держать apt/dpkg lock
APT_SERVICES=(
    "unattended-upgrades.service"
    "apt-daily.service"
    "apt-daily-upgrade.service"
)
APT_TIMERS=(
    "apt-daily.timer"
    "apt-daily-upgrade.timer"
)

# v5.0.4 (fix #27): --no-block чтобы не ждать graceful stop до 90 сек.
# Цикл pgrep / fuser ниже корректно дождётся завершения активных транзакций.
# Останавливаем сервисы (не disable — пусть вернутся после ребута)
for svc in "${APT_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop --no-block "$svc" 2>/dev/null || true
        print_info "Остановка запрошена: $svc"
    fi
done

# Останавливаем таймеры чтобы не запустились снова во время скрипта
for tmr in "${APT_TIMERS[@]}"; do
    if systemctl is-active --quiet "$tmr" 2>/dev/null; then
        systemctl stop --no-block "$tmr" 2>/dev/null || true
        print_info "Остановка запрошена: $tmr"
    fi
done

# Ждём корректного завершения активных apt/dpkg транзакций (max 5 мин)
WAIT=0
WAIT_MAX=300
while pgrep -f 'apt-get|(^|/)dpkg( |$)|unattended-upgr' >/dev/null 2>&1; do
    if [ "$WAIT" -ge "$WAIT_MAX" ]; then
        print_error "apt/dpkg висит >5 минут — небезопасно продолжать"
        print_info "Активные процессы:"
        pgrep -af 'apt-get|(^|/)dpkg( |$)|unattended-upgr' | sed 's/^/    /'
        print_info "Подожди завершения и запусти скрипт снова."
        print_info "Если процессы зависли (>30 мин) — проверь journalctl -u unattended-upgrades"
        exit 1
    fi
    if [ "$WAIT" -eq 0 ]; then
        print_status "Жду завершения активной apt/dpkg транзакции..."
    fi
    sleep 5
    WAIT=$((WAIT + 5))
    [ $((WAIT % 30)) -eq 0 ] && print_info "Прошло ${WAIT} сек..."
done

if [ "$WAIT" -gt 0 ]; then
    print_ok "apt/dpkg освободился (ждали ${WAIT} сек)"
else
    print_ok "apt/dpkg свободен"
fi
echo ""

# --- Проверка: GRUB_TIMEOUT (только warning, не правим) ---
# Если GRUB_TIMEOUT=0 — после неудачной загрузки нового ядра нет шанса
# выбрать старое из меню. v4.10 не правит автоматически — только предупреждает.
if [ -f /etc/default/grub ]; then
    CURRENT_TIMEOUT=$(grep -E '^GRUB_TIMEOUT=' /etc/default/grub | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
    if [ -n "$CURRENT_TIMEOUT" ] && [ "$CURRENT_TIMEOUT" -eq 0 ] 2>/dev/null; then
        print_warn "GRUB_TIMEOUT=0 — нет возможности выбрать старое ядро через console"
        print_info "Если новое ядро не загрузится — потребуется hard reset"
        print_info "Рекомендация (применить ВРУЧНУЮ если хочешь):"
        print_info "  sed -i 's/^GRUB_TIMEOUT=0/GRUB_TIMEOUT=2/' /etc/default/grub && update-grub"
    else
        print_ok "GRUB_TIMEOUT=$CURRENT_TIMEOUT (recovery возможен)"
    fi
fi

# --- Проверка: VMware/Hyper-V предупреждение ---
VIRT_TYPE=$(systemd-detect-virt 2>/dev/null)
case "$VIRT_TYPE" in
    "vmware")
        print_warn "Обнаружен VMware. XanMod ядро может конфликтовать со старыми VMware Tools."
        print_info "Если после ребута возникнут проблемы — обновите open-vm-tools"
        ;;
    "microsoft")
        print_warn "Обнаружен Hyper-V. Возможны проблемы с интеграционными сервисами на новом ядре."
        print_info "Если возникнут — переустановите hyperv-daemons после ребута"
        ;;
esac

# --- Проверка: UFW информационная (не трогаем правила) ---
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    print_warn "UFW активен — проверьте после оптимизации:"
    print_info "  • Что Xray/Remnawave порты разрешены (Reality 443, XHTTP 8443 и т.д.)"
    print_info "  • Команда: ufw status verbose"
fi

# --- Проверка: fstab дубликаты (только warning, не правим) ---
# v4.10: НЕ автодедупим. Если есть проблема — админ решит вручную.
# Дубликаты в fstab вызывают warning при boot, но не ломают систему.
if [ -f /etc/fstab ]; then
    SWAP_COUNT=$(awk '!/^[[:space:]]*#/ && NF>=3 && $3=="swap"' /etc/fstab | wc -l)
    if [ "$SWAP_COUNT" -gt 1 ]; then
        print_warn "В /etc/fstab найдено $SWAP_COUNT swap-записей"
        print_info "Это вызывает warning 'Duplicate entry' при boot (не критично)"
        print_info "Чтобы убрать: вручную закомментируй лишние swap-строки в /etc/fstab"
    else
        print_ok "fstab swap: 1 запись"
    fi
fi

# --- v5.0: проверка nftables (нужен для ШАГ 7.8 MSS clamp) ---
# nftables — стандартный пакет на Debian 12+/Ubuntu 22.04+. Если по какой-то
# причине не установлен (минималистичный образ от провайдера) — ставим сейчас,
# пока apt-сервисы остановлены и lock-frontend свободен.
print_status "Проверяем наличие nftables (для MSS clamp в ШАГ 7.8)..."
if ! command -v nft >/dev/null 2>&1; then
    print_info "nft не найден, устанавливаю пакет nftables..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y nftables 2>&1 | tail -5; then
        if command -v nft >/dev/null 2>&1; then
            print_ok "nftables установлен ($(v5_nft_version 2>/dev/null || echo "версия?"))"
        else
            print_warn "apt вернул успех, но nft всё равно не появился — fallback на iptables в ШАГ 7.8"
        fi
    else
        print_warn "Не удалось установить nftables — ШАГ 7.8 попробует fallback на iptables"
    fi
else
    print_ok "nftables присутствует ($(v5_nft_version 2>/dev/null || echo "версия?"))"
fi

# --- v5.0.4 (fix #35): assign DEFAULT_IFACE для NIC driver validation в ШАГ 4 ---
# Раньше переменная использовалась в строках вокруг 1930 (NIC driver compatibility
# check после установки нового XanMod LTS), но НИГДЕ не присваивалась →
# условие [ -n "$DEFAULT_IFACE" ] всегда false → блок "Защита 3: проверка
# драйвера NIC в новом ядре" молча пропускался.
# На vendor-kernel'ах (Alibaba/Yandex Cloud) это могло привести к unbootable
# серверу после reboot на новый XanMod LTS если driver не вкомпилен.
#
# Filtering: исключаем virtual/VPN/loopback интерфейсы — берём physical uplink.
print_status "Определение default network interface для NIC driver check..."
DEFAULT_IFACE=$(ip -4 route show default 2>/dev/null | \
    awk '$5 !~ /^(tun|wg|docker|br-|veth|lo|virbr)/ {print $5; exit}')
if [ -z "$DEFAULT_IFACE" ]; then
    # Fallback: первый non-virtual interface с rx_bytes > 0
    DEFAULT_IFACE=$(for d in /sys/class/net/*; do
        ifname=$(basename "$d")
        [[ "$ifname" =~ ^(lo|tun|wg|docker|br-|veth|virbr) ]] && continue
        rx=$(cat "$d/statistics/rx_bytes" 2>/dev/null || echo 0)
        [ "$rx" -gt 0 ] && echo "$ifname"
    done | head -1)
fi
if [ -n "$DEFAULT_IFACE" ]; then
    print_ok "Default interface: ${BOLD}$DEFAULT_IFACE${NC} (для NIC driver validation после kernel install)"
else
    DEFAULT_IFACE=""
    print_warn "Default interface не определён — NIC driver validation в ШАГ 4 будет пропущена"
fi

# --- Финальное резюме ---
echo ""
print_info "Pre-flight завершён. v4.10 НЕ трогает netplan/cloud-init/network."
print_info "Следующие шаги: установка XanMod + sysctl + NIC бусты + MSS clamp."
echo ""

# ==============================================================================
# ШАГ 2: ОЧИСТКА СИСТЕМЫ
# ==============================================================================

print_header "ШАГ 2: ОЧИСТКА СИСТЕМЫ"

# v4.10: УДАЛЕНО полностью:
#   - детект cloud-провайдера (dmidecode/cloud-init datasource/SSH-keys check)
#   - cloud-init из списка purge (защита SSH-ключей)
#   - snapd из списка purge (может косвенно зависеть cloud-init на Ubuntu Pro)
# Удаляем ТОЛЬКО телеметрию и багрепортеры — они никак не влияют на сеть/SSH.

# --- Бэкап существующих конфигов ---
print_status "Создаём бэкап существующих конфигов..."
# BACKUP_DIR уже создан в начале скрипта
[ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$BACKUP_DIR/" 2>/dev/null
[ -d /etc/sysctl.d ] && cp -r /etc/sysctl.d "$BACKUP_DIR/" 2>/dev/null
[ -d /etc/security/limits.d ] && cp -r /etc/security/limits.d "$BACKUP_DIR/" 2>/dev/null
[ -d /etc/systemd/system.conf.d ] && cp -r /etc/systemd/system.conf.d "$BACKUP_DIR/" 2>/dev/null
print_ok "Бэкап сохранён: $BACKUP_DIR"
echo ""

# --- Удаление ненужных пакетов (только телеметрия и багрепортеры) ---
print_status "Удаляем ненужные пакеты (телеметрия)..."
echo ""
# v4.10: только безопасные удаления.
# НЕ удаляем: snapd (Ubuntu Pro может зависеть), cloud-init (SSH ключи),
# unattended-upgrades (security updates — отключаем как сервис ниже, но не покупаем).
PKGS_TO_PURGE=("apport" "whoopsie" "ubuntu-report" "popularity-contest")

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
print_info "cloud-init и snapd НЕ удаляются (защита от поломки SSH-доступа)"

# --- Отключение ненужных сервисов ---
# Это только disable, пакеты остаются. При необходимости легко включить обратно.
print_status "Отключаем ненужные сервисы..."

# v5.3.0 (fix #9): multipathd НЕ трогаем безусловно. На dedicated с root/storage
# на multipath его отключение делает систему незагружаемой после ребута (maps не
# соберутся). Включаем в список только если активных multipath-карт нет И root не
# на dm/mapper-устройстве.
SERVICES_TO_DISABLE=(
    "ModemManager"
    "fwupd"
    "udisks2"
)

MULTIPATH_IN_USE=0
if command -v multipath >/dev/null 2>&1 && [ -n "$(multipath -ll 2>/dev/null)" ]; then
    MULTIPATH_IN_USE=1
fi
if findmnt -no SOURCE / 2>/dev/null | grep -qE '/dev/mapper/|/dev/dm-'; then
    MULTIPATH_IN_USE=1
fi
if [ "$MULTIPATH_IN_USE" = "1" ]; then
    print_warn "multipathd НЕ отключаю — обнаружены multipath-карты или root на dm/mapper (анти-кирпич)."
else
    SERVICES_TO_DISABLE+=("multipathd")
fi

# v5.3.0 (fix #10): отключение unattended-upgrades теперь opt-out.
# По умолчанию отключаем (как раньше — консервативно, без сюрприз-ребутов и
# авто-смены ядра, что важно при XanMod-пине). НО: это значит НЕТ авто-секьюрити-
# апдейтов. Чтобы ОСТАВИТЬ их — запусти с SETUP_DISABLE_UNATTENDED=0.
if [ "${SETUP_DISABLE_UNATTENDED:-1}" = "1" ]; then
    SERVICES_TO_DISABLE+=("unattended-upgrades")
    # v5.3.3 (fix #A1): disable юнита unattended-upgrades НЕ останавливает периодику —
    # её гонит apt-daily-upgrade.timer → apt.systemd.daily → unattended-upgrade по
    # APT::Periodic (enablement юнита там не проверяется). Реальное отключение:
    # APT::Periodic=0 + disable обоих таймеров.
    cat > /etc/apt/apt.conf.d/99-vpn-node-no-unattended <<'APTEOF'
// Generated by vpn-node-setup v5.3.3 (fix #A1): реальное отключение unattended-upgrades.
// Вернуть авто-апдейты: удалить этот файл + systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APTEOF
    systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    print_warn "unattended-upgrades отключён ПОЛНОСТЬЮ (юнит + таймеры + APT::Periodic=0) → НЕТ авто-секьюрити-апдейтов (включая ядро)."
    print_info "Оставить авто-апдейты: перезапусти с SETUP_DISABLE_UNATTENDED=0"
    print_info "Обновлять вручную: apt-get update && apt-get upgrade (ядро XanMod придёт из его репо)."
else
    RESTART_APT_TIMERS=1
    print_info "unattended-upgrades ОСТАВЛЕН включённым (SETUP_DISABLE_UNATTENDED=0) — авто-секьюрити-апдейты работают."
    print_info "Остановленные в pre-flight apt-таймеры запустятся обратно в конце прогона."
fi

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
systemctl reload systemd-journald 2>/dev/null || systemctl restart systemd-journald 2>/dev/null || true
print_ok "Journald ограничен: SystemMaxUse=100M"

# --- logrotate для remnanode (v5.3.1) ---
# Доки Remnawave требуют ротации логов ноды (/var/log/remnanode), иначе access/
# error логи Xray забьют диск. journald их НЕ покрывает (это файлы по volume, не
# journal). Ставим дропин проактивно: missingok делает его инертным, пока логов
# нет, и рабочим как только нода запишет первый лог. copytruncate — т.к. Xray
# держит файл открытым и не переоткрывает по сигналу logrotate.
if [ "${SETUP_NO_REMNANODE_LOGROTATE:-0}" != "1" ]; then
    print_status "Настраиваю logrotate для логов remnanode..."
    if ! command -v logrotate >/dev/null 2>&1; then
        apt-get install -y logrotate >/dev/null 2>&1 || true
    fi
    if command -v logrotate >/dev/null 2>&1; then
        cat > /etc/logrotate.d/remnanode <<'LOGROTATE'
/var/log/remnanode/*.log {
    daily
    rotate 7
    size 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LOGROTATE
        print_ok "logrotate настроен: /var/log/remnanode/*.log (daily, rotate 7, copytruncate)"
    else
        print_warn "logrotate не установился — настрой ротацию /var/log/remnanode вручную."
    fi
fi

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
    # v5.3.0 (fix #2): без SSE4.2 — ТОЛЬКО v1. x86-64-v2 baseline ТРЕБУЕТ SSE4.2/
    # POPCNT/SSE4.1 — установка v2-ядра на таком CPU = illegal instructions при
    # boot → сервер не грузится (нужна консоль провайдера). XanMod в LTS-ветке
    # выпускает x64v1 для legacy CPU — fallback-цепочка ниже его подхватит.
    CPU_LEVEL=1
    LEVEL_DESC="Нет SSE4.2 (legacy CPU) → используем v1 (v2 требует SSE4.2)"
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
# ШАГ 4: УСТАНОВКА XANMOD LTS (v4.12 — переход с MAIN на LTS)
# ==============================================================================

print_header "ШАГ 4: УСТАНОВКА ЯДРА XANMOD (LTS branch)"

# v4.12: переменные результата для финального summary
KERNEL_BRANCH="unknown"   # будет: "LTS-fresh-install" / "LTS-already-active" /
                          # "LTS-installed-MAIN-still-present" / "skipped-dry-run"
REBOOT_NEEDED="no"        # будет "yes" если установили новое ядро, "no" если LTS уже активен
MAIN_PKG_FOUND=""         # имя пакета MAIN xanmod если найден (для post-reboot cleanup)

# ==============================================================================
# v4.12: Idempotency и MAIN-detection ДО выбора пакета
# ==============================================================================

# v5.0.7: список LTS-branches Linux kernel.
# XanMod НЕ вставляет '-lts-' в uname -r или в имя пакета — LTS определяется
# по major.minor версии kernel'а (5.4, 5.10, 5.15, 6.1, 6.6, 6.12, 6.18, ...).
# Это mainline Linux LTS branches которые kernel.org поддерживает 2-6 лет.
# При выходе новой LTS ветки (примерно раз в год) — добавлять в этот массив.
# Reference: https://www.kernel.org/category/releases.html
# v5.3.0 (fix #7): 5.4 убран — EOL с декабря 2025 (kernel.org), XanMod его давно
# не собирает, ни одна нода на нём не работает. Список актуален на момент релиза:
# активные LTS-ветки kernel.org — 5.10, 5.15, 6.1, 6.6, 6.12, 6.18.
# ┌─ СОПРОВОЖДЕНИЕ: при выходе НОВОЙ LTS-ветки (≈раз в год, обычно последний
# │  major-релиз года) ОБЯЗАТЕЛЬНО добавь её сюда, иначе running-ядро этой ветки
# │  будет ошибочно принято за MAIN → ненужный repin GRUB / purge.
# └─ Проверять: https://www.kernel.org/category/releases.html
KNOWN_LTS_BRANCHES=("5.10" "5.15" "6.1" "6.6" "6.12" "6.18")

# Список всех LTS-пакетов (приоритет: больше — лучше для CPU level)
# Metapackage "linux-xanmod-lts-x64vN" автоматически тянет linux-image-lts-x64vN
# и linux-headers-lts-x64vN — отдельно их указывать не нужно.
LTS_PKG_PREFERRED="linux-xanmod-lts-x64v${CPU_LEVEL}"

# Проверяем что вообще установлено из xanmod (LTS и/или MAIN)
print_status "Проверяем установленные xanmod-пакеты..."
INSTALLED_XANMOD=$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^linux-xanmod-/{print $2}')

INSTALLED_LTS=""
INSTALLED_MAIN=""
if [ -n "$INSTALLED_XANMOD" ]; then
    INSTALLED_LTS=$(echo "$INSTALLED_XANMOD" | grep -E '^linux-xanmod-lts-' || true)
    # MAIN это всё что НЕ -lts- и НЕ -edge-/-rt-/-rt_lts-
    # Простая эвристика: метапакет MAIN имеет вид linux-xanmod-x64vN (без второго слова)
    INSTALLED_MAIN=$(echo "$INSTALLED_XANMOD" | grep -E '^linux-xanmod-x64v[0-9]+$' || true)
fi

# v5.0.7 ВАЖНО: linux-xanmod-lts-x64vN это META-PACKAGE который тянет КОНКРЕТНЫЙ
# linux-image-X.Y.Z-x64vN-xanmod1. В uname -r НЕТ суффикса '-lts-' — это deliberate
# decision XanMod, чтобы не ломать DKMS/инсталлер скрипты. Поэтому LTS-running
# определяется по версии running kernel'а, а не по имени.
#
# Также: на чистой ноде где скрипт установил linux-xanmod-x64vN (MAIN), пакет
# может оказаться LTS-веткой (если XanMod синхронизировал MAIN с LTS branch).
# Например в апреле 2026 MAIN=6.18.29 и LTS=6.18.29 одновременно — оба правильные.
# Это значит: даже если установлен MAIN-метапакет, реальное ядро может быть LTS.
RUNNING_KERNEL=$(uname -r)
# Извлекаем major.minor из running kernel (например '6.18' из '6.18.29-x64v3-xanmod1')
RUNNING_MAJOR_MINOR=$(echo "$RUNNING_KERNEL" | grep -oE '^[0-9]+\.[0-9]+' | head -1)

LTS_IS_RUNNING=0
if [[ "$RUNNING_KERNEL" =~ -xanmod ]] || [[ "$RUNNING_KERNEL" =~ xanmod ]]; then
    # Это XanMod ядро. Проверяем версию против списка LTS branches.
    for lts_branch in "${KNOWN_LTS_BRANCHES[@]}"; do
        if [ "$RUNNING_MAJOR_MINOR" = "$lts_branch" ]; then
            LTS_IS_RUNNING=1
            break
        fi
    done
fi

# v5.0.7: MAIN_IS_RUNNING — XanMod kernel с НЕ-LTS версией (например 7.x.x, 6.19.x)
# Это сценарий когда юзер хочет LTS, но загружен bleeding-edge MAIN.
MAIN_IS_RUNNING=0
if [[ "$RUNNING_KERNEL" =~ -xanmod ]] && [ "$LTS_IS_RUNNING" -eq 0 ]; then
    MAIN_IS_RUNNING=1
fi

# Print debug для clarity
if [ -n "$RUNNING_MAJOR_MINOR" ]; then
    if [ "$LTS_IS_RUNNING" -eq 1 ]; then
        print_info "Running kernel: $RUNNING_KERNEL (v${RUNNING_MAJOR_MINOR} = LTS branch)"
    elif [ "$MAIN_IS_RUNNING" -eq 1 ]; then
        print_info "Running kernel: $RUNNING_KERNEL (v${RUNNING_MAJOR_MINOR} = MAIN branch, NOT LTS)"
    fi
fi

if [ -n "$INSTALLED_LTS" ] && [ "$LTS_IS_RUNNING" -eq 1 ]; then
    print_ok "LTS xanmod уже установлен и активен: $RUNNING_KERNEL"
    print_info "Установленные LTS-пакеты:"
    echo "$INSTALLED_LTS" | sed 's/^/    /'
    print_info "Шаг установки ядра пропускается (idempotency)."
    KERNEL_BRANCH="LTS-already-active"
    REBOOT_NEEDED="no"
    KERNEL_PKG="$(echo "$INSTALLED_LTS" | head -1)"

    # Всё равно убедимся, что репо xanmod добавлено корректно (для будущих
    # security-updates), но без apt-get install ядра.
    if [ ! -f /etc/apt/sources.list.d/xanmod-release.list ]; then
        print_warn "Репозиторий xanmod не настроен — security updates LTS не придут"
        print_info "Скрипт продолжит работу и доконфигурирует репозиторий."
    else
        print_ok "Репозиторий xanmod уже настроен"
        echo ""
    fi
elif [ "$LTS_IS_RUNNING" -eq 1 ] && [ -n "$INSTALLED_MAIN" ] && [ -z "$INSTALLED_LTS" ]; then
    # v5.0.7 NEW CASE: ядро LTS-версии (например 6.18.29) активно, но установлено
    # через MAIN-метапакет (linux-xanmod-x64v3), а не через linux-xanmod-lts-x64v3.
    # Это происходит когда:
    #   - XanMod синхронизировал MAIN/LTS на одну версию (~50% времени).
    #   - Юзер апгрейдил MAIN метапакет, и в этот момент MAIN==LTS branch.
    # Технически: ядро правильное (LTS 6.18.x с BBRv3), но за обновлениями LTS
    # apt не пойдёт — он подписан на MAIN-метапакет и при следующем обновлении
    # может переключиться на 6.19.x/7.x.x (когда MAIN отойдёт от LTS).
    print_ok "Ядро LTS-версии активно: $RUNNING_KERNEL"
    print_info "Метапакет: $(echo "$INSTALLED_MAIN" | head -1) (MAIN)"
    print_warn "ВНИМАНИЕ: установлен MAIN-метапакет, но текущее ядро в LTS-ветке"
    print_warn "При следующем apt update MAIN может перейти на bleeding-edge (6.19+/7.x)"
    print_info "Рекомендация (не критично): сменить метапакет на LTS:"
    print_info "  apt-get install -y $LTS_PKG_PREFERRED"
    print_info "  apt-get purge -y $(echo "$INSTALLED_MAIN" | head -1)"
    print_info "  reboot"
    print_info ""
    print_info "Сейчас скрипт продолжит без переустановки ядра — оно уже правильное."
    KERNEL_BRANCH="LTS-active-via-MAIN-metapackage"
    REBOOT_NEEDED="no"
    KERNEL_PKG="$(echo "$INSTALLED_MAIN" | head -1)"

    if [ ! -f /etc/apt/sources.list.d/xanmod-release.list ]; then
        print_warn "Репозиторий xanmod не настроен"
        print_info "Скрипт продолжит работу и доконфигурирует репозиторий."
    else
        print_ok "Репозиторий xanmod уже настроен"
        echo ""
    fi
elif [ -n "$INSTALLED_LTS" ] && [ "$MAIN_IS_RUNNING" -eq 1 ]; then
    # v5.0.6 NEW CASE: LTS установлен, но активен MAIN xanmod.
    # Это типичный сценарий после предыдущего запуска скрипта который скачал и
    # установил LTS, но update-grub оставил MAIN как default (потому что
    # MAIN version > LTS version при `sort -V`).
    # Раньше скрипт скипал шаг 4 потому что INSTALLED_LTS != empty и не проверял
    # что именно АКТИВНО. Результат: после второго запуска ничего не менялось,
    # юзер искренне не понимал почему "ядро не сменилось".
    print_warn "LTS xanmod установлен, но активен MAIN: $RUNNING_KERNEL"
    print_info "Установленные LTS-пакеты:"
    echo "$INSTALLED_LTS" | sed 's/^/    /'
    print_info ""
    print_info "Причина: при предыдущем запуске update-grub поставил MAIN как default"
    print_info "(GRUB сортирует ядра по версии, MAIN 7.x > LTS 6.x при sort -V)."
    print_info ""
    print_info "Скрипт сейчас обновит GRUB чтобы default стал LTS, потребуется reboot."

    # Не выходим — продолжаем выполнение, дойдём до блока update-grub в конце
    # ШАГ 4 (он явно установит GRUB_DEFAULT на LTS). Просто помечаем состояние.
    KERNEL_BRANCH="LTS-installed-MAIN-running-repin-grub"
    REBOOT_NEEDED="yes"
    KERNEL_PKG="$(echo "$INSTALLED_LTS" | head -1)"
    # Не делаем apt-get install — пакет уже установлен. Только update-grub нужен.
    # Для этого ставим спец-флаг, чтобы пропустить install но не пропустить GRUB.
    SKIP_KERNEL_INSTALL=1
fi

# Информируем о MAIN если он есть
if [ -n "$INSTALLED_MAIN" ]; then
    MAIN_PKG_FOUND=$(echo "$INSTALLED_MAIN" | head -1)
    print_warn "Обнаружен MAIN xanmod: $MAIN_PKG_FOUND"
    print_info "После успешной загрузки на LTS ядро надо будет ВРУЧНУЮ убрать MAIN:"
    print_info "  apt-get purge $MAIN_PKG_FOUND linux-image-*-x64v*-xanmod1"
    print_info "  (только те linux-image, что НЕ -lts-)"
    print_info "Автоматически НЕ удаляем — слишком велик риск остаться без ядра."
fi
echo ""

# v5.0.4 (fix #36): порядок GPG операций изменён.
# Раньше: rm old keys → wget download → install new. Если wget падает
# (CF 403, network blip, dl.xanmod.org down), система остаётся БЕЗ keyring,
# но xanmod-release.list уже добавлен → apt-get update warnings + rerun
# может не помочь без manual cleanup.
# Теперь: wget tmp file → verify → THEN rm old + install new.
# + fallback на keyserver.ubuntu.com если dl.xanmod.org недоступен.

# Обновляем систему (apt-get update без xanmod-репо — стандартные источники)
# v5.3.0 (fix #4): самолечение. Если прошлый запуск умер после добавления
# xanmod-release.list, но до успешного update — раньше первый update падал
# фатально, а stale repo не чистился (cleanup был только во втором update ниже).
XANMOD_LIST="/etc/apt/sources.list.d/xanmod-release.list"
XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
purge_xanmod_repo() { rm -f "$XANMOD_LIST" /usr/share/keyrings/xanmod-archive-keyring.gpg "$XANMOD_KEYRING" 2>/dev/null; }
# list без keyring = недозаписанное состояние → чистим заранее (репо добавится ниже).
if [ -f "$XANMOD_LIST" ] && [ ! -s "$XANMOD_KEYRING" ]; then
    print_warn "Найден xanmod-release.list без keyring (недозаписанное состояние) — чищу."
    purge_xanmod_repo
fi

print_status "Обновляем списки пакетов..."
echo ""
if ! apt-get update; then
    # Возможно мешает stale/битый xanmod repo — сносим и повторяем один раз.
    if [ -f "$XANMOD_LIST" ]; then
        print_warn "apt-get update упал — сношу возможно-битый xanmod repo и повторяю..."
        purge_xanmod_repo
    fi
    if ! apt-get update; then
        print_error "FATAL: apt-get update завершился с ошибкой!"
        print_info "Проверьте интернет-соединение и состояние репозиториев (/etc/apt/sources.list)"
        exit 1
    fi
fi
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

# v5.0.4 (fix #36+#37): скачиваем GPG в tmp ПЕРВЫМ, потом удаляем старые ключи.
# wget с timeout=15 и tries=2 (раньше мог висеть 15 минут на CF 403).
print_status "Скачиваю GPG ключ XanMod (15s timeout, 2 retries)..."
XANMOD_KEY_TMP=$(mktemp)
XANMOD_KEY_OK=0
if wget --timeout=15 --tries=2 -qO "$XANMOD_KEY_TMP" https://dl.xanmod.org/archive.key && \
   [ -s "$XANMOD_KEY_TMP" ]; then
    XANMOD_KEY_OK=1
    print_ok "GPG ключ скачан с dl.xanmod.org"
else
    print_warn "dl.xanmod.org недоступен (CF 403 / timeout?) — пробую keyserver fallback..."
    # Fallback: gpg --recv-keys из публичного keyserver.
    # v5.3.0 (fix #17): ID ключа вынесен в константу XANMOD_GPG_KEY_ID (вверху файла).
    if command -v gpg >/dev/null 2>&1 && \
       gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$XANMOD_GPG_KEY_ID" 2>/dev/null && \
       gpg --export "$XANMOD_GPG_KEY_ID" > "$XANMOD_KEY_TMP" 2>/dev/null && \
       [ -s "$XANMOD_KEY_TMP" ]; then
        XANMOD_KEY_OK=1
        print_ok "GPG ключ получен с keyserver.ubuntu.com"
    fi
fi

if [ "$XANMOD_KEY_OK" != "1" ]; then
    print_error "Не удалось получить GPG ключ XanMod ни с dl.xanmod.org, ни с keyserver."
    print_error "Старые ключи (если были) НЕ тронуты — система остаётся в working state."
    rm -f "$XANMOD_KEY_TMP"
    exit 1
fi

# Теперь когда новый ключ скачан и валиден — безопасно удаляем старые
# и устанавливаем новый.
print_status "Очищаем старые ключи XanMod (после успешного скачивания нового)..."
rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg 2>/dev/null
rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg 2>/dev/null

# dearmor: если на входе ASCII-armored ключ (с dl.xanmod.org) — конвертирует
# в binary. Если уже binary (gpg --export) — gpg --dearmor берёт как есть.
# При ошибке dearmor — fallback на прямое копирование (binary input).
if gpg --dearmor < "$XANMOD_KEY_TMP" > /etc/apt/keyrings/xanmod-archive-keyring.gpg 2>/dev/null && \
   [ -s /etc/apt/keyrings/xanmod-archive-keyring.gpg ]; then
    :
else
    cp "$XANMOD_KEY_TMP" /etc/apt/keyrings/xanmod-archive-keyring.gpg
fi
rm -f "$XANMOD_KEY_TMP"
chmod 0644 /etc/apt/keyrings/xanmod-archive-keyring.gpg
echo ""
print_ok "GPG ключ установлен"

DISTRO_CODENAME=$(lsb_release -sc)
echo -e "    Codename дистрибутива: ${GREEN}$DISTRO_CODENAME${NC}"

# v5.3.2 (fix): XanMod публикует ядра НЕ для всех codename. Проверено: jammy
# (Ubuntu 22.04) и focal (20.04) отдают 404 на deb.xanmod.org/dists/<cn>/, а
# noble/bookworm/trixie/plucky — 200. Раньше на 22.04 репо добавлялся, apt update
# падал 404, fix#4 сносил репо → FATAL "нет ядра" с расплывчатой причиной.
# Теперь проверяем suite ДО добавления и, если его точно нет (404 на InRelease И
# Release), выходим рано с понятным сообщением. Fail-open: при сетевой ошибке
# (код 000/таймаут) не блокируем — пусть штатная логика apt разбирается.
if [ "${DRY_RUN:-0}" -ne 1 ] && command -v curl >/dev/null 2>&1; then
    _xm_http_code() { curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$1" 2>/dev/null; }
    XM_CODE=$(_xm_http_code "http://deb.xanmod.org/dists/${DISTRO_CODENAME}/InRelease")
    [ "$XM_CODE" = "200" ] || XM_CODE=$(_xm_http_code "http://deb.xanmod.org/dists/${DISTRO_CODENAME}/Release")
    if [ "$XM_CODE" = "404" ]; then
        print_error "XanMod не публикует ядра для codename '${DISTRO_CODENAME}'."
        print_info "Подтверждено снято с поддержки: jammy (Ubuntu 22.04), focal (20.04)."
        print_info "Поддерживаются: bookworm (Debian 12), trixie (Debian 13), noble (24.04), plucky (25.04) и новее."
        print_info "Что делать: обнови ОС до поддерживаемой ЛИБО оставь штатное ядро дистрибутива —"
        print_info "BBR есть и в нём (modprobe tcp_bbr + tcp_congestion_control=bbr), остальной тюнинг скрипта применится."
        print_info "Прервать установку ядра можно повторно с SKIP-флагом, но безопаснее обновить ОС."
        exit 1
    fi
fi

echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${DISTRO_CODENAME} main" | tee /etc/apt/sources.list.d/xanmod-release.list
print_ok "Репозиторий добавлен в sources.list"

print_status "Обновляем списки пакетов (с XanMod)..."
echo ""
if ! apt-get update; then
    print_error "FATAL: apt-get update с репозиторием XanMod провалился!"
    print_info "Возможные причины:"
    print_info "  - Репозиторий XanMod недоступен (deb.xanmod.org)"
    print_info "  - GPG ключ не подходит к репозиторию"
    print_info "  - Codename '$DISTRO_CODENAME' не поддерживается XanMod"
    # v5.0.4 (fix #28): cleanup broken state перед exit'ом.
    # Иначе следующий запуск скрипта тоже упадёт на apt-get update ВЫШЕ
    # (стандартный update в начале ШАГ 4) потому что xanmod-release.list
    # ссылается на broken repo с broken keyring.
    print_warn "Удаляю xanmod-release.list и keyring чтобы rerun был чистым..."
    rm -f /etc/apt/sources.list.d/xanmod-release.list
    rm -f /etc/apt/keyrings/xanmod-archive-keyring.gpg
    print_info "Запусти скрипт ещё раз когда исправишь причину (сеть/codename)."
    exit 1
fi
echo ""
print_ok "Списки обновлены"

# v4.12: если LTS уже активен — на этом этапе мы только обновили репо/ключи,
# никакого apt-get install ядра не делаем.
if [ "$KERNEL_BRANCH" = "LTS-already-active" ]; then
    print_ok "Шаг 4 завершён без переустановки ядра (LTS уже активен)."
    echo ""
elif [ "$KERNEL_BRANCH" = "LTS-active-via-MAIN-metapackage" ]; then
    # v5.0.7: LTS kernel активен, но через MAIN-метапакет.
    # Ядро правильное (LTS-ветка), но apt подписан на MAIN.
    # Не переустанавливаем — kernel работает, оптимизации применены.
    # Юзер при желании может вручную сменить метапакет (инструкция выше).
    print_ok "Шаг 4 завершён — kernel LTS-ветки активен (метапакет MAIN, но это OK)."
    echo ""
elif [ "${SKIP_KERNEL_INSTALL:-0}" = "1" ]; then
    # v5.0.6: LTS установлен но MAIN активен — пропускаем apt install,
    # но идём дальше к GRUB-блоку чтобы pin'нуть LTS как default.
    print_status "LTS пакет уже установлен, пропускаю apt install."
    print_status "Перехожу к update-grub для смены default kernel..."
    INSTALL_RESULT=0
    # NEW_KERNEL_VERSION должен быть определён для GRUB блока — вычисляем сейчас.
    # v5.1.1 FIX: XanMod НЕ вставляет '-lts-' в имя файла vmlinuz, поэтому
    # старый glob 'vmlinuz-*lts*xanmod*' всегда давал пустую строку.
    # Перебираем KNOWN_LTS_BRANCHES и выбираем самое свежее LTS-ядро из /boot.
    NEW_KERNEL_VERSION=""
    for lts_branch in "${KNOWN_LTS_BRANCHES[@]}"; do
        # shellcheck disable=SC2012,SC2086  # glob по версии ядра намеренный; имена в /boot без пробелов
        candidate=$(ls /boot/vmlinuz-${lts_branch}.*-x64v*-xanmod* 2>/dev/null | xargs -I{} basename {} 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -1)
        if [ -n "$candidate" ]; then
            if [ -z "$NEW_KERNEL_VERSION" ] || [ "$(printf '%s\n' "$NEW_KERNEL_VERSION" "$candidate" | sort -V | tail -1)" = "$candidate" ]; then
                NEW_KERNEL_VERSION="$candidate"
            fi
        fi
    done
    if [ -z "$NEW_KERNEL_VERSION" ]; then
        print_error "Не удалось определить версию установленного LTS — repin GRUB невозможен"
        print_info "Искали в /boot/vmlinuz-* по веткам: ${KNOWN_LTS_BRANCHES[*]}"
        print_info "Содержимое /boot/vmlinuz-*xanmod*:"
        ls -1 /boot/vmlinuz-*xanmod* 2>/dev/null | sed 's/^/    /' || print_info "    (ничего не найдено)"
        exit 1
    fi
    print_info "Найден LTS kernel: $NEW_KERNEL_VERSION (будет установлен как GRUB default)"
    echo ""
else

# v4.12: выбираем пакет с fallback цепочкой v3 → v2 → v1 ТОЛЬКО для LTS.
# В LTS-ветке доступен v1 (legacy CPU без SSE4.2) — в MAIN такого нет.
KERNEL_PKG="$LTS_PKG_PREFERRED"
print_status "Проверяем доступность пакета: ${BOLD}${KERNEL_PKG}${NC} (LTS branch)"

resolve_kernel_pkg() {
    local pkg="$1"
    apt-cache show "$pkg" >/dev/null 2>&1
}

if ! resolve_kernel_pkg "$KERNEL_PKG"; then
    print_warn "Пакет $KERNEL_PKG не найден, пробуем fallback в LTS-ветке..."

    FALLBACK_FOUND=0
    # Идём вниз по уровням: 3 → 2 → 1
    for try_level in 3 2 1; do
        # Не пробуем уровни выше выбранного
        [ "$try_level" -gt "$CPU_LEVEL" ] && continue
        TRY_PKG="linux-xanmod-lts-x64v${try_level}"
        if resolve_kernel_pkg "$TRY_PKG"; then
            KERNEL_PKG="$TRY_PKG"
            print_info "LTS fallback найден: $KERNEL_PKG"
            FALLBACK_FOUND=1
            break
        fi
    done

    if [ "$FALLBACK_FOUND" -eq 0 ]; then
        print_error "Ни один LTS-пакет не найден в репозитории!"
        echo ""
        print_info "Доступные пакеты XanMod:"
        apt-cache search linux-xanmod | head -20
        print_info "Возможная причина: deb.xanmod.org временно недоступен"
        print_info "или codename '$DISTRO_CODENAME' пока не поддерживает LTS-ветку."
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

# v4.12: dry-run — показываем что было бы сделано, но НЕ ставим
if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════════${NC}"
    print_info "[DRY-RUN] Здесь был бы вызван:"
    print_info "  DEBIAN_FRONTEND=noninteractive apt-get install -y $KERNEL_PKG"
    if [ -n "$MAIN_PKG_FOUND" ]; then
        print_info "[DRY-RUN] MAIN xanmod ($MAIN_PKG_FOUND) был бы оставлен для безопасности."
        print_info "         После ребута на LTS его нужно убрать вручную:"
        print_info "         apt-get purge $MAIN_PKG_FOUND"
    fi
    print_info "[DRY-RUN] update-grub также был бы вызван."
    print_info "[DRY-RUN] sysctl/limits/qdisc применятся в обычном режиме."
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════════${NC}"
    KERNEL_BRANCH="skipped-dry-run"
    REBOOT_NEEDED="no"
    INSTALL_RESULT=0
else
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$KERNEL_PKG"
    INSTALL_RESULT=$?
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""

    # v4.12: фиксируем ветку для summary
    if [ -n "$MAIN_PKG_FOUND" ]; then
        KERNEL_BRANCH="LTS-installed-MAIN-still-present"
    else
        KERNEL_BRANCH="LTS-fresh-install"
    fi
    REBOOT_NEEDED="yes"
fi

# v5.2.0: РЕАЛЬНАЯ ЗАМЕНА чужой версии XanMod (раньше она оставалась рядом с LTS).
# Симптом "ставит LTS, но другая версия не заменяется": MAIN/edge/rt или чужой
# CPU-level xanmod-метапакет оставался установленным → apt при upgrade снова тянул
# его ветку, GRUB мог вернуться на него.
# Делаем БЕЗОПАСНО, после успешной установки LTS:
#   1) purge чужих xanmod-МЕТАПАКЕТОВ (apt перестаёт отслеживать их ветку).
#      Метапакет не тянет за собой linux-image при purge → running kernel остаётся.
#   2) purge чужих linux-image/headers, которые НЕ запущены и НЕ в LTS-ветке.
#   Запущенное ядро НЕ трогаем — остаётся как GRUB-fallback до ребута.
# v5.2.0: под --dry-run детект работает и печатает ПЛАН purge, но НИЧЕГО не удаляет.
# Отключить полностью: SETUP_NO_KERNEL_REPLACE=1
if [ "${INSTALL_RESULT:-1}" -eq 0 ] && \
   [ -n "${KERNEL_PKG:-}" ] && [ "${SETUP_NO_KERNEL_REPLACE:-0}" != "1" ]; then
    RUNNING_K="$(uname -r)"
    _is_lts_branch() {
        local mm bb
        mm=$(echo "$1" | grep -oE '^[0-9]+\.[0-9]+' | head -1)
        for bb in "${KNOWN_LTS_BRANCHES[@]}"; do [ "$mm" = "$bb" ] && return 0; done
        return 1
    }

    # 1) Чужие xanmod-метапакеты = все linux-xanmod-* кроме выбранного LTS-пакета
    FOREIGN_META=$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^linux-xanmod-/{print $2}' | grep -vxF "$KERNEL_PKG" || true)

    # 2) Чужие образы/headers: установлены, НЕ запущены, НЕ LTS-ветка
    PURGE_IMG=""
    while read -r pkg; do
        [ -z "$pkg" ] && continue
        ver=$(echo "$pkg" | sed -E 's/^linux-(image|headers)-//')
        [ "$ver" = "$RUNNING_K" ] && continue       # running — fallback, не трогаем
        _is_lts_branch "$ver" && continue            # LTS-ветка — оставляем
        PURGE_IMG="$PURGE_IMG $pkg"
    done < <(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^linux-(image|headers)-[0-9].*xanmod/{print $2}')

    if [ "$DRY_RUN" -eq 1 ]; then
        # ПРЕВЬЮ — ничего не удаляем
        if [ -n "$FOREIGN_META" ]; then
            print_info "[DRY-RUN] purge чужих xanmod-метапакетов:"
            echo "$FOREIGN_META" | sed 's/^/      /'
        fi
        if [ -n "$PURGE_IMG" ]; then
            print_info "[DRY-RUN] purge старых не-LTS xanmod-образов (не запущены):"
            echo "$PURGE_IMG" | tr ' ' '\n' | sed '/^$/d; s/^/      /'
        fi
        if [ -z "$FOREIGN_META" ] && [ -z "$PURGE_IMG" ]; then
            print_info "[DRY-RUN] чужих xanmod-пакетов не найдено — заменять нечего."
        fi
    else
        if [ -n "$FOREIGN_META" ]; then
            print_status "Удаляю чужие xanmod-метапакеты (apt больше не будет их обновлять):"
            echo "$FOREIGN_META" | sed 's/^/    /'
            # shellcheck disable=SC2086
            if DEBIAN_FRONTEND=noninteractive apt-get purge -y $FOREIGN_META >/dev/null 2>&1; then
                print_ok "Чужие метапакеты удалены"
            else
                print_warn "Не все метапакеты удалились — проверь: apt-get purge $FOREIGN_META"
            fi
        fi
        if [ -n "$PURGE_IMG" ]; then
            print_status "Удаляю старые не-LTS xanmod-ядра (не запущены):"
            echo "$PURGE_IMG" | tr ' ' '\n' | sed '/^$/d; s/^/    /'
            # shellcheck disable=SC2086
            if DEBIAN_FRONTEND=noninteractive apt-get purge -y $PURGE_IMG >/dev/null 2>&1; then
                print_ok "Старые не-LTS ядра удалены"
            else
                print_warn "Часть ядер не удалилась — apt-get purge вручную"
            fi
        fi
    fi

    # Если СЕЙЧАС запущено чужое (не-LTS) ядро — его образ оставлен как fallback.
    if [[ "$RUNNING_K" =~ xanmod ]] && ! _is_lts_branch "$RUNNING_K"; then
        print_warn "Сейчас запущено не-LTS ядро ($RUNNING_K) — оставлено как fallback до ребута."
        print_info "После ребута на LTS повторный запуск setup.sh удалит его автоматически."
    fi
fi

if [ $INSTALL_RESULT -eq 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        print_ok "[DRY-RUN] Шаг 4 пропущен — ядро НЕ устанавливалось."
    elif [ "${SKIP_KERNEL_INSTALL:-0}" = "1" ]; then
        print_ok "LTS pre-installed, переход к GRUB repin..."
    else
        print_ok "Ядро XanMod LTS успешно установлено!"
    fi

    # v4.12: post-install валидация делается только если реально установили ядро
    if [ "$DRY_RUN" -eq 0 ]; then

    # ==========================================================================
    # POST-INSTALL VALIDATION — проверки ДО update-grub
    # Если новое ядро битое — лучше узнать сейчас чем после ребута
    # ==========================================================================

    # Определяем версию свежеустановленного ядра.
    # v5.1.1 FIX: '*lts*xanmod*' glob не работает — XanMod не вставляет 'lts' в имя файла.
    # Перебираем KNOWN_LTS_BRANCHES чтобы выбрать самое свежее LTS-ядро
    # (а не MAIN, который мог бы оказаться выше по версии).
    NEW_KERNEL_VERSION=""
    for lts_branch in "${KNOWN_LTS_BRANCHES[@]}"; do
        # shellcheck disable=SC2012,SC2086  # glob по версии ядра намеренный; имена в /boot без пробелов
        candidate=$(ls /boot/vmlinuz-${lts_branch}.*-x64v*-xanmod* 2>/dev/null | xargs -I{} basename {} 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -1)
        if [ -n "$candidate" ]; then
            if [ -z "$NEW_KERNEL_VERSION" ] || [ "$(printf '%s\n' "$NEW_KERNEL_VERSION" "$candidate" | sort -V | tail -1)" = "$candidate" ]; then
                NEW_KERNEL_VERSION="$candidate"
            fi
        fi
    done

    if [ -n "$NEW_KERNEL_VERSION" ] && [ "$NEW_KERNEL_VERSION" != "$CURRENT_KERNEL" ]; then
        print_status "Валидация нового ядра: $NEW_KERNEL_VERSION"

        # --- Защита 1: initramfs существует и не битый ---
        # Если установка ядра прерывалась, initrd может быть пустой / маленький
        # Здоровый initrd обычно >40MB, но мы проверяем хотя бы >10MB
        NEW_INITRD="/boot/initrd.img-${NEW_KERNEL_VERSION}"
        if [ -f "$NEW_INITRD" ]; then
            INITRD_SIZE=$(stat -c%s "$NEW_INITRD" 2>/dev/null)
            INITRD_SIZE_MB=$((INITRD_SIZE / 1048576))
            if [ "$INITRD_SIZE_MB" -lt 10 ]; then
                print_warn "initramfs подозрительно маленький: ${INITRD_SIZE_MB}MB (ожидалось >40MB)"
                print_status "Пересобираем initramfs..."
                if update-initramfs -u -k "$NEW_KERNEL_VERSION" 2>&1 | tail -5; then
                    INITRD_SIZE=$(stat -c%s "$NEW_INITRD" 2>/dev/null)
                    INITRD_SIZE_MB=$((INITRD_SIZE / 1048576))
                    if [ "$INITRD_SIZE_MB" -lt 10 ]; then
                        print_error "initramfs всё ещё битый — НЕ РЕБУТАЙТЕ"
                        print_info "Это критическая ошибка установки ядра"
                        exit 1
                    fi
                    print_ok "initramfs пересобран: ${INITRD_SIZE_MB}MB"
                fi
            else
                print_ok "initramfs корректный: ${INITRD_SIZE_MB}MB"
            fi
        else
            print_error "initramfs не найден: $NEW_INITRD"
            print_error "Это критическая ошибка установки ядра — НЕ РЕБУТАЙТЕ"
            exit 1
        fi

        # --- Защита 2: /lib/modules целостность ---
        # Если modules.dep битый или отсутствует — depmod не отработал
        MODULES_DIR="/lib/modules/$NEW_KERNEL_VERSION"
        if [ -d "$MODULES_DIR" ]; then
            if [ ! -s "$MODULES_DIR/modules.dep" ]; then
                print_warn "modules.dep отсутствует или пустой — запускаем depmod..."
                if depmod -a "$NEW_KERNEL_VERSION" 2>&1; then
                    print_ok "modules.dep пересоздан"
                else
                    print_error "depmod не сработал — модули могут не загрузиться"
                fi
            else
                print_ok "Модули ядра целостны"
            fi
        else
            print_error "Директория модулей $MODULES_DIR не существует"
            print_error "Установка ядра прошла неполно — НЕ РЕБУТАЙТЕ"
            exit 1
        fi

        # --- Защита 3: Драйвер сетевой карты есть в новом ядре ---
        # Самая критичная проверка: если в новом ядре нет драйвера NIC,
        # после ребута сеть будет мертва и потребуется hard reset через console
        if [ -n "$DEFAULT_IFACE" ] && command -v ethtool >/dev/null 2>&1; then
            NIC_DRIVER=$(ethtool -i "$DEFAULT_IFACE" 2>/dev/null | awk '/^driver:/{print $2; exit}')
            if [ -n "$NIC_DRIVER" ]; then
                print_status "Проверяем драйвер NIC ($NIC_DRIVER) в новом ядре..."
                # Ищем .ko или .ko.* (.ko.zst, .ko.xz) в директории модулей
                DRIVER_FOUND=$(find "$MODULES_DIR" -name "${NIC_DRIVER}.ko*" 2>/dev/null | head -1)

                if [ -n "$DRIVER_FOUND" ]; then
                    print_ok "Драйвер $NIC_DRIVER найден в новом ядре"
                else
                    # Может быть встроен в само ядро (builtin)
                    BUILTIN=$(grep -q "^${NIC_DRIVER}$\|/${NIC_DRIVER}\.ko$" "$MODULES_DIR/modules.builtin" 2>/dev/null && echo "yes")
                    if [ "$BUILTIN" = "yes" ]; then
                        print_ok "Драйвер $NIC_DRIVER встроен в ядро"
                    else
                        print_error "ВНИМАНИЕ: Драйвер $NIC_DRIVER НЕ НАЙДЕН в новом ядре!"
                        print_error "После ребута сеть НЕ ПОДНИМЕТСЯ — потребуется hard reset"
                        echo ""
                        print_info "Варианты действий:"
                        print_info "  1. Отменить ребут, оставить старое ядро как default:"
                        print_info "     sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=\"1>0\"/' /etc/default/grub"
                        print_info "     update-grub"
                        print_info "  2. Удалить новое ядро: apt-get remove $KERNEL_PKG"
                        echo ""
                        read -p "Продолжить установку? (НЕ рекомендуется) (y/N): " -n 1 -r < /dev/tty
                        echo ""
                        [[ ! $REPLY =~ ^[Yy]$ ]] && {
                            print_info "Установка прервана. Старое ядро не тронуто."
                            exit 1
                        }
                    fi
                fi
            fi
        fi
    fi
    fi  # v4.12: end of "if DRY_RUN == 0" — post-install validation block

    # Гарантируем что текущее (рабочее) ядро останется в GRUB как запасное
    # v4.12: при dry-run только сообщаем, не вызываем update-grub
    print_status "Проверяем загрузчик и настраиваем fallback..."
    # Проверяем что используется GRUB, а не systemd-boot (Ubuntu 24.04+)
    if [ -f /etc/default/grub ] && (dpkg -l grub-pc &>/dev/null || dpkg -l grub-efi-amd64 &>/dev/null); then
        if [ "$DRY_RUN" -eq 1 ]; then
            print_info "[DRY-RUN] update-grub был бы вызван (пропускаем)"
        else
            if ! grep -q "GRUB_DISABLE_SUBMENU" /etc/default/grub; then
                echo 'GRUB_DISABLE_SUBMENU=y' >> /etc/default/grub
                print_ok "GRUB submenu отключён (старое ядро доступно в меню)"
            fi

            # v5.0.6 FIX: если установлен MAIN xanmod (или stock kernel) с БОЛЬШЕЙ
            # версией чем наш LTS (например MAIN 7.0.2 vs LTS 6.18.x), update-grub
            # сортирует ядра по версии через `sort -V` и ставит MAIN первым.
            # GRUB_DEFAULT=0 → после reboot грузится MAIN, наш LTS игнорируется.
            # Решение: явно выставить GRUB_DEFAULT на LTS submenu entry.
            if [ -n "$NEW_KERNEL_VERSION" ]; then
                # v5.3.3 (fix #A2): title-pin на точную версию стейлится — apt ставит
                # 6.18.36, GRUB вечно грузит запиннутый 6.18.35 до повторного прогона.
                # Пин нужен ТОЛЬКО пока в /boot живёт не-LTS xanmod (MAIN 7.x сортируется
                # выше LTS при sort -V). Если не-LTS ядер нет — GRUB_DEFAULT=0: первый
                # entry = самый свежий LTS, point-release'ы подхватываются автоматически.
                NONLTS_PRESENT=0
                for vk in /boot/vmlinuz-*xanmod*; do
                    [ -e "$vk" ] || continue
                    vmm=$(basename "$vk" | sed 's/^vmlinuz-//' | grep -oE '^[0-9]+\.[0-9]+' | head -1)
                    vk_is_lts=0
                    for bb in "${KNOWN_LTS_BRANCHES[@]}"; do
                        [ "$vmm" = "$bb" ] && vk_is_lts=1 && break
                    done
                    if [ "$vk_is_lts" -eq 0 ]; then
                        NONLTS_PRESENT=1
                        break
                    fi
                done
                # Бэкап (один раз — если ещё нет)
                if [ ! -f /etc/default/grub.vpn-node-builder-backup ]; then
                    cp /etc/default/grub /etc/default/grub.vpn-node-builder-backup 2>/dev/null
                fi
                sed -i '/^GRUB_DEFAULT=/d' /etc/default/grub
                sed -i '/^GRUB_SAVEDEFAULT=/d' /etc/default/grub
                sed -i '/^# v5.0.6: pin GRUB default/d' /etc/default/grub
                sed -i '/^# (без этого update-grub ставит MAIN/d' /etc/default/grub
                sed -i '/^# v5.3.3: временный pin на LTS/d' /etc/default/grub
                sed -i '/^# После ребута на LTS повторный прогон/d' /etc/default/grub
                sed -i '/^# v5.3.3: только LTS-ядра/d' /etc/default/grub
                if [ "$NONLTS_PRESENT" -eq 1 ]; then
                    print_status "В /boot есть не-LTS xanmod — пиню GRUB_DEFAULT на LTS ($NEW_KERNEL_VERSION)..."
                    LTS_MENU_TITLE="Ubuntu, with Linux ${NEW_KERNEL_VERSION}"
                    # На Debian title будет "Debian GNU/Linux, with Linux ..."
                    if grep -qi '^ID=debian' /etc/os-release 2>/dev/null; then
                        LTS_MENU_TITLE="Debian GNU/Linux, with Linux ${NEW_KERNEL_VERSION}"
                    fi
                    {
                        echo ""
                        echo "# v5.3.3: временный pin на LTS, пока в /boot есть не-LTS xanmod."
                        echo "# После ребута на LTS повторный прогон снимет pin (GRUB_DEFAULT=0)."
                        echo "GRUB_DEFAULT=\"${LTS_MENU_TITLE}\""
                    } >> /etc/default/grub
                    print_ok "GRUB_DEFAULT=\"${LTS_MENU_TITLE}\" (временный pin до зачистки MAIN)"
                else
                    {
                        echo ""
                        echo "# v5.3.3: только LTS-ядра в /boot — свежий LTS всегда первый entry."
                        echo "GRUB_DEFAULT=0"
                    } >> /etc/default/grub
                    print_ok "GRUB_DEFAULT=0 — point-release'ы LTS подхватываются автоматически"
                fi
            fi

            if update-grub 2>&1 | tail -10; then
                print_ok "GRUB обновлён"

                # v5.0.6: после update-grub проверяем что наш entry реально существует.
                # Если title не совпал (старый grub, кастомный default-config) —
                # fallback на числовой индекс через grep.
                if [ -n "$NEW_KERNEL_VERSION" ] && [ -f /boot/grub/grub.cfg ]; then
                    if ! grep -q "with Linux ${NEW_KERNEL_VERSION}" /boot/grub/grub.cfg 2>/dev/null; then
                        print_warn "Menu entry для $NEW_KERNEL_VERSION не найден в grub.cfg"
                        print_info "GRUB может загрузить не тот kernel при reboot"
                        print_info "Проверь: grep menuentry /boot/grub/grub.cfg"
                    else
                        print_ok "LTS entry подтверждён в /boot/grub/grub.cfg"
                    fi
                fi
            else
                print_info "update-grub вернул ошибку — проверьте GRUB вручную после ребута"
            fi
        fi
    elif { [ -d /boot/efi/EFI/systemd ] || [ -f /boot/efi/EFI/ubuntu/grubx64.efi ]; } && ! dpkg -l grub-pc &>/dev/null; then
        print_info "Обнаружен systemd-boot — GRUB конфиг не трогаем, ядро выбирается автоматически"
        print_info "Для смены default kernel на systemd-boot: bootctl set-default <entry>"
    else
        print_info "GRUB не найден или не управляет загрузкой — пропускаем"
    fi
else
    print_error "Ошибка установки ядра! Код: $INSTALL_RESULT"
    print_info "Текущее ядро не тронуто. Сервер загрузится как обычно."
    exit 1
fi

fi  # v4.12: end of "if KERNEL_BRANCH = LTS-already-active ... else ..."

# ==============================================================================
# ШАГ 5: ОТКЛЮЧЕНИЕ IPv6
# ==============================================================================

print_header "ШАГ 5: ОТКЛЮЧЕНИЕ IPv6 (через sysctl, безопасный метод)"

# v4.10: УДАЛЁН метод через GRUB cmdline (ipv6.disable=1) — он трогает boot.
# Оставлен только sysctl-метод: безопасный, применяется runtime, не требует ребута.
#
# Что меняется:
#   - GRUB cmdline НЕ правится (boot не трогаем)
#   - update-grub НЕ вызывается
#   - модуль ipv6 ОСТАЁТСЯ загружен в памяти (~5-10 MB RAM)
#   - но IPv6 трафик не работает: bind(AF_INET6) возвращает EADDRNOTAVAIL,
#     AAAA-resolves не дают результата
#
# Эффект: те же 99% функционального отключения IPv6, без риска поломки boot.

print_status "Создаём sysctl-конфиг для отключения IPv6..."
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
# IPv6 disabled via sysctl (safe method — does not touch GRUB)
# Module ipv6 remains loaded but all IPv6 traffic is rejected.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
print_ok "sysctl-конфиг создан: /etc/sysctl.d/99-disable-ipv6.conf"

# Применяем сразу (без ребута)
# v5.3.3 (fix #A5): если активна SSH-сессия по IPv6 — live-отключение рвёт её
# ПОСРЕДИ прогона (SIGHUP убивает скрипт между установкой ядра и GRUB-пином →
# частичное состояние). Детект: SSH_CONNECTION с IPv6 ИЛИ established v6 на :22.
SSH_OVER_V6=0
if [ -n "${SSH_CONNECTION:-}" ] && [[ "${SSH_CONNECTION}" == *:*:* ]]; then
    SSH_OVER_V6=1
elif command -v ss >/dev/null 2>&1; then
    V6_SSH_COUNT=$(ss -H -6 -tn state established '( sport = :22 )' 2>/dev/null | wc -l)
    [ "${V6_SSH_COUNT:-0}" -gt 0 ] 2>/dev/null && SSH_OVER_V6=1
fi
if [ "$SSH_OVER_V6" -eq 1 ]; then
    print_warn "Обнаружена SSH-сессия по IPv6 — live-отключение IPv6 ПРОПУЩЕНО (оборвало бы сессию и сам скрипт)."
    print_info "Конфиг записан — IPv6 отключится после ребута. Дальше заходи по IPv4."
else
    print_status "Применяем настройки..."
    if sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1; then
        print_ok "IPv6 отключён в runtime"
    else
        print_warn "sysctl -p вернул ошибку — настройки применятся при следующем ребуте"
    fi
fi

# === Force IPv4 priority в gai.conf ===
# Чтобы getaddrinfo() возвращал IPv4 первым, даже если AAAA-запись существует
if [ -f /etc/gai.conf ]; then
    if ! grep -qE '^precedence ::ffff:0:0/96' /etc/gai.conf; then
        print_status "Настраиваем приоритет IPv4 в /etc/gai.conf..."
        echo "" >> /etc/gai.conf
        echo "# Force IPv4 over IPv6 for getaddrinfo()" >> /etc/gai.conf
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
        print_ok "IPv4 приоритет в gai.conf установлен"
    else
        print_info "IPv4 приоритет в gai.conf уже настроен"
    fi
fi

print_ok "IPv6 отключён через sysctl (модуль остаётся в памяти, но трафик не работает)"
print_info "Если хочешь полностью выгрузить модуль — добавь ipv6.disable=1 в GRUB вручную:"
print_info "  sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"ipv6.disable=1 |' /etc/default/grub"
print_info "  update-grub  # затем reboot"

# ==============================================================================
# ШАГ 5.5: CLEANUP конфликтующих sysctl-файлов (v5.0.1)
# ==============================================================================
# Если на ноде кто-то запускал node-diagnostic с -a (auto-apply), он создаёт
# /etc/sysctl.d/99-vpn-tuning.conf с КОНФЛИКТУЮЩИМИ для нашего стэка значениями:
#   somaxconn=8192       → деградация в 8 раз (vs наши 65535)
#   tcp_max_syn_backlog=8192 → то же
#   default_qdisc=cake   → меняет qdisc без обоснования (мы используем fq)
#   rmem_max=64MB        → лишний vs наш tier-aware профиль
# (Note: tcp_fastopen=3 совпадает с нашим default v5.0.3+ — НЕ конфликт.)
# Лексикографически 99-vpn-tuning > 99-conntrack > наш 99-vpn-node-tuning,
# поэтому при reboot diagnostic-значения тихо побеждали наши.
#
# Также удаляем СТАРЫЕ файлы от предыдущих версий нашего setup:
#   /etc/sysctl.d/99-conntrack.conf   (v4.x, v5.0)
#   /etc/sysctl.d/99-xray-tuning.conf (v4.x, v5.0)
# В v5.0.1 всё консолидировано в один /etc/sysctl.d/99-vpn-node-tuning.conf

print_header "ШАГ 5.5: CLEANUP КОНФЛИКТУЮЩИХ SYSCTL-ФАЙЛОВ"

CLEANUP_BACKUP_DIR="/var/lib/vpn-node-builder/snapshots/sysctl-cleanup-$(date -u +%Y%m%dT%H%M%SZ)"
CLEANUP_DID_BACKUP=0

# 1) node-diagnostic'овский файл (конфликтует с нашими профильными значениями)
NODE_DIAG_CONF="/etc/sysctl.d/99-vpn-tuning.conf"
if [ -f "$NODE_DIAG_CONF" ]; then
    # v5.3.0 (fix #17): детект не только по баннеру (его могут сменить), но и по
    # самим конфликтующим ключам. Если файл задаёт default_qdisc=cake ИЛИ
    # somaxconn=8192 — он конфликтует с нашим стэком независимо от заголовка.
    if grep -q "Generated by node-diagnostic" "$NODE_DIAG_CONF" 2>/dev/null || \
       grep -qE '^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*cake' "$NODE_DIAG_CONF" 2>/dev/null || \
       grep -qE '^[[:space:]]*net\.core\.somaxconn[[:space:]]*=[[:space:]]*8192' "$NODE_DIAG_CONF" 2>/dev/null; then
        print_warn "Обнаружен конфликтующий файл (node-diagnostic-стиль): $NODE_DIAG_CONF"
        print_warn "Содержит КОНФЛИКТУЮЩИЕ значения: somaxconn=8192 (деградация 8x vs 65535), default_qdisc=cake (vs fq)"
        mkdir -p "$CLEANUP_BACKUP_DIR"
        cp -a "$NODE_DIAG_CONF" "$CLEANUP_BACKUP_DIR/" 2>/dev/null
        CLEANUP_DID_BACKUP=1
        rm -f "$NODE_DIAG_CONF"
        print_ok "Удалён $NODE_DIAG_CONF (backup в $CLEANUP_BACKUP_DIR/)"
    else
        # Файл с тем же именем но не от diagnostic — оставляем, но warning'им.
        print_warn "Файл $NODE_DIAG_CONF существует, но не похож на node-diagnostic'овский."
        print_warn "Оставляю как есть. Если он мешает — удали вручную."
    fi
fi

# 2) Старые файлы от наших предыдущих версий (v4.x, v5.0).
# В v5.0.1 всё консолидировано в /etc/sysctl.d/99-vpn-node-tuning.conf.
# В v5.1.0 переименовано в 80-vpn-node-tuning.conf (см. ниже про порядок).
for old_conf in /etc/sysctl.d/99-conntrack.conf /etc/sysctl.d/99-xray-tuning.conf /etc/sysctl.d/99-vpn-node-tuning.conf; do
    if [ -f "$old_conf" ]; then
        # Идентифицируем что это наш старый файл по характерному комментарию
        if grep -qE "AUTO-GENERATED|gaming-friendly|tier-aware|XRAY/VPN NODE OPTIMIZATION" "$old_conf" 2>/dev/null; then
            mkdir -p "$CLEANUP_BACKUP_DIR"
            cp -a "$old_conf" "$CLEANUP_BACKUP_DIR/" 2>/dev/null
            CLEANUP_DID_BACKUP=1
            rm -f "$old_conf"
            print_ok "Удалён старый файл: $old_conf (backup сохранён)"
        else
            print_warn "Файл $old_conf существует но не похож на наш — оставляю."
        fi
    fi
done

# v5.1.0 cleanup: ad-hoc UDP fix файлы которые юзеры создавали вручную в проде
# для emergency UDP buffer fix (через 99-z-udp-fix.conf). Теперь fix встроен
# в основной 80-vpn-node-tuning.conf — ad-hoc файлы больше не нужны.
# Backup на всякий случай, потом удаляем.
for udp_fix in /etc/sysctl.d/99-z-udp-fix.conf /etc/sysctl.d/99-udp-fix.conf; do
    if [ -f "$udp_fix" ]; then
        if grep -qE "udp_rmem_min|udp_wmem_min|UDP socket buffer" "$udp_fix" 2>/dev/null; then
            mkdir -p "$CLEANUP_BACKUP_DIR"
            cp -a "$udp_fix" "$CLEANUP_BACKUP_DIR/" 2>/dev/null
            CLEANUP_DID_BACKUP=1
            rm -f "$udp_fix"
            print_ok "Удалён ad-hoc UDP fix: $udp_fix (теперь встроен в основной конфиг)"
        fi
    fi
done

# 3) Если node-diagnostic создал свои systemd unit'ы (vpn-rps.service, vpn-ring.service)
# — оставляем, они не конфликтуют с нашими (rps-tuning.service, nic-tuning.service).
# При желании клиент может удалить вручную.

if [ "$CLEANUP_DID_BACKUP" = "1" ]; then
    print_info "Backup удалённых файлов: $CLEANUP_BACKUP_DIR"
fi
print_ok "Cleanup завершён — система готова к чистой конфигурации v5.0.1"

# ==============================================================================
# ШАГ 6: НАСТРОЙКА CONNTRACK
# ==============================================================================

print_header "ШАГ 6: НАСТРОЙКА CONNTRACK"

print_status "Загружаем модуль nf_conntrack..."
modprobe nf_conntrack 2>/dev/null || true

# v5.0: tier-aware conntrack_max + hashsize.
# Раньше (v4.13) было фиксированно 262144 для всех — на 600+ юзеров с
# keepalive каждые 25 сек + множественные tcp/udp соединения per user
# (Reality + Hysteria2 + WG handshakes) могло подходить к 50%+ utilization
# → drops. Hashsize всегда = conntrack_max / 4 (рекомендация netfilter.org).
#
# Тиры идут по тем же порогам что в ШАГ 7 (sysctl-профили):
#   TIER 1: ≤1.2GB (TOTAL_MEM_MB <= 1200)  — без изменений (1GB не вытянет 600+)
#   TIER 2: ≤2.5GB (TOTAL_MEM_MB <= 2500)  — bump до 524288
#   TIER 3: ≤8.5GB (TOTAL_MEM_MB <= 8500)  — bump до 1048576
#   TIER 4: >8.5GB                          — 1048576
#
# Каждая запись в conntrack ~316 байт, 1M записей = ~316MB RAM.
# Hashsize 262144 buckets × 8 байт = ~2MB — копейки.

# v5.3.0 (fix #1): RAM из /proc/meminfo (MemTotal не локализуется), не из `free`
# (метка "Mem:" — gettext-строка → на не-англ. локали парс мог вернуть пусто →
# 1GB-нода уходила в TIER 4 → OOM). Guard: нет RAM → fail с понятным текстом.
CONNTRACK_TOTAL_MEM_MB=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
if ! [ "${CONNTRACK_TOTAL_MEM_MB:-0}" -ge 1 ] 2>/dev/null; then
    print_error "FATAL: не смог определить объём RAM из /proc/meminfo."
    print_info "Проверь: cat /proc/meminfo | head -1"
    exit 1
fi

if [ "$CONNTRACK_TOTAL_MEM_MB" -le 1200 ]; then
    CONNTRACK_MAX=262144
    CONNTRACK_HASHSIZE=65536
    CONNTRACK_TIER="TIER 1 (≤1.2GB, до ~200 юзеров)"
elif [ "$CONNTRACK_TOTAL_MEM_MB" -le 2500 ]; then
    # v5.0.6 FIX: 524288 → 786432. При 1000 юзеров с современным web (40 active TCP
    # + 100 TIME_WAIT per user × 2 reply) = ~290k entries = 55% от 524288. При 1500
    # юзеров уже 83% — близко к переполнению. 786432 даёт запас до ~1500 юзеров.
    CONNTRACK_MAX=786432
    CONNTRACK_HASHSIZE=196608
    CONNTRACK_TIER="TIER 2 (≤2.5GB, до ~700 юзеров)"
elif [ "$CONNTRACK_TOTAL_MEM_MB" -le 8500 ]; then
    CONNTRACK_MAX=1048576
    CONNTRACK_HASHSIZE=262144
    CONNTRACK_TIER="TIER 3 (≤8.5GB, до ~3000 юзеров)"
else
    # v5.0.6 FIX: TIER 4 был идентичен TIER 3 (1048576) — не использовалось
    # преимущество большего RAM. 2097152 даёт запас до ~6000 юзеров на одной ноде.
    # Cost: 2M × 316 байт = ~640MB RAM (на 16GB ноде это 4%).
    CONNTRACK_MAX=2097152
    CONNTRACK_HASHSIZE=524288
    CONNTRACK_TIER="TIER 4 (>8.5GB, до ~6000 юзеров)"
fi

print_info "Conntrack профиль: $CONNTRACK_TIER → max=$CONNTRACK_MAX, hashsize=$CONNTRACK_HASHSIZE"

# Применяем сразу (до перезагрузки)
print_status "Применяем настройки conntrack..."
sysctl -w "net.netfilter.nf_conntrack_max=$CONNTRACK_MAX" 2>/dev/null || true
# v5.0.6 FIX: было 7200 (2ч) — long-lived TCP (SSH, Telegram MTProto, IMAP IDLE,
# WebSocket) у клиентов VPN дропались через ровно 2 часа при stateful firewall.
# 86400 (24ч) — достаточно для активных юзеров, не создаёт мусора в таблице
# (idle коннекты дропаются keepalive раньше). Минимум по апстрим-консенсусу
# должен быть >= tcp_keepalive_time + N*tcp_keepalive_intvl = 7875 (default kernel).
# v5.3.4 FIX(X1): 86400 -> 7200, скоординировано с shieldnode (90-shieldnode.conf).
# Раньше 86400 в 80- молча проигрывал shieldnode-1800 по лексикографике (90>80) —
# теперь оба пишут 7200, итог детерминирован при любой комбинации установки.
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=7200 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=60 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=60 2>/dev/null || true
# v4.13 CRIT-1: UDP timeouts (udp_timeout / udp_timeout_stream) НЕ выставляем —
# их владеет shieldnode (90-shieldnode.conf: 180/300 для VPN keepalive Hysteria2/
# WireGuard/TUIC). Раньше setup писал 120/180 в 99-conntrack.conf, и из-за
# лексикографического порядка sysctl-d 99 > 90 — наши значения перетирали
# shieldnode'овские при reboot. Симптом: каждый второй UDP-keepalive дропался,
# Hysteria2 рвался у мобильных юзеров.
sysctl -w net.netfilter.nf_conntrack_generic_timeout=300 2>/dev/null || true

# Hashsize = conntrack_max / 4
# Применяем мягко: только если модуль свежезагружен или активных соединений мало
if [ -f /sys/module/nf_conntrack/parameters/hashsize ]; then
    CURRENT_HASHSIZE=$(cat /sys/module/nf_conntrack/parameters/hashsize)
    ACTIVE_CONN=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)

    if [ "$CURRENT_HASHSIZE" = "$CONNTRACK_HASHSIZE" ]; then
        print_info "Hashsize уже $CONNTRACK_HASHSIZE — пропускаем"
    elif [ "$ACTIVE_CONN" -lt 5000 ]; then
        # Безопасно менять — мало активных коннектов
        # v5.3.0 (fix #16): if/else вместо A && B || C (раньше print_info мог
        # сработать даже при успешной записи, если print_ok вернёт non-zero).
        if echo "$CONNTRACK_HASHSIZE" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null; then
            print_ok "Hashsize изменён: $CURRENT_HASHSIZE → $CONNTRACK_HASHSIZE (активных соед.: $ACTIVE_CONN)"
        else
            print_info "Hashsize применится после ребута (через modprobe.d)"
        fi
    else
        # Много активного трафика — не трогаем сейчас, применится после ребута
        print_info "Активных соед.: $ACTIVE_CONN — hashsize применится после ребута (избегаем лагов)"
    fi
fi

# Сохраняем в конфиг для сохранения после ребута
# v4.13 CRIT-1: убраны nf_conntrack_udp_timeout/udp_timeout_stream — их пишет
# shieldnode (90-shieldnode.conf: 180/300 для VPN keepalive). Лексикографический
# порядок 99>90 заставлял setup перетирать shieldnode после reboot.
#
# v5.0.1: КОНСОЛИДАЦИЯ — раньше писали в /etc/sysctl.d/99-conntrack.conf
# (ШАГ 6) И /etc/sysctl.d/99-xray-tuning.conf (ШАГ 7) — два файла наших,
# плюс возможный 99-vpn-tuning.conf от node-diagnostic. Теперь всё в одном
# /etc/sysctl.d/80-vpn-node-tuning.conf — проще ревью и аудит.
#
# v5.1.0: ПЕРЕИМЕНОВАНИЕ 99→80. Раньше наш файл шёл после shieldnode (90-)
# в лексикографическом порядке → наши настройки перебивали shieldnode'овские
# поправки (log_martians, conntrack udp timeouts) при reboot. Теперь правильно:
#   80-vpn-node-tuning.conf  (база, наши tier-aware параметры)
#   90-shieldnode.conf       (security overrides)
#   99-z-*.conf              (ad-hoc operator fixes, override всё)
# Legacy /etc/sysctl.d/99-vpn-node-tuning.conf удаляется в ШАГ 5.5.
SYSCTL_FILE_CONSOLIDATED="/etc/sysctl.d/80-vpn-node-tuning.conf"

cat > "$SYSCTL_FILE_CONSOLIDATED" <<EOF
# ==============================================================================
# vpn-node-setup v${SCRIPT_VERSION} — консолидированный sysctl для VPN-ноды
# ==============================================================================
# Этот файл управляется vpn-node-setup. Не редактируй вручную — изменения
# будут перезаписаны при следующем запуске. Для своих настроек создай
# отдельный /etc/sysctl.d/99-zz-custom.conf (zz = последний лексикографически).
#
# Совместимость:
#   - shieldnode (90-shieldnode.conf): UDP conntrack timeouts оставлены ему.
#   - node-diagnostic (99-vpn-tuning.conf): удаляется в ШАГ 5.5 как опасный.
# ==============================================================================

# === [ШАГ 6] CONNTRACK — tier-aware ===
# Profile: $CONNTRACK_TIER (RAM ${CONNTRACK_TOTAL_MEM_MB}MB)
# UDP timeouts здесь НЕ выставляются — владеет shieldnode (180/300).
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 7200   # v5.3.4: 86400->7200 (coord. с shieldnode 90-)
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_generic_timeout = 300

EOF
print_ok "Conntrack записан в $SYSCTL_FILE_CONSOLIDATED (max=$CONNTRACK_MAX)"

# Hashsize через modprobe для сохранения после ребута
cat > /etc/modprobe.d/conntrack.conf <<EOF
options nf_conntrack hashsize=$CONNTRACK_HASHSIZE
EOF
print_ok "Hashsize сохранён в modprobe.d ($CONNTRACK_HASHSIZE)"

# Гарантируем загрузку модуля при boot (на минималистичных образах его может не быть)
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/conntrack.conf <<EOF
# Force-load conntrack at boot (needed for nf_conntrack_max sysctl to take effect)
nf_conntrack
EOF
print_ok "nf_conntrack будет автозагружаться при boot"

# ==============================================================================
# ШАГ 7: НАСТРОЙКА СЕТЕВОГО СТЕКА (SYSCTL)
# ==============================================================================

print_header "ШАГ 7: НАСТРОЙКА СЕТЕВОГО СТЕКА (SYSCTL)"

# Получаем информацию о памяти
# v5.3.0 (fix #1): total — из /proc/meminfo (см. ШАГ 6). used/free — для вывода,
# под LC_ALL=C чтобы метка "Mem:" не локализовалась. bc с fallback на awk.
TOTAL_MEM_MB=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
if ! [ "${TOTAL_MEM_MB:-0}" -ge 1 ] 2>/dev/null; then
    print_error "FATAL: не смог определить объём RAM из /proc/meminfo."
    exit 1
fi
if command -v bc >/dev/null 2>&1; then
    TOTAL_MEM_GB=$(echo "scale=1; $TOTAL_MEM_MB / 1024" | bc)
else
    TOTAL_MEM_GB=$(awk "BEGIN{printf \"%.1f\", $TOTAL_MEM_MB/1024}")
fi
USED_MEM_MB=$(LC_ALL=C free -m | awk '/^Mem:/{print $3}')
FREE_MEM_MB=$(LC_ALL=C free -m | awk '/^Mem:/{print $4}')

print_status "Анализируем оперативную память..."
echo ""
echo -e "    ${BOLD}Память:${NC}"
echo -e "    ├─ Всего: ${GREEN}${TOTAL_MEM_MB} MB${NC} (~${TOTAL_MEM_GB} GB)"
echo -e "    ├─ Использовано: ${YELLOW}${USED_MEM_MB} MB${NC}"
echo -e "    └─ Свободно: ${GREEN}${FREE_MEM_MB} MB${NC}"
echo ""

SYSCTL_FILE="$SYSCTL_FILE_CONSOLIDATED"

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

# v5.0.3: TFO_VALUE определяется до heredoc (3 = включён, 0 = выключен).
# По умолчанию включаем TFO=3 — снимает bottleneck по числу одновременных
# подключений на пиках. Отключить можно через env: DISABLE_TFO=1.
if [ "${DISABLE_TFO:-0}" = "1" ]; then
    TFO_VALUE=0
    print_warn "DISABLE_TFO=1 — TCP Fast Open будет ВЫКЛЮЧЕН (TFO_VALUE=0)"
    print_warn "Используй только если нода за CDN/middlebox который дропает SYN с TFO cookie."
else
    TFO_VALUE=3
    print_info "TCP Fast Open: TFO_VALUE=3 (включён, default v5.0.3)"
fi

# --- Базовый конфиг (общий для всех профилей) ---
# v5.0.1: используем `>>` (append) — файл уже создан в ШАГ 6 с conntrack-блоком.
# Консолидированный файл $SYSCTL_FILE_CONSOLIDATED содержит весь наш sysctl.
cat >> $SYSCTL_FILE <<EOF
# === [ШАГ 7] СЕТЕВОЙ СТЕК ===
# Profile: $PROFILE_NAME
# RAM: ${TOTAL_MEM_MB} MB
# Generated: $(date -u +%Y-%m-%d)

# === BBRv3 Congestion Control ===
# v5.3.2: на XanMod `bbr` = BBRv3 (built-in, дефолт). default_qdisc=fq перебивает
# дефолт XanMod (fq_pie) — оба работают с BBRv3, но Google рекомендует именно fq.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === IP Forwarding ===
net.ipv4.ip_forward = 1

# === TCP Connections ===
# Очередь входящих соединений (accept backlog)
net.core.somaxconn = 65535
# Очередь SYN-пакетов (защита от SYN flood + пики подключений)
net.ipv4.tcp_max_syn_backlog = 65535
# SYN cookies — moved to shieldnode (90-shieldnode.conf, v5.0.4)
# (раньше: net.ipv4.tcp_syncookies = 1)
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
# RFC 1337 (TIME_WAIT assassination) — moved to shieldnode (90-shieldnode.conf, v5.0.4)
# (раньше: net.ipv4.tcp_rfc1337 = 1)
# v5.0.3: TCP Fast Open включён по умолчанию (бывший anti-pattern v4.x был ОШИБКОЙ).
# TFO работает на уровне TCP SYN, Reality на уровне TLS — РАЗНЫЕ слои стека,
# не конфликтуют. Эмпирически проверено на проде (см. v5.0.3 changelog).
# Решает bottleneck ~550-630 юзеров: экономит 1 RTT на TLS handshake →
# быстрее переход из half-open в established → выше пропускная способность
# по числу новых connections per second.
# Отключить можно через env: DISABLE_TFO=1 sudo bash setup.sh --optimize
net.ipv4.tcp_fastopen = $TFO_VALUE
# Timestamps обязательны для безопасности tcp_tw_reuse (RFC 1323)
net.ipv4.tcp_timestamps = 1

# === Connection Keepalives (Mobile clients) ===
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# === UDP Socket Buffer Floor (v5.1.0 — CRITICAL FIX) ===
# Default kernel udp_rmem_min/udp_wmem_min = 4096 (4 KB per socket).
# Это убивает любой высоконагруженный UDP трафик на VPN-ноде:
#   - QUIC outbound (Xray к Cloudflare/Google/Meta — HTTP/3 на современном вебе)
#   - Caddy HTTP/3 listener (входящие клиенты с Chrome/Safari/Firefox HTTP/3)
#   - Hysteria2 (если используется в стэке)
#   - WireGuard, Tuic, DNS (53/udp)
# При 500+ UDP socket'ов с bursty трафиком kernel дропает датаграммы в
# RcvbufErrors (visible в /proc/net/snmp).
#
# Verified в production (causal-violet-pike, 5895 active TCP + 528 UDP):
#   ДО fix: RcvbufErrors = 82183 (накопленные), растут на десятки/час
#   ПОСЛЕ fix: RcvbufErrors growth = 0/30s устойчиво
#   Источник UDP на тестовой ноде: Caddy HTTP/3 (UDP/443) +
#   528 Xray outbound QUIC сокетов к destination'ам
#
# 8 MB подобран эмпирически — даёт reasonable BDP для QUIC на
# 100-500 Mbps клиентах при RTT 50-200ms, без избыточного memory pressure.
# Это floor (минимум для socket buffer), не reserved — kernel выделяет
# на основании реального BDP, но не опускается ниже этого значения когда
# global udp_mem pressure высокий.
net.ipv4.udp_rmem_min = 8388608
net.ipv4.udp_wmem_min = 8388608

# === TCP Window Scale (v5.2.0 — ВЕРНУЛИ дефолт ядра 1; было -2) ===
# v5.2.0 FIX: -2 заставлял ядро АНОНСИРОВАТЬ окно больше, чем буфер реально
# удержит после skb-truesize-оверхеда. На relay-ноде (CDN → нода → медленный
# CGNAT/мобильный клиент) приёмный буфер упирался в потолок → постоянный
# tcp_collapse()/prune (на проде намерили ~59 collapse/сек, TCPRcvCollapsed
# росло на ~95M) → жжёный softirq-CPU + дропы на приёме + дёрганое окно →
# у клиентов микро-фризы, просадки скорости, долгая загрузка видео/картинок.
# Дефолт ядра =1 (Eric Dumazet перевёл default 2→1 именно как "major latency
# source" для slow-consumer). Синтетический "+5-15%" из netperf на реальном
# relay-трафике под backpressure не держится. BBR делает свой pacing — минусов нет.
net.ipv4.tcp_adv_win_scale = 1

# === Bufferbloat reduction — REMOVED in v5.0.5 ===
# Раньше: net.ipv4.tcp_notsent_lowat = 131072
# Цель была: ограничить unsent данные в socket buffer → меньше latency для
# interactive нагрузок (Reality TLS handshake, SSH, VoIP).
#
# Проблема: VPN-нода это TCP forwarding RELAY (CDN → Xray → клиент), а не
# веб-сервер. Cloudflare ставит 131072 на своих веб-серверах потому что
# они контролируют user-space (Nginx), там это работает с HTTP/2 prioritization.
# У нас Xray читает из CDN-socket'а и пишет в client-socket большие TLS chunks.
# При watermark 131072 (128 KB) write() блокируется когда unsent ≥ 128 KB —
# Xray останавливает чтение от CDN → CDN снижает rate → клиент видит
# buffer drain → YouTube ФРИЗИТ на 0.3-1 секунды периодически.
#
# Kernel default (UINT_MAX / ~4 GB) = unlimited = autotuning сам управляет.
# BBR congestion control делает свой pacing — нам не нужен дополнительный
# watermark на app-level.
#
# Источники:
#   - kernel.org docs: "Default: UINT_MAX (0xFFFFFFFF), meaning this has no effect"
#   - Cloudflare blog (Oct 2025): "Our web servers set 131072 for its sockets,
#     all other senders use 4 GiB, the default value"
#   - Eric Dumazet (patch author): "might increase number of context switches
#     for blocking sockets"

# === Security Hardening — moved to shieldnode (v5.0.4) ===
# Раньше vpn-node-setup писал rp_filter, send_redirects, accept_redirects,
# tcp_syncookies (см. выше), icmp_echo_ignore_broadcasts, tcp_rfc1337 (см. выше)
# в свой 99-vpn-node-tuning.conf (priority 99).
# Эти ключи владеет shieldnode (90-shieldnode.conf, priority 90).
# Лексикографически 99 > 90 — vpn-node-setup перетирал shieldnode при reboot.
# Сейчас значения совпадают, но если shieldnode v3.21+ сменит — наши тихо
# перетрут.
# Если shieldnode на ноде не установлен, выставь эти ключи вручную:
#   cat > /etc/sysctl.d/99-zz-fallback-security.conf <<EOF
#   net.ipv4.conf.all.rp_filter = 2
#   net.ipv4.conf.default.rp_filter = 2
#   net.ipv4.conf.all.send_redirects = 0
#   net.ipv4.conf.default.send_redirects = 0
#   net.ipv4.conf.all.accept_redirects = 0
#   net.ipv4.conf.default.accept_redirects = 0
#   net.ipv4.icmp_echo_ignore_broadcasts = 1
#   net.ipv4.tcp_syncookies = 1
#   net.ipv4.tcp_rfc1337 = 1
#   EOF
#   sysctl -p /etc/sysctl.d/99-zz-fallback-security.conf

# === File Descriptors (ядро, system-wide) ===
fs.file-max = 2097152

# === Inotify Limits (важно при 10k+ соединений Xray) ===
# Дефолты Linux (8192/128) не справляются с большим числом сокетов/файлов
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
fs.inotify.max_queued_events = 65536
EOF

# --- Профильные настройки (зависят от RAM) ---
if [ "$TOTAL_MEM_MB" -le 1200 ]; then
    cat >> $SYSCTL_FILE <<EOF

# === TIER 1: 1GB RAM (SURVIVAL MODE) ===
# v5.3.1: rmem_max/wmem_max 4MB/2MB → 8MB/8MB. Это ПОТОЛОК для setsockopt, который
# делают QUIC-приложения (Caddy HTTP/3, Xray-QUIC, Hysteria2). Раньше quic-go
# писал "failed to sufficiently increase buffer" (хочет 7.5MB, потолок резал на
# 4MB/2MB) и QUIC-send упирался жёстко в 2MB. 8MB закрывает quic-go (7.5MB) и
# согласуется с udp_rmem_min/udp_wmem_min=8MB (раньше floor 8MB > потолка 4MB —
# нестыковка). Память НЕ резервируется (это ceiling, не default — rmem_default
# ниже остаётся 256KB), а агрегат UDP ограничен udp_mem (~360MB cap), runaway нет.
# tcp_rmem/tcp_wmem НЕ трогаем: TCP-автотюн (Reality) не лимитится rmem_max и на
# 1GB ноде ему хватает 4MB/2MB.
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 16384 2097152
# v5.1.0: udp_mem tier-aware (global UDP buffer cap, pages по 4KB).
# ~360 MB ceiling — достаточно для 200-300 UDP sockets на 1GB ноде.
net.ipv4.udp_mem = 44693 59590 89385
vm.vfs_cache_pressure = 150
vm.swappiness = 20
vm.min_free_kbytes = 32768
# v4.13 CRIT-2: overcommit_memory=1 на TIER 1 предотвращает OOM на 1GB ноде
# при пиковой нагрузке (Xray + CrowdSec + bouncer = ~600MB baseline,
# +200-300MB пиков). Без этого kernel может отказывать в malloc.
vm.overcommit_memory = 1
EOF

elif [ "$TOTAL_MEM_MB" -le 2500 ]; then
    cat >> $SYSCTL_FILE <<EOF

# === TIER 2: 2GB RAM (BALANCED MODE) ===
# v5.3.1: wmem_max 8MB → 16MB (симметрия с rmem_max=16MB). 8MB закрывал quic-go
# (7.5MB), но Hysteria2-send рекомендует 16MB. Потолок setsockopt, память не
# резервирует; агрегат ограничен udp_mem (~700MB cap на TIER2).
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
# v5.1.0 CRITICAL: rmem_default 262144 → 2097152 (2MB).
# Xray не вызывает setsockopt(SO_RCVBUF) явно — сокеты создаются с
# *_default размером, не *_max. 262144 (256KB) был bottleneck'ом для
# QUIC/UDP burst трафика. 2MB - safe sweet spot для 2GB ноды:
# ~500 UDP sockets × 1MB средне = 500MB на буферы, остальное Xray + ОС.
# (Реальная аллокация = high watermark от autotuning, не reserved per socket.)
# На TIER 3+ можно ставить 8MB (см. ниже), на 2GB - 2MB безопаснее.
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 32768 8388608
# v5.1.0: udp_mem tier-aware (~700 MB ceiling для UDP)
net.ipv4.udp_mem = 89385 119181 178770
vm.vfs_cache_pressure = 100
vm.swappiness = 10
vm.min_free_kbytes = 65536
net.core.netdev_max_backlog = 4096
# overcommit_memory=1 на TIER 2: позволяет ядру не отказывать в крупных
# аллокациях при фрагментации (Go-рантайм при mmap-fail аварийно завершается
# с "out of memory", не SIGSEGV — формулировка прошлых версий была неточной).
# ВАЖНО: главная анти-OOM мера на TIER1/2 теперь — zram-swap (ШАГ 7.4), который
# поглощает пики; overcommit лишь снижает спорадические fork/alloc-отказы.
vm.overcommit_memory = 1
EOF

elif [ "$TOTAL_MEM_MB" -le 8500 ]; then
    cat >> $SYSCTL_FILE <<EOF

# === TIER 3: 4-8GB RAM (PERFORMANCE MODE) ===
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
# v5.1.0 CRITICAL: rmem_default 524288 → 8388608 (8MB).
# Verified в production (causal-violet-pike 8GB, 5895 active TCP +
# 528 UDP sockets, peak hours): после изменения RcvbufErrors → 0,
# заметное улучшение QUIC throughput (Xray к Cloudflare/Google).
# Реальная memory pressure после fix: ~800MB на UDP buffers (kernel
# не reserve, аллоцирует по BDP). На 8GB ноде - безопасно.
net.core.rmem_default = 8388608
net.core.wmem_default = 8388608
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
# v5.1.0: udp_mem tier-aware (~3 GB ceiling)
net.ipv4.udp_mem = 371994 495994 743988
vm.swappiness = 10
vm.min_free_kbytes = 131072
net.core.netdev_max_backlog = 16384
# tcp_adv_win_scale=-2 moved to base block in v5.1.0 (applies to all tiers)
EOF

else
    cat >> $SYSCTL_FILE <<EOF

# === TIER 4: 8GB+ RAM (ULTRA 10G MODE) ===
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
# v5.1.0: rmem_default 1048576 → 8388608 (8MB).
# На больших ноды можно даже больше, но 8MB достаточно для 90% workloads.
# Для специальных нагрузок (10G+ throughput) поднять до 16MB через
# /etc/sysctl.d/99-zz-custom.conf.
net.core.rmem_default = 8388608
net.core.wmem_default = 8388608
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 87380 33554432
# v5.1.0: udp_mem tier-aware (~6 GB ceiling)
net.ipv4.udp_mem = 743988 991988 1487976
vm.swappiness = 10
vm.min_free_kbytes = 262144
net.core.netdev_max_backlog = 32768
# tcp_adv_win_scale=-2 moved to base block in v5.1.0
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

# Применяем sysctl конфиги явно (БЕЗ --system: 99-disable-ipv6.conf обработан
# в ШАГ 5 отдельно с проверкой SSH-over-IPv6 — здесь его не трогаем)
# v5.0.1: один консолидированный файл (раньше было два — 99-xray-tuning + 99-conntrack)
print_status "Применяем sysctl конфигурацию (tuning + conntrack, без IPv6)..."
if [ -f "$SYSCTL_FILE_CONSOLIDATED" ]; then
    sysctl -p "$SYSCTL_FILE_CONSOLIDATED" 2>/dev/null | tail -5
fi
print_ok "Sysctl применён (BBR и qdisc активируются после ребута на XanMod; IPv6 — после ребута)"

# ==============================================================================
# ШАГ 7.4: ZRAM SWAP (v5.3.0 — anti-OOM на TIER 1/2)  [fix #13]
# ==============================================================================
# На 1-2GB ноде пики (Xray+CrowdSec+QUIC-буферы) → OOM-kill Xray (downtime для
# всех). zram = сжатый swap в RAM: гасит пики без диск-износа и сетевой латентности.
# Только TIER1/2 и только если swap отсутствует. Отключить: SETUP_NO_ZRAM=1.
if [ "$TOTAL_MEM_MB" -le 2500 ] && [ "${SETUP_NO_ZRAM:-0}" != "1" ]; then
    print_header "ШАГ 7.4: ZRAM SWAP (anti-OOM для $PROFILE_NAME)"
    EXISTING_SWAP=$(awk 'NR>1{print}' /proc/swaps 2>/dev/null | wc -l)
    if [ "$EXISTING_SWAP" -gt 0 ]; then
        print_info "Swap уже присутствует ($EXISTING_SWAP устройств) — zram не добавляю."
    elif [ "$DRY_RUN" -eq 1 ]; then
        print_info "[DRY-RUN] здесь был бы создан zram-swap (~50% RAM, max 512MB)."
    else
        # zram-size: 50% RAM, но не больше 512MB (на 1-2GB ноде этого достаточно).
        ZRAM_MB=$(( TOTAL_MEM_MB / 2 ))
        [ "$ZRAM_MB" -gt 512 ] && ZRAM_MB=512
        print_status "Настраиваю zram-swap: ${ZRAM_MB}MB (zstd)..."

        if modprobe zram 2>/dev/null; then
            # Генератор устройства + systemd-unit для персистентности после ребута.
            cat > /usr/local/sbin/vpn-zram.sh <<ZRAMEOF
#!/bin/bash
# Auto-generated by vpn-node-setup v5.3.0 (fix #13): zram-swap anti-OOM.
set -e
ZRAM_MB=${ZRAM_MB}
modprobe zram 2>/dev/null || true
# Берём первое свободное zram-устройство (не ломаем чужие, напр. zram0 от systemd).
DEV=\$(zramctl --find --size \${ZRAM_MB}M --algorithm zstd 2>/dev/null) || {
    # Fallback для старых zramctl без --find
    [ -e /dev/zram0 ] || echo 1 > /sys/class/zram-control/hot_add 2>/dev/null || true
    DEV=/dev/zram0
    echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    echo \${ZRAM_MB}M > /sys/block/zram0/disksize 2>/dev/null || true
}
mkswap "\$DEV" >/dev/null 2>&1 || true
# priority 100 — zram выше любого диск-swap (быстрее).
swapon -p 100 "\$DEV" 2>/dev/null || true
ZRAMEOF
            chmod +x /usr/local/sbin/vpn-zram.sh

            cat > /etc/systemd/system/vpn-zram.service <<'ZUNIT'
[Unit]
Description=vpn-node-setup zram swap (anti-OOM, TIER1/2)
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vpn-zram.sh
ExecStop=/bin/sh -c 'for d in /dev/zram*; do swapoff "$d" 2>/dev/null || true; done'

[Install]
WantedBy=multi-user.target
ZUNIT
            systemctl daemon-reload 2>/dev/null || true
            if systemctl enable --now vpn-zram.service >/dev/null 2>&1; then
                sleep 1
                if grep -q zram /proc/swaps 2>/dev/null; then
                    print_ok "zram-swap активен (${ZRAM_MB}MB, zstd, priority 100) — переживёт reboot"
                else
                    print_warn "vpn-zram.service запущен, но zram не виден в /proc/swaps — проверь: swapon --show"
                fi
            else
                print_warn "Не удалось enable vpn-zram.service — zram не настроен"
            fi
        else
            print_warn "Модуль zram недоступен в текущем ядре — zram-swap пропущен (применится после ребута на XanMod LTS)"
            print_info "После ребута повтори --optimize чтобы поднять zram на новом ядре."
        fi
    fi
fi

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
    QDISC_CUSTOM=0   # v5.3.3 (fix #A4)

    # Считаем количество TX очередей
    QUEUES=$(ls /sys/class/net/"$IFACE"/queues/ 2>/dev/null | grep -c tx)
    print_status "Анализируем структуру очередей..."
    echo -e "    ├─ CPU ядер: ${GREEN}$(nproc)${NC}"
    echo -e "    └─ TX очередей: ${GREEN}$QUEUES${NC}"
    echo ""

    if [ "$QUEUES" -gt 1 ]; then
        # Multi-queue NIC: ставим mq как root, на каждую queue — fq
        print_status "Настраиваем Multi-Queue (mq + fq per-queue)..."

        # Проверяем текущий root qdisc — если уже mq, не трогаем (избегаем drop пакетов)
        CURRENT_ROOT=$(tc qdisc show dev "$IFACE" | awk '/qdisc/ && /root/ {print $2; exit}')
        if [ "$CURRENT_ROOT" = "mq" ]; then
            print_info "Root qdisc уже mq — пропускаем replace (без drop пакетов)"
        elif [[ "$CURRENT_ROOT" =~ ^(htb|cake|cbq|hfsc|codel|pie|netem|tbf)$ ]]; then
            # v5.0.4 (fix #15): не трогать custom qdisc (manual admin config).
            # Раньше: tc qdisc replace wipe'ил custom config молча.
            print_warn "Custom qdisc '$CURRENT_ROOT' обнаружен на $IFACE — НЕ трогаю."
            print_info "Если хочешь применить mq+fq: tc qdisc del dev $IFACE root, потом повторить --optimize"
            QDISC_MODE="custom ($CURRENT_ROOT, untouched)"
            QDISC_CUSTOM=1   # v5.3.3 (fix #A4): пост-блок ниже скипается
            APPLIED=0
            MQ_HANDLE=""
        else
            # add вместо replace когда возможно
            tc qdisc add dev "$IFACE" root handle 1: mq 2>/dev/null || \
                tc qdisc replace dev "$IFACE" root handle 1: mq 2>/dev/null
        fi

        # Ждём пока mq создаст sub-qdisc'ы
        # v5.3.3 (fix #A4): при custom qdisc пост-блок скипаем целиком — раньше он
        # затирал QDISC_MODE на "mq + fq" и печатал ложный "mq уже инициализирован".
        if [ "${QDISC_CUSTOM:-0}" != "1" ]; then
        sleep 1
        MQ_HANDLE=$(tc qdisc show dev "$IFACE" | awk '/qdisc mq/ {print $3}' | head -1)

        if [ -n "$MQ_HANDLE" ]; then
            # Фикс hex-индексации: для 16+ очередей нужен правильный hex
            # mq использует индексы 1..N в hex (1, 2, ... 9, a, b, ... f, 10, 11, ...)
            APPLIED=0
            for i in $(seq 1 "$QUEUES"); do
                HEX_IDX=$(printf '%x' "$i")
                # Проверяем есть ли уже fq на этой child queue — если да, пропускаем
                EXISTING=$(tc qdisc show dev "$IFACE" | grep "parent ${MQ_HANDLE}${HEX_IDX} " | grep -c fq)
                if [ "$EXISTING" -eq 0 ]; then
                    if tc qdisc add dev "$IFACE" parent "${MQ_HANDLE}${HEX_IDX}" fq 2>/dev/null; then
                        APPLIED=$((APPLIED + 1))
                    elif tc qdisc change dev "$IFACE" parent "${MQ_HANDLE}${HEX_IDX}" fq 2>/dev/null; then
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
        fi  # v5.3.3 (fix #A4) QDISC_CUSTOM guard
    else
        # Single-queue: один fq на root (через add если можно — без drop)
        print_status "Настраиваем Single-Queue (fq)..."
        CURRENT_ROOT=$(tc qdisc show dev "$IFACE" | awk '/qdisc/ && /root/ {print $2; exit}')
        if [ "$CURRENT_ROOT" = "fq" ]; then
            print_info "fq уже активен — пропускаем"
        elif [[ "$CURRENT_ROOT" =~ ^(htb|cake|cbq|hfsc|codel|pie|netem|tbf|mq)$ ]]; then
            # v5.0.4 (fix #15): не трогать custom qdisc (manual admin config).
            print_warn "Custom qdisc '$CURRENT_ROOT' обнаружен на $IFACE — НЕ трогаю."
            print_info "Если хочешь применить fq: tc qdisc del dev $IFACE root, потом повторить --optimize"
            QDISC_MODE="custom ($CURRENT_ROOT, untouched)"
            QDISC_CUSTOM=1   # v5.3.3 (fix #A4)
        else
            tc qdisc add dev "$IFACE" root fq 2>/dev/null || tc qdisc replace dev "$IFACE" root fq
        fi
        # v5.3.3 (fix #A4): не затирать QDISC_MODE/печать при custom qdisc.
        if [ "${QDISC_CUSTOM:-0}" != "1" ]; then
            print_ok "Single-Queue настроен: fq на root"
            QDISC_MODE="fq (single-queue)"
        fi
    fi

    echo ""
    print_info "Текущая структура qdisc:"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────────${NC}"
    tc qdisc show dev "$IFACE"
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
    HW_QUEUES=$(ls /sys/class/net/"$IFACE"/queues/ 2>/dev/null | grep -c rx)

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
        # v5.3.4 FIX(V2): rps_cpus требует cpumask запятыми по 32-бит словам (старший
        # первым); (1<<CPUS) переполняется при CPUS>=64 (давало маску "0" = RPS off).
        # Строим маску по группам — корректно при любом числе ядер.
        _rem=$(( CPUS % 32 )); _full=$(( CPUS / 32 )); MASK=""
        [ "$_rem" -gt 0 ] && MASK=$(printf '%x' $(( (1 << _rem) - 1 )))
        _i=0; while [ "$_i" -lt "$_full" ]; do MASK="${MASK:+$MASK,}ffffffff"; _i=$((_i+1)); done
        [ -z "$MASK" ] && MASK=0
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
# v5.3.4 FIX(V2): cpumask запятыми по 32-бит словам (старший первым); без этого
# на >32 CPU ядро отвергало одно-токеновый hex, а при CPUS>=64 маска была "0".
_rem=$(( CPUS % 32 )); _full=$(( CPUS / 32 )); MASK=""
[ "$_rem" -gt 0 ] && MASK=$(printf '%x' $(( (1 << _rem) - 1 )))
_i=0; while [ "$_i" -lt "$_full" ]; do MASK="${MASK:+$MASK,}ffffffff"; _i=$((_i+1)); done
[ -z "$MASK" ] && MASK=0
for q in /sys/class/net/"$IFACE"/queues/rx-*/rps_cpus; do
    [ -w "$q" ] && echo $MASK > $q
done
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
for q in /sys/class/net/"$IFACE"/queues/rx-*/rps_flow_cnt; do
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
        ACTIVE_MASK=$(cat /sys/class/net/"$IFACE"/queues/rx-0/rps_cpus 2>/dev/null)
        if [ "$ACTIVE_MASK" = "$MASK" ] || [ "$(echo "$ACTIVE_MASK" | tr -d 0,)" = "$(echo "$MASK" | tr -d 0,)" ]; then
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

        # v5.3.3 (fix #A3): ethtool -k печатает ДЛИННЫЕ имена (generic-receive-offload:),
        # старый grep '^gro-...:' никогда не матчился → gro/gso/tso не детектились в
        # runtime (реально работали только rx/tx-checksumming). Маппинг short→long.
        _off_long_name() {
            case "$1" in
                gro) echo "generic-receive-offload" ;;
                gso) echo "generic-segmentation-offload" ;;
                tso) echo "tcp-segmentation-offload" ;;
                tx)  echo "tx-checksumming" ;;
                rx)  echo "rx-checksumming" ;;
                *)   echo "$1" ;;
            esac
        }

        for off in "${OFFLOAD_LIST[@]}"; do
            OFF_LONG=$(_off_long_name "$off")
            CURRENT=$(ethtool -k "$IFACE" 2>/dev/null | grep -E "^${OFF_LONG}:" | head -1 | awk '{print $2}')

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

        # v5.1.0: LRO явно выключаем (defensive).
        # LRO (Large Receive Offload) КОНФЛИКТУЕТ с ip_forward=1 — kernel
        # auto-disable работает для большинства драйверов, но ixgbe и
        # некоторые vmxnet3 firmware игнорируют. На virtio_net LRO обычно
        # [fixed off] — наш ethtool -K вернёт ошибку, мы тихо игнорируем.
        if ethtool -K "$IFACE" lro off 2>/dev/null; then
            print_ok "LRO: explicitly disabled (защита от ixgbe/vmxnet3 forwarding bugs)"
            NIC_BOOSTS_APPLIED+=("lro off")
        fi

        # v5.1.0: UDP-GRO forwarding попытка включения.
        # Помогает PPS для Hysteria2 на forwarding path — kernel батчит
        # UDP пакеты в super-packets для драйвера. Default off на большинстве
        # систем. На virtio_net + XanMod 6.18 — поддерживается.
        if ethtool -K "$IFACE" rx-udp-gro-forwarding on 2>/dev/null; then
            print_ok "rx-udp-gro-forwarding: enabled (Hysteria2 PPS boost)"
            NIC_BOOSTS_APPLIED+=("udp-gro-forwarding")
        fi
    else
        print_info "ethtool не работает с $IFACE — пропускаем offloads"
    fi

    # v5.1.0: Multi-queue NIC попытка.
    # На virtio_net дефолт обычно combined=1 — все RX/TX на одном CPU.
    # ethtool -L combined N запрашивает N очередей. На QEMU/KVM:
    #   - max=1 (типично для small VPS): команда тихо fail, no-op
    #   - max>1: kernel создаст N очередей → RPS/XPS работает эффективнее
    # Безопасно: kernel сам валидирует, не падает при неподдержке.
    if command -v ethtool >/dev/null 2>&1; then
        MAX_COMBINED=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Pre-set maximums/,/Current hardware settings/' | awk '/^Combined:/{print $2; exit}')
        CUR_COMBINED=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Current hardware settings/,EOF' | awk '/^Combined:/{print $2; exit}')
        if [ -n "$MAX_COMBINED" ] && [ -n "$CUR_COMBINED" ] && [ "$MAX_COMBINED" -gt 1 ] 2>/dev/null && [ "$MAX_COMBINED" -gt "$CUR_COMBINED" ] 2>/dev/null; then
            TARGET=$(( MAX_COMBINED < CPUS ? MAX_COMBINED : CPUS ))
            if [ "$TARGET" -gt "$CUR_COMBINED" ] && ethtool -L "$IFACE" combined "$TARGET" 2>/dev/null; then
                print_ok "NIC combined queues: $CUR_COMBINED → $TARGET (max=$MAX_COMBINED)"
                NIC_BOOSTS_APPLIED+=("multi-queue $TARGET")
            fi
        else
            print_info "NIC max-combined=${MAX_COMBINED:-?} cur=${CUR_COMBINED:-?} — multi-queue не применим"
        fi
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

            # Применяем только если есть смысл (current < max и разница хотя бы 4x)
            # 4x порог — на mlx5/ixgbe при меньшей разнице link-flap не оправдан
            # И не на virtio (там почти всегда max=current и команда no-op)
            DRIVER=$(ethtool -i "$IFACE" 2>/dev/null | awk '/^driver:/ {print $2}')

            if [ "$DRIVER" = "virtio_net" ]; then
                print_info "virtio_net: ring buffers тюнинг не применим, пропускаем (без link-flap)"
            elif [ -n "$CUR_RX" ] && [ "$CUR_RX" = "$MAX_RX" ]; then
                print_info "Ring buffers уже на максимуме, пропускаем"
            elif [ -n "$CUR_RX" ] && [ "$((MAX_RX / CUR_RX))" -lt 4 ] 2>/dev/null; then
                print_info "Прирост <4x (${CUR_RX}→${MAX_RX}), пропускаем (link-flap не оправдан)"
            else
                # Только тут реально применяем — выгода оправдывает короткий разрыв
                print_status "Применяем ring buffers (возможен link-flap 1-3 сек)..."
                if ethtool -G "$IFACE" rx "$MAX_RX" tx "$MAX_TX" 2>/dev/null; then
                    print_ok "Ring buffers: RX=$MAX_RX, TX=$MAX_TX (было RX=$CUR_RX/$CUR_TX)"
                    NIC_BOOSTS_APPLIED+=("ring buffers max")
                    # v5.3.0 (fix #8): персистим ring buffers через udev (срабатывает
                    # на device-add, ДО трафика — без per-boot link-flap, который давал
                    # nic-tuning.service на уже-поднятом линке). Из nic-tuning.sh убрано.
                    if command -v ethtool >/dev/null 2>&1; then
                        ETHTOOL_BIN=$(command -v ethtool)
                        mkdir -p /etc/udev/rules.d
                        cat > /etc/udev/rules.d/99-vpn-nic-rings.rules <<UDEV_RINGS
# Generated by vpn-node-setup v5.3.0 (fix #8): персистентные NIC ring buffers.
# Применяются на device-add (до трафика) — без per-boot link-flap.
# Матчим по имени интерфейса на момент установки. Если NIC переименуют —
# обнови правило (или перезапусти --optimize).
ACTION=="add", SUBSYSTEM=="net", KERNEL=="$IFACE", RUN+="$ETHTOOL_BIN -G $IFACE rx $MAX_RX tx $MAX_TX"
UDEV_RINGS
                        udevadm control --reload 2>/dev/null || true
                        print_ok "udev-правило сохранено: /etc/udev/rules.d/99-vpn-nic-rings.rules (flap-free персистентность)"
                    fi
                else
                    print_info "Драйвер не позволяет менять ring buffers"
                fi
            fi
        else
            print_info "Драйвер не сообщает max ring buffer size"
        fi
    fi

    # === БУСТ 3: GRO Flush Timeout + napi_defer_hard_irqs ===
    # v5.0.5: ВОЗВРАЩЕНО к kernel default (0/0).
    # Раньше: gro_flush=50µs, napi_defer=1 — батчинг прерываний для экономии CPU.
    # Проблема: kernel docs прямо говорят "choosing a large value for
    # gro_flush_timeout will defer IRQs to allow for better batch processing,
    # but will induce latency when the system is not fully loaded".
    # На VPN-relay ноде с малым/средним числом активных юзеров (50-200) система
    # часто "not fully loaded" → defer добавляет 50µs jitter на TX path → может
    # усиливать ощущение micro-stall в видеостримах.
    # Экономия CPU 15-25% softirq заметна только при пиковой нагрузке (1000+
    # юзеров), для типичной ноды эта экономия не оправдывает jitter.
    #
    # Если нода действительно перегружена (cpu softirq >50% на ядро) — можно
    # вернуть значения вручную:
    #   echo 50000 > /sys/class/net/"$IFACE"/gro_flush_timeout
    #   echo 1 > /sys/class/net/"$IFACE"/napi_defer_hard_irqs
    print_status "Сбрасываю GRO flush + napi defer к kernel default (classic NAPI)..."
    GRO_PATH="/sys/class/net/$IFACE/gro_flush_timeout"
    NAPI_PATH="/sys/class/net/$IFACE/napi_defer_hard_irqs"

    if [ -w "$GRO_PATH" ] && [ -w "$NAPI_PATH" ]; then
        OLD_GRO=$(cat "$GRO_PATH" 2>/dev/null)
        OLD_NAPI=$(cat "$NAPI_PATH" 2>/dev/null)
        echo 0 > "$GRO_PATH" 2>/dev/null
        echo 0 > "$NAPI_PATH" 2>/dev/null
        NEW_GRO=$(cat "$GRO_PATH" 2>/dev/null)
        NEW_NAPI=$(cat "$NAPI_PATH" 2>/dev/null)
        if [ "$NEW_GRO" = "0" ] && [ "$NEW_NAPI" = "0" ]; then
            if [ "$OLD_GRO" != "0" ] || [ "$OLD_NAPI" != "0" ]; then
                print_ok "GRO flush + napi defer: ($OLD_GRO/$OLD_NAPI) → (0/0) — classic NAPI"
                NIC_BOOSTS_APPLIED+=("GRO defer reset to 0 (classic NAPI)")
            else
                print_info "GRO flush + napi defer уже в kernel default (0/0)"
            fi
        else
            print_info "GRO flush не применился, возможно read-only sysfs"
        fi
    else
        print_info "GRO flush недоступен (старое ядро или виртуалка)"
    fi

    # === БУСТ 3.5: txqueuelen=10000 ===
    # v4.13: default 1000 — узкое горлышко на virtio при пиках исходящего
    # трафика (Reality response, Hysteria2 ACK). Поднимаем до 10000.
    # Стоимость: ~13MB max буфер при полной очереди (10000 × 1500B), но
    # реально используется fraction. С qdisc fq (BBR) drops редкие — это
    # safety net против burst'ов.
    print_status "Настраиваем txqueuelen=10000 (буфер исходящих пакетов)..."
    OLD_QLEN=$(ip -o link show dev "$IFACE" 2>/dev/null | grep -oE 'qlen [0-9]+' | awk '{print $2}')
    OLD_QLEN="${OLD_QLEN:-1000}"
    if ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null; then
        NEW_QLEN=$(ip -o link show dev "$IFACE" 2>/dev/null | grep -oE 'qlen [0-9]+' | awk '{print $2}')
        if [ "$NEW_QLEN" = "10000" ]; then
            print_ok "txqueuelen: $OLD_QLEN → 10000 (защита от TX-drops при пиках)"
            NIC_BOOSTS_APPLIED+=("txqueuelen 10000")
        else
            print_info "txqueuelen применился, но проверка показала: $NEW_QLEN"
        fi
    else
        print_info "txqueuelen применить не удалось (driver limitation)"
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

    # === БУСТ 5: IRQ Affinity (распределение прерываний RX/TX очередей по CPU) ===
    # Без этого все прерывания сыпятся на CPU0 → бутылочное горлышко на 10G/multi-queue
    # ВАЖНО: irqbalance конфликтует с ручным affinity — отключаем его ТОЛЬКО если
    # реально применили affinity (на single-queue NIC он полезен — пусть работает)
    if [ "$CPUS" -gt 1 ] && [ -n "$IFACE" ]; then
        print_status "Анализируем IRQ сетевого интерфейса $IFACE..."

        # Собираем IRQ номера сетевой карты из /proc/interrupts
        # Формат строк: " 123: ... ethX-rx-0" или "iface-TxRx-0" (зависит от драйвера)
        NIC_IRQS=$(grep -E "(^|[[:space:]])${IFACE}(-|$)" /proc/interrupts 2>/dev/null | awk -F: '{gsub(/ /,"",$1); print $1}')

        if [ -z "$NIC_IRQS" ]; then
            print_info "IRQ для $IFACE не найдены в /proc/interrupts (virtio/paravirt? пропускаем)"
            IRQ_AFFINITY_MODE="skipped (no IRQs)"
        else
            IRQ_COUNT=$(echo "$NIC_IRQS" | wc -l)
            echo -e "    ├─ IRQ найдено: ${GREEN}$IRQ_COUNT${NC}"
            echo -e "    └─ Стратегия: round-robin по $CPUS CPU"

            # Проверяем не работает ли irqbalance — если да, исключаем NIC IRQ из его контроля
            # вместо полного отключения (irqbalance полезен для других IRQ — диски, USB)
            # v5.3.0 (fix #15): убрана дохлая переменная IRQBALANCE_ACTIVE (нигде не читалась).
            if systemctl is-active irqbalance &>/dev/null; then
                print_status "Обнаружен активный irqbalance — настраиваем IRQBALANCE_BANNED_CPULIST..."

                # Создаём banned IRQ список для irqbalance (не отключаем сервис целиком)
                mkdir -p /etc/default
                BANNED_IRQS=$(echo "$NIC_IRQS" | tr '\n' ' ' | sed 's/ $//')

                # Пишем drop-in конфиг (не трогаем основной /etc/default/irqbalance)
                if [ -f /etc/default/irqbalance ]; then
                    # Удаляем старую запись если была
                    sed -i '/^IRQBALANCE_BANNED_INTERRUPTS=/d' /etc/default/irqbalance
                    echo "IRQBALANCE_BANNED_INTERRUPTS=\"$BANNED_IRQS\"" >> /etc/default/irqbalance
                    systemctl restart irqbalance 2>/dev/null || true
                    print_ok "irqbalance настроен: NIC IRQs ($IRQ_COUNT шт.) исключены из его управления"
                fi
            fi

            # Применяем round-robin affinity: IRQ N → CPU (N % CPUS)
            # v5.3.0 (fix #12): пишем номер CPU в smp_affinity_list (а не hex-маску в
            # smp_affinity) — корректно при любом числе ядер. На 32+ CPU одиночная
            # hex-маска без группировки отвергалась ядром (и 1<<CPU при CPU>=64 = 0).
            # Fallback на hex-маску для <32 CPU.
            APPLIED_IRQ=0
            IRQ_INDEX=0
            for irq in $NIC_IRQS; do
                CPU_FOR_IRQ=$((IRQ_INDEX % CPUS))
                if [ -w "/proc/irq/$irq/smp_affinity_list" ] && \
                   echo "$CPU_FOR_IRQ" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null; then
                    APPLIED_IRQ=$((APPLIED_IRQ + 1))
                elif [ "$CPUS" -le 32 ] && [ -w "/proc/irq/$irq/smp_affinity" ]; then
                    AFFINITY_MASK=$(printf "%x" $((1 << CPU_FOR_IRQ)))
                    if echo "$AFFINITY_MASK" > "/proc/irq/$irq/smp_affinity" 2>/dev/null; then
                        APPLIED_IRQ=$((APPLIED_IRQ + 1))
                    fi
                fi
                IRQ_INDEX=$((IRQ_INDEX + 1))
            done

            if [ "$APPLIED_IRQ" -gt 0 ]; then
                print_ok "IRQ affinity: $APPLIED_IRQ/$IRQ_COUNT прерываний распределены по $CPUS CPU"
                NIC_BOOSTS_APPLIED+=("IRQ affinity ($APPLIED_IRQ irqs)")
                IRQ_AFFINITY_MODE="enabled ($APPLIED_IRQ irqs, round-robin)"
            else
                print_info "IRQ affinity не применился (возможно kernel не позволяет, или CPU isolation активен)"
                IRQ_AFFINITY_MODE="failed"
            fi
        fi
    else
        IRQ_AFFINITY_MODE="skipped (single CPU or no iface)"
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

# v5.3.0 (fix #8): ring buffers здесь БОЛЬШЕ НЕ трогаем — это вызывало link-flap
# на КАЖДОМ буте (сервис стартует After=network-online, линк уже поднят). Теперь
# ring buffers персистятся через udev-правило /etc/udev/rules.d/99-vpn-nic-rings.rules
# (срабатывает на device-add, до трафика — без флапа). Здесь только flap-free бусты.
if command -v ethtool >/dev/null 2>&1; then
    # Offloads — безопасно, поддерживаются практически всеми драйверами
    for off in gro gso tso tx rx; do
        ethtool -K "$IFACE" "$off" on 2>/dev/null || true
    done
    # v5.1.0: LRO off (defensive — ip_forward=1 несовместим с LRO)
    ethtool -K "$IFACE" lro off 2>/dev/null || true
    # v5.1.0: UDP-GRO forwarding (Hysteria2 PPS boost)
    ethtool -K "$IFACE" rx-udp-gro-forwarding on 2>/dev/null || true
fi

# v5.1.0: Multi-queue NIC (best-effort, no-op на virtio max=1)
if command -v ethtool >/dev/null 2>&1; then
    MAX_C=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Pre-set maximums/,/Current hardware settings/' | awk '/^Combined:/{print $2; exit}')
    CUR_C=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Current hardware settings/,EOF' | awk '/^Combined:/{print $2; exit}')
    if [ -n "$MAX_C" ] && [ -n "$CUR_C" ] && [ "$MAX_C" -gt 1 ] 2>/dev/null && [ "$MAX_C" -gt "$CUR_C" ] 2>/dev/null; then
        TARGET=$(( MAX_C < CPUS ? MAX_C : CPUS ))
        [ "$TARGET" -gt "$CUR_C" ] && ethtool -L "$IFACE" combined "$TARGET" 2>/dev/null || true
    fi
fi

# GRO flush + napi defer — v5.0.5: classic NAPI (0/0), без deferred IRQs.
# Раньше 50µs/1 — добавляло jitter на TX path под лёгкой нагрузкой.
[ -w "/sys/class/net/"$IFACE"/gro_flush_timeout" ] && echo 0 > "/sys/class/net/"$IFACE"/gro_flush_timeout"
[ -w "/sys/class/net/"$IFACE"/napi_defer_hard_irqs" ] && echo 0 > "/sys/class/net/"$IFACE"/napi_defer_hard_irqs"

# v4.13: txqueuelen=10000 для virtio (default 1000 узкое горлышко на пиках
# исходящего трафика). На физических NIC default уже 1000-10000, lift'ить
# не повредит. Применяется в runtime прямо сейчас + сохраняется через этот
# сервис на каждый reboot.
ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null || true

# XPS — распределение TX по CPU (только если CPU < 32 для безопасности маски)
if [ "$CPUS" -gt 1 ] && [ "$CPUS" -lt 32 ]; then
    for tx_q in /sys/class/net/"$IFACE"/queues/tx-*; do
        [ ! -d "$tx_q" ] && continue
        Q_NUM=$(basename "$tx_q" | sed 's/tx-//')
        CPU_FOR_Q=$((Q_NUM % CPUS))
        CPU_MASK=$(printf "%x" $((1 << CPU_FOR_Q)))
        [ -w "$tx_q/xps_cpus" ] && echo "$CPU_MASK" > "$tx_q/xps_cpus" 2>/dev/null || true
    done
fi

# IRQ affinity — распределяем прерывания NIC по CPU round-robin
# (без этого все IRQ попадают на CPU0 = бутылочное горлышко)
# v5.3.0 (fix #12): smp_affinity_list (номер CPU) корректен на 32+ CPU; fallback на hex для <32.
if [ "$CPUS" -gt 1 ]; then
    NIC_IRQS=$(grep -E "(^|[[:space:]])${IFACE}(-|$)" /proc/interrupts 2>/dev/null | awk -F: '{gsub(/ /,"",$1); print $1}')
    if [ -n "$NIC_IRQS" ]; then
        IDX=0
        for irq in $NIC_IRQS; do
            CPU_N=$((IDX % CPUS))
            if [ -w "/proc/irq/$irq/smp_affinity_list" ] && echo "$CPU_N" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null; then
                :
            elif [ "$CPUS" -le 32 ] && [ -w "/proc/irq/$irq/smp_affinity" ]; then
                MASK=$(printf "%x" $((1 << CPU_N)))
                echo "$MASK" > "/proc/irq/$irq/smp_affinity" 2>/dev/null || true
            fi
            IDX=$((IDX + 1))
        done
    fi
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
# ШАГ 7.8: MSS CLAMP (v5.0 — главное лекарство от bottleneck 580-630 юзеров)
# ==============================================================================
#
# Проблема: VPN-нода форвардит трафик клиентов. У части клиентов (мобильные,
# кривые WiFi-роутеры, провайдеры с PPPoE) реальный path MTU < 1500. Без MSS
# clamp:
#   1. Клиент шлёт SYN с MSS=1460 (предполагая MTU 1500).
#   2. Реальный path MTU < 1500.
#   3. TCP-сегмент 1500 байт со флагом DF не пролезает.
#   4. Зависает либо blackhole'ится (Path MTU Discovery часто блокируется ICMP).
#   5. На 600+ юзеров кумулятивная вероятность что хотя бы у части PMTU issues —
#      высокая → клиенты "не подключаются".
#
# tcp_mtu_probing=1 (которое у нас уже есть в ШАГ 7) частично лечит это для
# исходящих пакетов САМОЙ ноды, но НЕ для клиентского TCP при FORWARD'е.
# MSS clamp (`tcp option maxseg size set rt mtu`) — гарантированный fix:
# пересчитывает MSS в SYN на основе реального MTU исходящего интерфейса
# для каждого пакета.
#
# КОГДА реально помогает (подтверждено доками nftables/XTLS, v5.3.2):
#   - egress с УРЕЗАННЫМ MTU: WARP/wgcf (1280/1420), PPPoE, GRE/WG-туннели →
#     clamp не даёт TCP слать сегменты больше пути → нет blackhole/фрагментации.
#   - 5G/GFW часто ломает PMTUD → "бесконечная загрузка"; clamp обходит это.
# На прямом egress с MTU=1500 clamp даёт MSS~1460 (≈дефолт) — практически no-op,
# но безвреден. `rt mtu` с ядра авто-обрабатывает И syn, И syn+ack (оба направления).
# Примечание: клиентский MTU (≈1350) — это конфиг клиента, скрипт его не меняет.
#
# СОВМЕСТИМОСТЬ с shieldnode v3.18.x (исследование nft priorities):
#   shieldnode taблица:    inet ddos_protect
#   shieldnode hooks:
#     prerouting (panel):  priority -150
#     prerouting (alone):  priority -100
#     forward    (panel):  priority -50
#     forward    (alone):  priority filter (=0)
#   crowdsec:              hook prerouting priority -200 (ip/ip6 crowdsec)
#
#   Наша таблица:           inet vpn_node_mss_clamp  (отдельная, не пересекается)
#   Наши hooks:             forward priority -150, output priority -150
#
#   Безопасно: shieldnode НЕ использует priority -150 на forward hook
#   (только на prerouting). Конфликта нет. MSS clamp срабатывает раньше
#   shieldnode-фильтрации — небольшая лишняя работа на пакетах которые
#   потом дропнутся, но нулевой риск рейс-условий.

print_header "ШАГ 7.8: MSS CLAMP (PMTU fix для клиентов с нестандартным MTU)"

# Проверяем shieldnode для информационного сообщения
if v5_shieldnode_detected; then
    print_info "Обнаружен shieldnode — наш MSS clamp использует отдельную таблицу"
    print_info "(inet vpn_node_mss_clamp, priority -150 на forward/output) — без конфликтов"
else
    print_info "shieldnode не обнаружен — MSS clamp применяется как самостоятельный модуль"
fi

# v5.0.4 (fix #9): iptables fallback УДАЛЁН.
# Раньше при отсутствии nft использовался iptables-mangle + сохранение в
# /etc/iptables/rules.v4 через iptables-save. Проблема: iptables-save
# дампит ВСЕ правила (iptables и xtables-translated nft) → файл
# rules.v4 содержит правила UFW и shieldnode → их кто-то воссатновит при
# ребуте через netfilter-persistent → конфликты, потеря UFW rules.
# Безопаснее fail clean чем тихо ломать firewall.
#
# Если на ноде нет nft (старый Debian) — устанавливаем его сейчас.
MSS_BACKEND="none"
NFT_VER=""

if command -v nft >/dev/null 2>&1; then
    NFT_VER=$(v5_nft_version)
    if [ -n "$NFT_VER" ] && v5_ver_ge "$NFT_VER" "1.0"; then
        MSS_BACKEND="nft"
        print_ok "Backend: nftables v$NFT_VER (поддерживает 'tcp option maxseg size set rt mtu')"
    else
        print_warn "nft найден но версия '$NFT_VER' < 1.0 — MSS clamp НЕ применён"
        print_info "Обнови nftables: apt install --only-upgrade nftables"
    fi
fi

if [ "$MSS_BACKEND" = "none" ]; then
    print_error "nftables >= 1.0 не доступен — MSS clamp НЕ применён."
    print_info "Установи: apt install nftables"
    print_warn "Клиенты с PMTU<1500 (мобильные, PPPoE) могут видеть blackhole для крупных пакетов."
    MSS_CLAMP_STATUS="skipped (no nftables)"
else
    # --- Apply MSS clamp ---
    case "$MSS_BACKEND" in
        nft)
            # v5.0.4 (fix #11): atomic transaction для live apply.
            # Раньше: nft delete + nft -f новой версии → окно ~10-100ms без правил
            # в netfilter → на проде с 600 юзеров и keepalive ~24 SYN/сек мог
            # пройти SYN без MSS clamp.
            # Теперь: 'add table {}' → 'delete table' → 'add table {...}'
            # внутри одной nft -f транзакции — kernel применяет атомарно.

            # стdrerr nft сохраняем во временный файл, чтобы при failure
            # юзер увидел РЕАЛЬНУЮ причину (раньше было 2>/dev/null — silent fail).
            NFT_STDERR=$(mktemp /tmp/v5-nft-mss.XXXXXX.err) || NFT_STDERR=/dev/null

            # Применяем правило live atomic.
            if nft -f - 2>"$NFT_STDERR" <<'NFT_MSS_EOF'; then
table inet vpn_node_mss_clamp {}
delete table inet vpn_node_mss_clamp
table inet vpn_node_mss_clamp {
    chain forward {
        type filter hook forward priority -150; policy accept;
        # MSS clamp: pin TCP MSS на каждом SYN под фактический MTU исходящего интерфейса.
        # Лечит blackhole/freeze у клиентов с PMTU<1500 (мобильные, PPPoE, кривые WiFi).
        # ВАЖНО для VPN-ноды при форварде клиентского TCP.
        tcp flags syn tcp option maxseg size set rt mtu comment "v5_mss_clamp_fwd"
    }
    chain output {
        type filter hook output priority -150; policy accept;
        tcp flags syn tcp option maxseg size set rt mtu comment "v5_mss_clamp_out"
    }
}
NFT_MSS_EOF
                rm -f "$NFT_STDERR"
                print_ok "MSS clamp применён live через nft (forward + output, priority -150)"

                # Сохраняем в файл для persistent применения через systemd unit при boot.
                # Не используем /etc/nftables.conf — он может быть управляем дистрибутивом
                # или другим софтом. Своя директория /etc/nftables.d/ + наш systemd unit.
                mkdir -p /etc/nftables.d
                cat > /etc/nftables.d/vpn-node-mss-clamp.conf <<'NFT_MSS_FILE'
#!/usr/sbin/nft -f
# Generated by vpn-node-setup v5.0.4 — MSS clamp для VPN-ноды.
# Лечит проблему "потолка 580-630 юзеров" у клиентов с PMTU<1500.
#
# Совместимо с shieldnode v3.20.5+:
#   - Отдельная таблица (не пересекается с inet ddos_protect)
#   - Priority -150 на forward — shieldnode forward chain удалён в v3.20.5
#   - Priority -150 на output  — стандартно, никакого конфликта
#
# v5.0.4 (fix #11): atomic add-then-delete-then-add чтобы перezагрузка
# (systemctl restart mss-clamp.service) не создавала окно потери MSS clamp.
# Конструкция: 'add table {}' создаёт пустую таблицу если не было (idempotent
# для cold start), 'delete table' удаляет её СО ВСЕМ содержимым (теперь
# точно существует после add), потом ещё раз 'add table' с правилами.
# Всё внутри одной nft -f транзакции — атомарно для kernel.

table inet vpn_node_mss_clamp {}
delete table inet vpn_node_mss_clamp
table inet vpn_node_mss_clamp {
    chain forward {
        type filter hook forward priority -150; policy accept;
        tcp flags syn tcp option maxseg size set rt mtu comment "v5_mss_clamp_fwd"
    }
    chain output {
        type filter hook output priority -150; policy accept;
        tcp flags syn tcp option maxseg size set rt mtu comment "v5_mss_clamp_out"
    }
}
NFT_MSS_FILE
                print_ok "Конфиг сохранён в /etc/nftables.d/vpn-node-mss-clamp.conf"

                # Systemd unit для загрузки правил при boot.
                # Type=oneshot + RemainAfterExit=yes — стандартный паттерн для
                # firewall-юнитов (active-status показывается даже после exec'а).
                cat > /etc/systemd/system/mss-clamp.service <<'UNIT_EOF'
[Unit]
Description=vpn-node-setup v5.0.4 — MSS clamp via nftables
Documentation=https://github.com/abcproxy70-ops/node
After=network-pre.target
Wants=network-pre.target
# Не имеем зависимости от shieldnode — наша таблица отдельная, можем стартовать
# параллельно. Если shieldnode стартует раньше или позже — без разницы.
DefaultDependencies=no
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
# v5.0.4 (fix #11+#19): atomic transaction уже внутри conf-файла,
# не нужна sh -c обёртка с delete+f. ExecStop с префиксом `-` игнорирует
# exit code — если таблицы уже нет (внешний процесс flush'нул), unit не
# уйдёт в failed state.
ExecStart=/usr/sbin/nft -f /etc/nftables.d/vpn-node-mss-clamp.conf
ExecStop=-/usr/sbin/nft delete table inet vpn_node_mss_clamp
ExecReload=/usr/sbin/nft -f /etc/nftables.d/vpn-node-mss-clamp.conf

[Install]
WantedBy=multi-user.target
UNIT_EOF
                systemctl daemon-reload 2>/dev/null || true
                if systemctl enable --now mss-clamp.service >/dev/null 2>&1; then
                    print_ok "Systemd unit mss-clamp.service создан и enabled (persistent после reboot)"
                else
                    print_warn "Не удалось enable mss-clamp.service — правила применены live, но не переживут reboot"
                fi

                MSS_CLAMP_STATUS="active (nft, priority -150)"
            else
                print_error "nft отверг конфиг — возможно эта версия не поддерживает 'rt mtu'"
                print_info "Версия nft: $NFT_VER. Нужна >= 1.0."
                if [ -s "$NFT_STDERR" ]; then
                    print_info "nft stderr:"
                    sed 's/^/    /' "$NFT_STDERR" | head -10
                fi
                rm -f "$NFT_STDERR"
                MSS_BACKEND="iptables"  # сигнал в блок ниже что nft failed
            fi
            ;;
    esac

    # v5.0.4 (fix #9): iptables fallback УДАЛЁН.
    # Если nft live-apply провалился (set MSS_BACKEND="iptables" в catch-блоке выше),
    # просто рапортуем failure. Раньше тут был iptables-mangle + iptables-save в
    # /etc/iptables/rules.v4 — это перезаписывало правила UFW и shieldnode.
    if [ "$MSS_BACKEND" = "iptables" ]; then
        print_error "nft live-apply провалился ранее, iptables fallback УДАЛЁН в v5.0.4."
        print_info "Проверь NFT_STDERR-логи выше — почему nft не принял правила."
        print_info "Возможные причины: nft < 1.0, kernel < 5.6 без maxseg support."
        MSS_CLAMP_STATUS="failed (nft apply failed; no iptables fallback)"
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

# v4.13: сохраняем текущий запущенный скрипт как "установленный" — для
# поддержки `--upgrade` и `--rollback`. Это безопасно: $SCRIPT_STATE_DIR
# принадлежит root, права 0644.
mkdir -p "$SCRIPT_STATE_DIR"
if [ -f "${BASH_SOURCE[0]}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
    cp -a "${BASH_SOURCE[0]}" "$SCRIPT_INSTALLED_PATH" 2>/dev/null
    echo "$SCRIPT_VERSION" > "$SCRIPT_VERSION_FILE"
    chmod 0644 "$SCRIPT_INSTALLED_PATH" "$SCRIPT_VERSION_FILE" 2>/dev/null
fi

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
echo -e "  │ Ядро (пакет)           │ ${GREEN}${KERNEL_PKG:-не выбран}${NC}"
echo -e "  │ Ветка ядра             │ ${GREEN}${KERNEL_BRANCH:-unknown}${NC}"
echo -e "  │ Reboot нужен           │ ${GREEN}${REBOOT_NEEDED:-unknown}${NC}"
echo -e "  │ MAIN xanmod (старый)   │ ${YELLOW}${MAIN_PKG_FOUND:-нет, чисто}${NC}"
echo -e "  │ CPU Level              │ ${GREEN}x86-64-v${CPU_LEVEL}${NC}                           │"
echo -e "  │ Профиль памяти         │ ${PROFILE_COLOR}$PROFILE_NAME${NC}                │"
echo -e "  │ RAM                    │ ${GREEN}${TOTAL_MEM_MB} MB${NC}                            │"
echo -e "  │ Лимит nofile           │ ${GREEN}$LIMIT_COUNT${NC}                          │"
echo -e "  │ TCP Congestion         │ ${GREEN}BBRv3${NC}                               │"
echo -e "  │ Qdisc                  │ ${GREEN}${QDISC_MODE:-fq}${NC}                     │"
echo -e "  │ RPS                    │ ${GREEN}${RPS_MODE:-disabled}${NC}                 │"
echo -e "  │ NIC Boosts             │ ${GREEN}${NIC_BOOSTS_SUMMARY:-none}${NC}            │"
echo -e "  │ IRQ Affinity           │ ${GREEN}${IRQ_AFFINITY_MODE:-skipped}${NC}         │"
echo -e "  │ MSS clamp              │ ${GREEN}${MSS_CLAMP_STATUS:-skipped}${NC}      │"
echo -e "  │ Conntrack max          │ ${GREEN}${CONNTRACK_MAX:-?} (${CONNTRACK_TIER:-?})${NC}      │"
echo -e "  │ IPv6                   │ ${GREEN}отключён через sysctl${NC}              │"
echo -e "  └─────────────────────────────────────────────────────────────────┘"
echo ""

echo -e "  ${BOLD}Что было сделано:${NC}"
echo -e "  ├─ ${GREEN}✔${NC} Бэкап старых конфигов: ${CYAN}${BACKUP_DIR}${NC}"
echo -e "  ├─ ${GREEN}✔${NC} Удалены apport, whoopsie, ubuntu-report, popularity-contest"
echo -e "  ├─ ${GREEN}✔${NC} cloud-init и snapd НЕ тронуты (защита SSH-ключей)"
echo -e "  ├─ ${GREEN}✔${NC} Отключены ModemManager, fwupd, udisks2, multipathd, unattended-upgrades"
echo -e "  ├─ ${GREEN}✔${NC} Ограничены логи journald (100MB)"
case "$KERNEL_BRANCH" in
    "LTS-fresh-install")
        echo -e "  ├─ ${GREEN}✔${NC} Установлено ядро XanMod LTS с BBRv3 (старое ядро как fallback)"
        ;;
    "LTS-installed-MAIN-still-present")
        echo -e "  ├─ ${GREEN}✔${NC} Установлено ядро XanMod LTS параллельно с MAIN (см. notes ниже)"
        ;;
    "LTS-already-active")
        echo -e "  ├─ ${GREEN}✔${NC} XanMod LTS уже активен — установка пропущена (idempotency)"
        ;;
    "LTS-active-via-MAIN-metapackage")
        echo -e "  ├─ ${GREEN}✔${NC} Ядро LTS-ветки активно через MAIN-метапакет — установка пропущена"
        ;;
    "LTS-installed-MAIN-running-repin-grub")
        echo -e "  ├─ ${YELLOW}↻${NC} GRUB перепинён на LTS — после reboot будет активен LTS"
        ;;
    "skipped-dry-run")
        echo -e "  ├─ ${MAGENTA}ℹ${NC} [DRY-RUN] Установка ядра не выполнялась"
        ;;
    *)
        echo -e "  ├─ ${YELLOW}?${NC} Состояние ядра: $KERNEL_BRANCH"
        ;;
esac
echo -e "  ├─ ${GREEN}✔${NC} IPv6 отключён через sysctl (модуль остался, трафик не работает)"
echo -e "  ├─ ${GREEN}✔${NC} Настроен conntrack ($CONNTRACK_MAX max, короткие таймауты, $CONNTRACK_TIER)"
echo -e "  ├─ ${GREEN}✔${NC} Оптимизирован сетевой стек (tw_reuse, MTU probing, notsent_lowat)"
echo -e "  ├─ ${MAGENTA}ℹ${NC} Security hardening (rp_filter, syncookies, redirects) — owned by shieldnode"
echo -e "  ├─ ${GREEN}✔${NC} Настроены лимиты (nofile $LIMIT_COUNT)"
echo -e "  ├─ ${GREEN}✔${NC} Qdisc + RPS настроены под топологию железа"
echo -e "  ├─ ${GREEN}✔${NC} NIC бусты: GRO flush, XPS, offloads, ring buffers"
echo -e "  ├─ ${GREEN}✔${NC} IRQ affinity распределён по CPU (round-robin)"
echo -e "  └─ ${GREEN}✔${NC} Inotify limits увеличены (для 10k+ соединений)"
echo ""
echo -e "  ${BOLD}Что НЕ было тронуто (минимизация рисков v4.10):${NC}"
echo -e "  ├─ ${MAGENTA}✗${NC} netplan (никаких accept-ra, link-local, новых файлов)"
echo -e "  ├─ ${MAGENTA}✗${NC} cloud-init (защита SSH-ключей)"
echo -e "  ├─ ${MAGENTA}✗${NC} GRUB cmdline (никаких ipv6.disable=1, etc)"
echo -e "  ├─ ${MAGENTA}✗${NC} systemd-networkd-wait-online (никаких override)"
echo -e "  ├─ ${MAGENTA}✗${NC} /etc/network/interfaces, ifupdown"
echo -e "  ├─ ${MAGENTA}✗${NC} /etc/fstab (только warning при дублях)"
echo -e "  └─ ${MAGENTA}✗${NC} UFW правила (только warning об активности)"
echo ""

echo -e "  ${BOLD}Файлы конфигурации:${NC}"
echo -e "  ├─ ${CYAN}/etc/sysctl.d/80-vpn-node-tuning.conf${NC} (консолидированный, v5.1.0)"
echo -e "  ├─ ${CYAN}/etc/sysctl.d/99-disable-ipv6.conf${NC}"
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

# v4.12: вывод reboot-блока зависит от состояния установки
if [ "$REBOOT_NEEDED" = "yes" ]; then
    echo -e "  ${YELLOW}⚠️  ВАЖНО: Для активации ядра XanMod LTS требуется перезагрузка!${NC}"
    echo ""

    echo -e "${RED}"
    echo "  ╔═══════════════════════════════════════════════════════════════════╗"
    echo "  ║                     🔄 ТРЕБУЕТСЯ REBOOT                           ║"
    echo "  ╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
elif [ "$KERNEL_BRANCH" = "LTS-already-active" ]; then
    echo -e "  ${GREEN}✓ XanMod LTS уже активен — reboot не требуется.${NC}"
    echo ""
elif [ "$KERNEL_BRANCH" = "LTS-active-via-MAIN-metapackage" ]; then
    echo -e "  ${GREEN}✓ Kernel LTS-ветки активен — reboot не требуется.${NC}"
    echo -e "  ${YELLOW}ℹ Метапакет MAIN ($KERNEL_PKG), но текущее ядро — LTS-версия.${NC}"
    echo -e "  ${YELLOW}  Для переключения метапакета на LTS (рекомендуется):${NC}"
    echo -e "  ${CYAN}    apt-get install -y $LTS_PKG_PREFERRED${NC}"
    echo -e "  ${CYAN}    apt-get purge -y $KERNEL_PKG${NC}"
    echo ""
elif [ "$KERNEL_BRANCH" = "skipped-dry-run" ]; then
    echo -e "  ${MAGENTA}ℹ DRY-RUN: ядро не устанавливалось. Reboot не нужен.${NC}"
    echo -e "  ${MAGENTA}  Чтобы выполнить установку — запусти скрипт без --dry-run.${NC}"
    echo ""
fi

# v4.12: пост-инструкция для случая параллельного MAIN+LTS
if [ "$KERNEL_BRANCH" = "LTS-installed-MAIN-still-present" ] && [ -n "$MAIN_PKG_FOUND" ]; then
    echo -e "  ${YELLOW}⚠️  ПОСЛЕ УСПЕШНОГО reboot на LTS — УБЕРИТЕ старый MAIN xanmod:${NC}"
    echo -e "  ${CYAN}  uname -r${NC}        # убедитесь, что в имени есть '-lts-'"
    echo -e "  ${CYAN}  apt-get purge $MAIN_PKG_FOUND${NC}"
    echo -e "  ${CYAN}  # затем удалите осиротевшие linux-image без -lts-:${NC}"
    echo -e "  ${CYAN}  dpkg -l | awk '/^ii/ && \$2 ~ /linux-image-.*xanmod/ && \$2 !~ /-lts-/{print \$2}' | xargs -r apt-get purge -y${NC}"
    echo -e "  ${CYAN}  apt-get autoremove --purge${NC}"
    echo ""
fi

echo -e "  ${BOLD}После перезагрузки проверьте:${NC}"
echo -e "  ${CYAN}uname -r${NC}                                    # Должно содержать 'lts' и 'xanmod' (напр. 6.18.27-x64v3-xanmod1)"
echo -e "  ${CYAN}sysctl net.ipv4.tcp_congestion_control${NC}      # Должно быть bbr"
echo -e "  ${CYAN}sysctl net.core.default_qdisc${NC}               # Должно быть fq"
echo -e "  ${CYAN}tc qdisc show dev \$(ip route|awk '/default/{print \$5;exit}')${NC}  # mq+fq или fq"
echo -e "  ${CYAN}cat /sys/class/net/\$(ip route|awk '/default/{print \$5;exit}')/queues/rx-0/rps_cpus${NC}  # RPS mask"
echo -e "  ${CYAN}sysctl net.netfilter.nf_conntrack_max${NC}       # Должно быть $CONNTRACK_MAX ($CONNTRACK_TIER)"
echo -e "  ${CYAN}cat /proc/sys/net/ipv4/tcp_tw_reuse${NC}         # Должно быть 1"
echo -e "  ${CYAN}sysctl net.ipv6.conf.all.disable_ipv6${NC}       # Должно быть 1"
echo -e "  ${CYAN}grep \$(ip route|awk '/default/{print \$5;exit}') /proc/interrupts | head -5${NC}  # IRQ распределение"
echo -e "  ${CYAN}cat /proc/sys/fs/inotify/max_user_watches${NC}   # Должно быть 524288"
echo -e "  ${CYAN}systemctl --failed${NC}                          # Не должно быть failed-сервисов"
echo ""

# v4.13: подсказка про self-upgrade
# v5.0 BUGFIX: используем installed.sh (стабильный путь после optimize), не $0.
# После любого optimize'а installed.sh уже сохранён (см. блок ниже finalize).
echo -e "  ${BOLD}Управление версией:${NC}"
echo -e "  ${CYAN}sudo bash $SCRIPT_INSTALLED_PATH --check${NC}                        # Проверить новую версию на github"
echo -e "  ${CYAN}sudo bash $SCRIPT_INSTALLED_PATH --upgrade${NC}                      # Безопасный upgrade (snapshot + rollback support)"
echo -e "  ${CYAN}sudo bash $SCRIPT_INSTALLED_PATH --rollback${NC}                     # Откатиться к предыдущей версии"
echo ""

# v5.3.3 (fix #A1): юзер оставил авто-апдейты — возвращаем таймеры,
# остановленные в ШАГ 1.5 (иначе до ребута апдейтов не было бы).
if [ "${RESTART_APT_TIMERS:-0}" = "1" ]; then
    systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    print_ok "apt-таймеры запущены обратно (SETUP_DISABLE_UNATTENDED=0)"
fi

# v4.12: prompt о перезагрузке только если она реально нужна
if [ "$REBOOT_NEEDED" = "yes" ]; then
    # v5.3.0 (fix #6): если нас запустил --upgrade родитель (SETUP_NO_REBOOT=1) —
    # НЕ перезагружаемся сами (иначе убьём родителя до promote installed.sh).
    # Оставляем сигнал-файл, reboot предложит родитель после promote.
    if [ "${SETUP_NO_REBOOT:-0}" = "1" ]; then
        mkdir -p "$SCRIPT_STATE_DIR" 2>/dev/null
        : > "$SCRIPT_STATE_DIR/.reboot-needed" 2>/dev/null
        echo -e "  ${YELLOW}Ядро установлено. Reboot выполнит upgrade-обёртка после завершения.${NC}"
        echo ""
    elif [ -t 0 ]; then
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
    else
        # non-TTY (CI/ansible): не ребутим автоматически, только сообщаем.
        echo ""
        echo -e "  ${YELLOW}Требуется reboot для активации ядра (non-TTY — авто-reboot пропущен).${NC}"
        echo -e "  ${CYAN}sudo reboot${NC}"
        echo ""
    fi
else
    echo -e "  ${GREEN}Reboot не требуется. Скрипт завершён.${NC}"
    echo ""
fi

# ==============================================================================
# SIGNING RELEASES (v5.3.0, fix #5) — как включить проверку подписи апдейтов
# ==============================================================================
# По умолчанию проверка ВЫКЛючена (SETUP_REQUIRE_SIG=0) — апгрейды работают как
# раньше (только структурные sanity-checks). Чтобы защититься от компрометации
# GitHub-репозитория / MITM (запуск чужого кода от root), включи detached-подпись.
#
# Вариант A — minisign (проще, рекомендуется):
#   1) Один раз сгенерируй ключ:        minisign -G
#   2) При каждом релизе подписывай:    minisign -S -m vpn-node-setup.sh
#      (создаёт vpn-node-setup.sh.minisig — клади его рядом в репо)
#   3) На нодах запускай с публичным ключом:
#        SETUP_REQUIRE_SIG=1 \
#        SETUP_MINISIGN_PUBKEY="RWQ....(твой публичный ключ из minisign.pub)" \
#        sudo bash installed.sh --upgrade
#
# Вариант B — GPG:
#   1) Один раз:     gpg --full-generate-key   (узнай fingerprint: gpg -K --fingerprint)
#   2) Каждый релиз: gpg --armor --detach-sign vpn-node-setup.sh
#      (создаёт vpn-node-setup.sh.asc — клади рядом в репо)
#   3) На нодах:
#        SETUP_REQUIRE_SIG=1 \
#        SETUP_SIG_FINGERPRINT="ПОЛНЫЙ_ОТПЕЧАТОК_БЕЗ_ПРОБЕЛОВ" \
#        sudo bash installed.sh --upgrade
#      (публичный ключ должен быть импортирован: gpg --import pub.asc)
#
# Те же переменные действуют и на node-diagnostic (--diagnose): чтобы он проходил
# проверку, ты должен зеркалить node-diagnostic у себя и класть .asc/.minisig рядом
# (NODE_DIAG_URL переопредели на своё зеркало). Иначе — оставь проверку выключенной
# для диагностики и полагайся на встроенные sanity-checks.
#
# ПРОЩЕ ВСЕГО: пропиши эти переменные в /etc/environment или в ansible-окружение,
# чтобы все ноды апгрейдились только с валидной подписью.
# ==============================================================================
