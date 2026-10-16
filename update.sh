#!/bin/sh

# --- НАСТРОЙКИ ---
# Здесь можно указать:
# - raw-ссылки на подписки
# - прямые ссылки вида vless://, ss://, trojan://, socks5://, hy2://
SOURCE_1=""
SOURCE_2=""
SOURCE_3=""

# Сколько максимум ключей класть в Podkop
LIMIT=27

# Секция Podkop, в которую пишутся ключи
SECTION="main"

# Сколько секунд ждать запуска sing-box после рестарта Podkop
RESTART_TIMEOUT=120
# -----------------

# Где лежат библиотеки Podkop (переопределяется только для тестов)
PODKOP_LIB="${PODKOP_LIB:-/usr/lib/podkop}"
PODKOP_CONFIG="${PODKOP_CONFIG:-/etc/config/podkop}"

log() { echo "[$(date '+%F %T')] $*" >&2; }

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

TAB="$(printf '\t')"
ESC="$(printf '\033')"

# Ищем в тексте ссылки на поддерживаемые протоколы
PATTERN='(vless|ss|trojan|socks|socks4|socks4a|socks5|hysteria2|hy2)://[^"'"'"' <>]+'

# --- НОРМАЛИЗАЦИЯ ИМЕНИ ---
# Убираем мусор из названия, но флаги и emoji не трогаем
clean_name() {
    printf '%s' "$1" | \
    sed 's/%20/ /g' | \
    sed 's/[[:cntrl:]]//g' | \
    sed 's/["\\`]/_/g' | \
    sed 's/[?#&]/_/g' | \
    sed 's/[|,]/_/g' | \
    sed 's/[[:space:]][[:space:]]*/_/g'
}

# --- СКАЧИВАНИЕ ---
# Загружает сырой текст/HTML/подписку и при необходимости декодирует base64
download_content() {
    raw=$(wget --no-check-certificate --user-agent="v2rayNG/1.8.5" -qO- "$1" 2>/dev/null)
    [ -n "$raw" ] || return 1

    # Ссылки уже видны — это текст или HTML
    case "$raw" in
        *://*) printf '%s' "$raw"; return 0 ;;
    esac

    # Иначе пробуем base64 (в т.ч. url-safe и без паддинга)
    b64=$(printf '%s' "$raw" | tr -d ' \r\n' | tr '_-' '/+')
    case $((${#b64} % 4)) in
        2) b64="${b64}==" ;;
        3) b64="${b64}=" ;;
    esac
    decoded=$(printf '%s' "$b64" | base64 -d 2>/dev/null)
    case "$decoded" in
        *://*) printf '%s' "$decoded" ;;
        *) printf '%s' "$raw" ;;
    esac
}

# socks:// (формат v2rayN) Podkop не понимает — переводим в socks5://
fix_socks() {
    rest="${1#socks://}"
    case "$rest" in
        *@*)
            userinfo="${rest%%@*}"
            case "$userinfo" in
                *:*) ;;
                *)
                    decoded=$(printf '%s' "$userinfo" | base64 -d 2>/dev/null)
                    case "$decoded" in
                        *:*) userinfo="$decoded" ;;
                    esac
                    ;;
            esac
            printf 'socks5://%s@%s' "$userinfo" "${rest#*@}"
            ;;
        *) printf 'socks5://%s' "$rest" ;;
    esac
}

