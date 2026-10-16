#!/bin/sh
# Песочница: гоняет update.sh и подписки на компьютере, без роутера.
#
# Берёт настоящие библиотеки Podkop (нужной версии) и настоящий sing-box,
# а uci, pidof и рестарт Podkop подменяет заглушками. «Рестарт» собирает
# outbound'ы тем же кодом Podkop и делает sing-box check, как при старте на
# роутере, поэтому битый ключ роняет его так же, как настоящий Podkop.
#
# Использование:
#   tests/sandbox.sh links <url|файл>...   проверить каждый ключ по отдельности
#   tests/sandbox.sh run <url|ключ>...     прогнать update.sh целиком (до 3 источников)
#   tests/sandbox.sh podkop <url|файл>     скормить ВСЕ ключи «Podkop» без фильтра,
#                                          как будто их вписали руками
#
# Переменные окружения:
#   PODKOP_VERSION  тег релиза Podkop (по умолчанию последний)
#   SINGBOX_VERSION тег релиза sing-box (по умолчанию последний)
#   SINGBOX_BIN     свой бинарник sing-box вместо скачивания (например, extended)
#   LIMIT           сколько ключей отбирает update.sh (по умолчанию как в скрипте)
#   BREAK_RESTART=1 первый рестарт «падает», чтобы проверить откат
#   SEED_LINKS      файл с ключами, которые уже «стоят» в Podkop до запуска run
#   SANDBOX_SHELL   чем запускать update.sh (по умолчанию sh)
#   SANDBOX_CACHE   куда складывать скачанное (по умолчанию .sandbox/ в репозитории)
#
# Ближе всего к роутеру — busybox ash, его можно взять из alpine:
#   docker run --rm -v "$PWD":/w -w /w -e SANDBOX_CACHE=/tmp/sb alpine:3.20 \
#       sh -c 'apk add -q curl jq && tests/sandbox.sh run <url>'
# (dash не подходит: библиотеки Podkop используют [[ ]], который есть в ash)

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${SANDBOX_CACHE:-$ROOT/.sandbox}"
mkdir -p "$CACHE"

die() { echo "sandbox: $*" >&2; exit 1; }

# Через редирект releases/latest: у API GitHub лимит 60 запросов в час
latest_tag() {
    curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed 's#.*/tag/##'
}