# --- НОРМАЛИЗАЦИЯ ССЫЛКИ ---
# Только чистка мусора. Параметры ключа не трогаем:
# годен ли ключ, решает sing-box (см. ПРОВЕРКА)
normalize_link() {
    # Убираем мусор, чистим HTML-экранирование и пробелы по краям
    link=$(printf '%s' "$1" | tr -cd '\40-\176' | \
       sed 's/&amp;/\&/g; s/^[[:space:]]*//; s/[[:space:]]*$//')

    case "$link" in
        socks://*) link=$(fix_socks "$link") ;;
    esac

    case "$link" in
        vless://*|ss://*|trojan://*|socks4://*|socks4a://*|socks5://*|hysteria2://*|hy2://*) ;;
        *) return 1 ;;
    esac

    # Разделяем ссылку и имя после #
    base="${link%%#*}"
    name=""
    [ "$base" != "$link" ] && name="${link#*#}"

    # Выкидываем обрезанные ключи (query заканчивается на & или =)
    case "$base" in
        *\?*=|*\?*'&') return 1 ;;
    esac

    # sing-box не пускает reality без uTLS, а многие подписки fp не пишут.
    # Подставляем chrome, как это делают клиенты (и Forkop)
    case "$base" in
        *[?\&]security=reality*)
            case "$base" in
                *[?\&]fp=?*) ;;
                *) base="${base}&fp=chrome" ;;
            esac
            ;;
    esac

    # Без type Podkop собирает обычный tcp, но пишет в лог красное
    # "Unknown transport ''". Указываем tcp явно
    case "$base" in
        vless://*|trojan://*)
            case "$base" in
                *[?\&]type=?*) ;;
                *\?*) base="${base}&type=tcp" ;;
                *) base="${base}?type=tcp" ;;
            esac
            ;;
    esac

    [ -n "$name" ] && base="${base}#$(clean_name "$name")"

    # Podkop читает список ключей через for link in $list:
    # пробел внутри ссылки разрежет её на куски и уронит запуск
    case "$base" in
        *[[:space:]]*) return 1 ;;
    esac

    printf '%s\n' "$base"
}

# Имя ключа для логов: то, что после #, иначе host:port
link_title() {
    case "$1" in
        *#?*) printf '%s' "${1#*#}" ;;
        *) printf '%s' "$1" | sed -E 's#^[a-z0-9]+://([^@]*@)?([^/?#]*).*#\2#' ;;
    esac
}

# --- СБОР ---
# Если источник — прямая ссылка, кладём её в приоритет
# Если источник — подписка/страница, скачиваем и парсим из неё все ключи
collect() {
    input="$1"
    num="$2"

    [ -n "$input" ] || return

    case "$input" in
        *://*)
            case "$input" in
                http://*|https://*) ;;
                *)
                    norm=$(normalize_link "$input") || {
                        log "⚠️  Ссылка $num: прямой ключ отброшен"
                        return
                    }
                    log "✅ Ссылка $num: добавлен прямой ключ (приоритет)"
                    printf '%s\n' "$norm" >> "$WORK/priority"
                    return
                    ;;
            esac
            ;;
    esac

    log "📡 Ссылка $num: загрузка..."
    content=$(download_content "$input") || {
        log "❌ Ссылка $num: ошибка загрузки"
        return
    }

    # Считаем найденные ключи до фильтрации
    count=$(printf '%s\n' "$content" | grep -oE "$PATTERN" | wc -l | tr -d ' ')
    log "✅ Ссылка $num: найдено ключей: $count"

    printf '%s\n' "$content" | grep -oE "$PATTERN" | while read -r link; do
        norm=$(normalize_link "$link") || continue
        printf '%s\n' "$norm" >> "$WORK/pool"
    done
}

# --- ПРОВЕРКА ---
# Каждый ключ превращается в outbound тем же кодом Podkop, который потом
# соберёт итоговый конфиг, и проверяется установленным sing-box.

validation_available() {
    command -v sing-box >/dev/null 2>&1 || { log "⚠️  sing-box не найден"; return 1; }
    command -v jq >/dev/null 2>&1 || { log "⚠️  jq не найден"; return 1; }
    [ -r "$PODKOP_LIB/sing_box_config_facade.sh" ] || {
        log "⚠️  Не найдены библиотеки Podkop в $PODKOP_LIB"
        return 1
    }
    (
        . "$PODKOP_LIB/constants.sh"
        . "$PODKOP_LIB/sing_box_config_facade.sh"
        command -v sing_box_cf_add_proxy_outbound >/dev/null 2>&1
    ) 2>/dev/null || {
        log "⚠️  В этой версии Podkop нет sing_box_cf_add_proxy_outbound"
        return 1
    }
}

# Строит outbound для каждой строки "id<TAB>ссылка" из $1.
# Удачные пишет в $2 как "id<TAB>json", неудачные в $3 как "id<TAB>причина"
build_outbounds() {
    (
        . "$PODKOP_LIB/constants.sh"
        [ -r "$PODKOP_LIB/logging.sh" ] && . "$PODKOP_LIB/logging.sh"
        . "$PODKOP_LIB/sing_box_config_facade.sh"
        # Podkop пишет ошибки через log ... "fatal" — перехватываем их как причину
        log() { [ "$2" = "fatal" ] && printf '%s\n' "$1" >&2; return 0; }

        while IFS="$TAB" read -r id link <&3; do
            out=$(sing_box_cf_add_proxy_outbound '{"outbounds":[]}' "pu$id" "$link" "$UDP_OVER_TCP" 2>"$WORK/build.err")
            outbound=$(printf '%s' "$out" | jq -ce '.outbounds[0] // empty' 2>/dev/null)
            if [ -n "$outbound" ]; then
                printf '%s\t%s\n' "$id" "$outbound" >> "$2"
            else
                reason=$(head -n 1 "$WORK/build.err")
                printf '%s\t%s\n' "$id" "${reason:-Podkop не смог разобрать ссылку}" >> "$3"
            fi
        done 3< "$1"
    )
}