# --- Podkop ---
PODKOP_VERSION="${PODKOP_VERSION:-$(latest_tag itdoginfo/podkop)}"
case "$PODKOP_VERSION" in ""|*/*) die "не удалось узнать версию Podkop" ;; esac
: || "не удалось узнать версию Podkop"
LIB="$CACHE/podkop-$PODKOP_VERSION/lib"
if [ ! -r "$LIB/sing_box_config_facade.sh" ]; then
    echo "📦 Скачиваю Podkop $PODKOP_VERSION..." >&2
    tmp="$CACHE/podkop-$PODKOP_VERSION.tar.gz"
    curl -fsSL -o "$tmp" "https://github.com/itdoginfo/podkop/archive/refs/tags/$PODKOP_VERSION.tar.gz"
    mkdir -p "$CACHE/podkop-$PODKOP_VERSION/src"
    tar xzf "$tmp" -C "$CACHE/podkop-$PODKOP_VERSION/src" --strip-components 1
    rm -f "$tmp"
    mkdir -p "$LIB"
    cp "$CACHE/podkop-$PODKOP_VERSION/src/podkop/files/usr/lib/"*.sh "$LIB/"
    # Библиотеки подключают друг друга по жёсткому пути /usr/lib/podkop
    for f in "$LIB"/*.sh; do
        sed -i.bak "s#/usr/lib/podkop#$LIB#g" "$f" && rm -f "$f.bak"
    done
fi

# --- sing-box ---
if [ -n "${SINGBOX_BIN:-}" ]; then
    SB="$SINGBOX_BIN"
else
    SINGBOX_VERSION="${SINGBOX_VERSION:-$(latest_tag SagerNet/sing-box)}"
    os=$(uname -s | tr 'A-Z' 'a-z')
    case "$(uname -m)" in
        arm64|aarch64) arch=arm64 ;;
        x86_64|amd64) arch=amd64 ;;
        *) die "неизвестная архитектура $(uname -m), укажите SINGBOX_BIN" ;;
    esac
    # alpine/OpenWrt живут на musl, обычная linux-сборка там не запустится
    if [ "$os" = linux ] && ls /lib/ld-musl-* >/dev/null 2>&1; then
        arch="$arch-musl"
    fi
    SB="$CACHE/sing-box-$SINGBOX_VERSION-$os-$arch/sing-box"
    if [ ! -x "$SB" ]; then
        echo "📦 Скачиваю sing-box $SINGBOX_VERSION ($os-$arch)..." >&2
        name="sing-box-${SINGBOX_VERSION#v}-$os-$arch"
        mkdir -p "$CACHE/sing-box-$SINGBOX_VERSION-$os-$arch"
        curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/$SINGBOX_VERSION/$name.tar.gz" |
            tar xz -C "$CACHE/sing-box-$SINGBOX_VERSION-$os-$arch" --strip-components 1 "$name/sing-box"
    fi
fi
"$SB" version >/dev/null 2>&1 || die "sing-box не запускается: $SB"

# --- Заглушки ---
RUN="$(mktemp -d)"
trap 'rm -rf "$RUN"' EXIT INT TERM
BIN="$RUN/bin"
mkdir -p "$BIN"
ln -s "$SB" "$BIN/sing-box"
CONFIG="$RUN/podkop.conf"
: > "$CONFIG"

# uci: хранит опции в $PODKOP_CONFIG строками "ключ=значение" (списки — повтором ключа)
cat > "$BIN/uci" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && shift
store="$PODKOP_CONFIG"
cmd="$1"; arg="${2:-}"
key="${arg%%=*}"; val="${arg#*=}"
drop() { grep -v -F -x -e "$1" "$store" | grep -v "^$1=" > "$store.tmp" || true; mv "$store.tmp" "$store"; }
case "$cmd" in
    get)
        out=$(grep "^$key=" "$store" | cut -d= -f2- | tr '\n' ' ' | sed 's/ $//')
        [ -n "$out" ] || exit 1
        printf '%s\n' "$out" ;;
    set) drop "$key"; printf '%s=%s\n' "$key" "$val" >> "$store" ;;
    add_list) printf '%s=%s\n' "$key" "$val" >> "$store" ;;
    delete) drop "$key" ;;
    commit) ;;
    *) echo "uci-заглушка: не умею '$cmd'" >&2; exit 1 ;;
esac
EOF

# pidof: sing-box «запущен», если последний рестарт прошёл
cat > "$BIN/pidof" <<EOF
#!/bin/sh
[ -e "$RUN/running" ]
EOF

# wget через curl; локальный файл отдаётся как есть, чтобы run принимал фикстуры
cat > "$BIN/wget" <<'EOF'
#!/bin/sh
ua=""; url=""; out="-"; timeout=30
while [ $# -gt 0 ]; do
    case "$1" in
        --user-agent=*) ua="${1#--user-agent=}" ;;
        -qO-|-O-) out="-" ;;
        -O) out="$2"; shift ;;
        -T) timeout="$2"; shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
if [ -f "$url" ]; then
    data=$(cat "$url")
else
    data=$(curl -fsSL -m "$timeout" -A "$ua" "$url") || exit 1
fi
if [ "$out" = "-" ]; then printf '%s' "$data"; else printf '%s' "$data" > "$out"; fi
EOF

# sleep: долгие ожидания пропускаем, короткие (опрос API пинга) — настоящие
cat > "$BIN/sleep" <<'EOF'
#!/bin/sh
[ "$1" -le 1 ] 2>/dev/null && exec /bin/sleep "$1"
exit 0
EOF

# Рестарт Podkop: собрать outbound'ы кодом Podkop и проверить как при старте
cat > "$BIN/podkop-restart" <<EOF
#!/bin/sh
rm -f "$RUN/running"
if [ "\${BREAK_RESTART:-}" = 1 ] && [ ! -e "$RUN/broken" ]; then
    touch "$RUN/broken"
    echo "   [podkop] (BREAK_RESTART) имитирую падение при старте" >&2
    exit 0
fi
links=\$(uci -q get podkop.main.urltest_proxy_links) || { echo "   [podkop] URLTest proxy links is not set. Aborted." >&2; exit 0; }
. "$LIB/constants.sh"
. "$LIB/sing_box_config_facade.sh"
log() { [ "\$2" = fatal ] && echo "   [podkop] \$1" >&2; return 0; }
config='{"log":{"disabled":true},"outbounds":[]}'
i=1
for link in \$links; do
    config="\$(sing_box_cf_add_proxy_outbound "\$config" "main-\$i" "\$link" "")"
    i=\$((i + 1))
done
printf '%s' "\$config" > "$RUN/sing-box.json"
if result=\$(sing-box check -c "$RUN/sing-box.json" 2>&1); then
    touch "$RUN/running"
    echo "   [podkop] sing-box запущен, ключей: \$((i - 1))" >&2
else
    echo "   [podkop] Sing-box configuration is invalid. Aborted." >&2
    printf '%s\n' "\$result" | sed 's/\x1b\[[0-9;]*m//g' | grep -m1 -iE 'fatal|panic|error' | sed 's/^/   [sing-box] /' >&2
fi
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH" PODKOP_CONFIG="$CONFIG" PODKOP_LIB="$LIB"

echo "🧪 Podkop $PODKOP_VERSION, $("$SB" version | head -n 1)" >&2

# Достаёт ключи из url/файла через функции самого update.sh
extract_links() {
    sed -n '/^find_links()/,/^}/p; /^clean_name()/,/^# --- СБОР ---/p' "$ROOT/update.sh" > "$RUN/funcs.sh"
    # shellcheck disable=SC1091
    . "$RUN/funcs.sh"
    PATTERN=$(sed -n "s/^PATTERN=//p" "$ROOT/update.sh")
    eval "PATTERN=$PATTERN"
    for src in "$@"; do
        if [ -f "$src" ]; then cat "$src"; else download_content "$src"; fi
    done | find_links | awk '!seen[$0]++'
}

mode="${1:-}"
[ $# -ge 2 ] || { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
shift

case "$mode" in
    links)
        extract_links "$@" > "$RUN/links"
        ok=0; bad=0
        while IFS= read -r link <&3; do
            title=$(printf '%s' "$link" | sed 's/.*#//' | cut -c1-40)
            printf '%s\n' "$link" | sed 's/^/podkop.main.urltest_proxy_links=/' > "$CONFIG"
            if podkop-restart 2>"$RUN/err" && [ -e "$RUN/running" ]; then
                ok=$((ok + 1))
            else
                bad=$((bad + 1))
                echo "❌ $title"
                grep -v 'invalid. Aborted' "$RUN/err" | sed 's/^ */     /'
            fi
        done 3< "$RUN/links"
        echo "Итого: годных $ok, битых $bad"
        ;;
    podkop)
        extract_links "$@" | sed 's/^/podkop.main.urltest_proxy_links=/' > "$CONFIG"
        echo "Скармливаю Podkop все $(wc -l < "$CONFIG" | tr -d ' ') ключей без фильтра..." >&2
        podkop-restart
        [ -e "$RUN/running" ] && echo "✅ Podkop запустился" || echo "💥 Podkop упал бы при старте"
        ;;
    run)
        [ $# -le 3 ] || die "update.sh принимает не больше 3 источников"
        if [ -n "${SEED_LINKS:-}" ]; then
            extract_links "$SEED_LINKS" | sed 's/^/podkop.main.urltest_proxy_links=/' > "$CONFIG"
        fi
        cp "$ROOT/update.sh" "$RUN/update.sh"
        n=1
        for src in "$@"; do
            esc=$(printf '%s' "$src" | sed 's/[&|\\]/\\&/g')
            sed -i.bak "s|^SOURCE_$n=.*|SOURCE_$n=\"$esc\"|" "$RUN/update.sh"
            n=$((n + 1))
        done
        [ -n "${LIMIT:-}" ] && sed -i.bak "s|^LIMIT=.*|LIMIT=$LIMIT|" "$RUN/update.sh"
        sed -i.bak "s|/etc/init.d/podkop restart|podkop-restart|" "$RUN/update.sh"
        status=0
        ${SANDBOX_SHELL:-sh} "$RUN/update.sh" || status=$?
        echo "--- update.sh завершился с кодом $status; ключей в конфиге: $(grep -c '^podkop.main.urltest_proxy_links=' "$CONFIG" || true)" >&2
        exit "$status"
        ;;
    *) die "неизвестный режим '$mode' (links | run | podkop)" ;;
esac