# Проверяет набор outbound'ов (файл "id<TAB>json") одним sing-box check
check_outbounds() {
    cut -f2- "$1" | jq -sc '{log: {disabled: true}, outbounds: .}' > "$WORK/check.json" 2>/dev/null || {
        CHECK_ERR="не удалось собрать JSON"
        return 1
    }
    CHECK_ERR=$(sing-box check -c "$WORK/check.json" 2>&1) && return 0
    CHECK_ERR=$(printf '%s\n' "$CHECK_ERR" | sed "s/${ESC}\[[0-9;]*m//g" | \
        grep -m 1 -iE 'fatal|panic|error' | \
        sed 's/^.*FATAL\[[0-9]*\] //; s/^initialize outbound\[[0-9]*\]: //; s/^decode config at [^:]*: //')
    return 1
}

# Деление пополам: чистый набор стоит одну проверку, плохие ключи
# изолируются рекурсивно (группы до 4 штук проверяются по одному)
PART=0
validate_file() {
    local file="$1" n size i part
    n=$(wc -l < "$file" | tr -d ' ')
    [ "$n" -gt 0 ] || return 0

    if check_outbounds "$file"; then
        cat "$file" >> "$WORK/good"
        return 0
    fi

    if [ "$n" -eq 1 ]; then
        printf '%s\t%s\n' "$(cut -f1 "$file")" "${CHECK_ERR:-sing-box check не прошёл}" >> "$WORK/rejected"
        return 0
    fi

    if [ "$n" -le 4 ]; then
        size=1
    else
        size=$(( (n + 1) / 2 ))
    fi

    i=1
    while [ "$i" -le "$n" ]; do
        PART=$((PART + 1))
        part="$WORK/part.$PART"
        sed -n "${i},$((i + size - 1))p" "$file" > "$part"
        validate_file "$part"
        i=$((i + size))
    done
}

# --- ПРИМЕНЕНИЕ ---
singbox_is_up() {
    elapsed=0
    while [ "$elapsed" -lt "$RESTART_TIMEOUT" ]; do
        if pidof sing-box >/dev/null 2>&1; then
            # sing-box должен не просто стартовать, а остаться жив
            sleep 5
            pidof sing-box >/dev/null 2>&1 && return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    return 1
}

# ==================== СТАРТ ====================
: > "$WORK/priority"
: > "$WORK/pool"

log "📥 Сбор ключей..."
collect "$SOURCE_1" "1"
collect "$SOURCE_2" "2"
collect "$SOURCE_3" "3"

# Кандидаты: сначала прямые ключи, затем пул в случайном порядке, без дублей
sort -u "$WORK/pool" | awk 'BEGIN{srand()} {print rand() "\t" $0}' | sort -n | cut -f2- > "$WORK/pool.rnd"
cat "$WORK/priority" "$WORK/pool.rnd" | awk 'NF && !seen[$0]++' > "$WORK/candidates"
CANDIDATES=$(wc -l < "$WORK/candidates" | tr -d ' ')
PRIORITY_COUNT=$(awk 'NF' "$WORK/priority" | sort -u | wc -l | tr -d ' ')

if [ "$CANDIDATES" -eq 0 ]; then
    log "❌ Нет ключей — ничего не меняем"
    exit 0
fi

: > "$WORK/good"
: > "$WORK/rejected"

if validation_available; then
    UDP_OVER_TCP=$(uci -q get "podkop.$SECTION.enable_udp_over_tcp")
    log "🔍 Проверка ключей через Podkop + sing-box (кандидатов: $CANDIDATES, нужно: $LIMIT)..."

    # Берём кандидатов порциями, пока не наберём LIMIT рабочих
    pos=1
    accepted=0
    while [ "$accepted" -lt "$LIMIT" ] && [ "$pos" -le "$CANDIDATES" ]; do
        need=$((LIMIT - accepted))
        awk -v a="$pos" -v b="$((pos + need - 1))" 'NR >= a && NR <= b {print NR "\t" $0}' \
            "$WORK/candidates" > "$WORK/batch"
        : > "$WORK/built"
        build_outbounds "$WORK/batch" "$WORK/built" "$WORK/rejected"
        validate_file "$WORK/built"
        accepted=$(wc -l < "$WORK/good" | tr -d ' ')
        pos=$((pos + need))
    done

    # Пишем в лог, что и почему отброшено
    sort -n "$WORK/rejected" | while IFS="$TAB" read -r id reason; do
        link=$(sed -n "${id}p" "$WORK/candidates")
        if [ "$id" -le "$PRIORITY_COUNT" ]; then
            log "⚠️  Прямой ключ отброшен: $(link_title "$link") — $reason"
        else
            log "⛔ Отброшен: $(link_title "$link") — $reason"
        fi
    done

    # Финальная проверка всего набора вместе
    if [ -s "$WORK/good" ] && ! check_outbounds "$WORK/good"; then
        log "❌ Итоговый набор не прошёл sing-box check ($CHECK_ERR) — ничего не меняем"
        exit 1
    fi

    cut -f1 "$WORK/good" | sort -n | head -n "$LIMIT" | while read -r id; do
        sed -n "${id}p" "$WORK/candidates"
    done > "$WORK/final"
else
    log "⚠️  Проверка через sing-box недоступна — ключи пойдут без проверки, защищает только откат"
    head -n "$LIMIT" "$WORK/candidates" > "$WORK/final"
fi

TOTAL=$(wc -l < "$WORK/final" | tr -d ' ')
REJECTED=$(wc -l < "$WORK/rejected" | tr -d ' ')

# Если ничего не осталось — ничего не меняем
if [ "$TOTAL" -eq 0 ]; then
    log "❌ Нет рабочих ключей (отброшено: $REJECTED) — ничего не меняем"
    exit 0
fi

log "✨ Готово! Выбрано $TOTAL серверов (отброшено: $REJECTED)"

# Если список не изменился — не перезапускаем
# (порядок не важен — его всё равно перемешивает случайная выборка)
OLD_LINKS=$(uci -q get "podkop.$SECTION.urltest_proxy_links" | tr ' ' '\n' | sort)
NEW_LINKS=$(sort "$WORK/final")
if [ "$OLD_LINKS" = "$NEW_LINKS" ]; then
    log "👌 Список ключей не изменился — перезапуск не нужен"
    exit 0
fi

# --- UCI ---
# Сохраняем рабочий конфиг для отката
cp "$PODKOP_CONFIG" "$WORK/podkop.backup" || {
    log "❌ Не удалось сохранить резервную копию $PODKOP_CONFIG — ничего не меняем"
    exit 1
}

uci -q delete "podkop.$SECTION.urltest_proxy_links"
log "🧹 Старые ключи удалены из конфига"

log "⚙️  Настройка Podkop: включение URLTest и запись ключей..."
uci set "podkop.$SECTION.connection_type=proxy"
uci set "podkop.$SECTION.proxy_config_type=urltest"
uci set "podkop.$SECTION.urltest_check_interval=1m"
uci set "podkop.$SECTION.urltest_tolerance=150"
uci set "podkop.$SECTION.urltest_testing_url=https://cp.cloudflare.com/generate_204"

while read -r link; do
    [ -n "$link" ] && uci add_list "podkop.$SECTION.urltest_proxy_links=$link"
done < "$WORK/final"

uci commit podkop

log "🔄 Перезапуск сервиса..."
/etc/init.d/podkop restart

if singbox_is_up; then
    log "🚀 Обновление успешно завершено! Записано серверов: $TOTAL"
    exit 0
fi

# --- ОТКАТ ---
log "💥 sing-box не запустился за ${RESTART_TIMEOUT}с — возвращаю прежний конфиг"
log "   Подробности: logread -e podkop | tail -n 30"
cp "$WORK/podkop.backup" "$PODKOP_CONFIG"
/etc/init.d/podkop restart

if singbox_is_up; then
    log "↩️  Откат выполнен, Podkop работает на прежних ключах"
else
    log "❌ После отката sing-box тоже не запустился — проверьте Podkop вручную"
fi
exit 1
