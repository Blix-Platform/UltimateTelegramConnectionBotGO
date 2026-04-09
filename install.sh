#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

SERVICE_NAME="tgbot"
INSTALL_DIR="/opt/tgbot"
REPO="Blix-Platform/UltimateTelegramConnectionBotGO"

print_header() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}${WHITE}Telegram Connection Bot - Установка${NC}                      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${WHITE}UltimateTelegramConnectionBotGO${NC}                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_step() {
    echo -e "${CYAN}┌──────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${BOLD}$1${NC}"
    echo -e "${CYAN}└──────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ️  $1${NC}"
}

print_header

if [ "$EUID" -ne 0 ]; then
    print_error "Запустите скрипт от имени root (sudo)"
    exit 1
fi

print_step "ШАГ 1/7: Проверка зависимостей"

GO_REQUIRED="1.19"

install_go() {
    print_info "Установка Go..."

    if ! command -v curl &> /dev/null; then
        apt-get update -qq
        apt-get install -y -qq curl
    fi

    GO_VERSION_LATEST=$(curl -fsSL https://go.dev/VERSION?m=text | head -1)
    GO_URL="https://golang.org/dl/${GO_VERSION_LATEST}.linux-amd64.tar.gz"

    rm -rf /usr/local/go
    curl -fsSL "$GO_URL" | tar -C /usr/local -xz

    if [ -f /usr/local/go/bin/go ]; then
        ln -sf /usr/local/go/bin/go /usr/local/bin/go
        ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
        export PATH="/usr/local/go/bin:$PATH"
        export GOROOT=/usr/local/go
        print_success "Go установлен: $(/usr/local/go/bin/go version | grep -oP 'go\K[0-9.]+')"
    else
        print_error "Ошибка установки Go"
        exit 1
    fi
}

if ! command -v go &> /dev/null; then
    install_go
else
    GO_BIN=go
    [ -f /usr/local/go/bin/go ] && GO_BIN=/usr/local/go/bin/go
    GO_VERSION=$($GO_BIN version | grep -oP 'go\K[0-9]+\.[0-9]+')
    GO_REQ_MAJOR=$(echo "$GO_REQUIRED" | cut -d. -f1)
    GO_REQ_MINOR=$(echo "$GO_REQUIRED" | cut -d. -f2)
    GO_INST_MAJOR=$(echo "$GO_VERSION" | cut -d. -f1)
    GO_INST_MINOR=$(echo "$GO_VERSION" | cut -d. -f2)

    if [ "$GO_INST_MAJOR" -gt "$GO_REQ_MAJOR" ] || { [ "$GO_INST_MAJOR" -eq "$GO_REQ_MAJOR" ] && [ "$GO_INST_MINOR" -ge "$GO_REQ_MINOR" ]; }; then
        print_success "Go найден: $($GO_BIN version | grep -oP 'go\K[0-9.]+')"
    else
        print_info "Go устарел (нужен $GO_REQUIRED, у вас $GO_VERSION). Обновление..."
        install_go
    fi
fi

export PATH="/usr/local/go/bin:$PATH"
export GOROOT=/usr/local/go

print_info "Установка build-зависимостей для SQLite..."
apt-get update -qq
apt-get install -y -qq build-essential gcc libsqlite3-dev curl unzip
print_success "Build-зависимости установлены"

if command -v systemctl &> /dev/null; then
    print_success "systemd найден"
    HAS_SYSTEMD=true
else
    print_info "systemd не найден, сервис не будет создан"
    HAS_SYSTEMD=false
fi

echo ""
print_step "ШАГ 2/7: Загрузка файлов проекта"

# Get latest commit (or latest [UP] commit)
print_info "Получение последнего коммита..."
COMMITS_RAW=$(curl -fsSL --max-time 15 "https://api.github.com/repos/$REPO/commits?per_page=10" 2>/dev/null || echo "")

TARGET_COMMIT=""
TARGET_VER="dev"

if [ -n "$COMMITS_RAW" ]; then
    # Try to find first [UP] commit
    while IFS= read -r SHA_LINE; do
        SHA=$(echo "$SHA_LINE" | sed 's/"sha":"//;s/"//')
        [ -z "$SHA" ] && continue

        # Get commit detail
        COMMIT_DETAIL=$(curl -fsSL --max-time 10 "https://api.github.com/repos/$REPO/commits/$SHA" 2>/dev/null || echo "")
        MSG=$(echo "$COMMIT_DETAIL" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"//')

        if echo "$MSG" | grep -qi '^\[UP\]'; then
            TARGET_COMMIT="$SHA"
            MSG_CLEAN=$(echo "$MSG" | sed 's/^\[UP\][[:space:]]*//;s/^\[up\][[:space:]]*//')
            TARGET_VER="$MSG_CLEAN"
            break
        fi
    done < <(echo "$COMMITS_RAW" | grep -o '"sha":"[^"]*"')

    # Fallback to latest commit
    if [ -z "$TARGET_COMMIT" ]; then
        TARGET_COMMIT=$(echo "$COMMITS_RAW" | grep -o '"sha":"[^"]*"' | head -1 | sed 's/"sha":"//;s/"//')
    fi
fi

if [ -z "$TARGET_COMMIT" ]; then
    print_error "Не удалось получить коммиты"
    exit 1
fi

print_success "Коммит: ${TARGET_COMMIT:0:7}"

echo -e "${YELLOW}ℹ️  Загрузка файлов из коммита...${NC}"

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Download essential files directly from commit
FILES_NEEDED=("cmd/bot/main.go" "go.mod" "go.sum" "update.sh" "install.sh" "uninstall.sh" "update.bat" "install.bat" "uninstall.bat")

for FILE in "${FILES_NEEDED[@]}"; do
    FILE_URL="https://raw.githubusercontent.com/$REPO/$TARGET_COMMIT/$FILE"
    curl -fsSL --max-time 30 "$FILE_URL" -o "$TEMP_DIR/$FILE" 2>/dev/null || {
        print_info "Пропуск $FILE (не найден)"
    }
done

# Download internal directory as ZIP
print_info "Загрузка internal/..."
curl -fsSL --max-time 120 "https://github.com/$REPO/archive/$TARGET_COMMIT.zip" -o "$TEMP_DIR/source.zip" 2>/dev/null || {
    print_error "Не удалось загрузить исходники"
    exit 1
}

unzip -q "$TEMP_DIR/source.zip" -d "$TEMP_DIR/extracted"

SRC_DIR=$(find "$TEMP_DIR/extracted" -mindepth 1 -maxdepth 1 -type d | head -1)

if [ -z "$SRC_DIR" ]; then
    print_error "Не удалось распаковать архив"
    exit 1
fi

print_success "Файлы загружены"

echo ""
print_step "ШАГ 3/7: Ввод данных бота"

echo -e "${WHITE}${BOLD}Введите токен бота от @BotFather:${NC}"
echo -e "${YELLOW}Пример: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz${NC}"
echo -n -e "${CYAN}BOT_TOKEN → ${NC}"
read -r BOT_TOKEN

while [ -z "$BOT_TOKEN" ]; do
    print_error "Токен не может быть пустым!"
    echo -n -e "${CYAN}BOT_TOKEN → ${NC}"
    read -r BOT_TOKEN
done

echo ""
echo -e "${WHITE}${BOLD}Введите ваш Telegram ID:${NC}"
echo -e "${YELLOW}Узнать ID можно через бота @userinfobot${NC}"
echo -n -e "${CYAN}ADMIN_ID → ${NC}"
read -r ADMIN_ID

while ! [[ "$ADMIN_ID" =~ ^[0-9]+$ ]]; do
    print_error "ID должен содержать только цифры!"
    echo -n -e "${CYAN}ADMIN_ID → ${NC}"
    read -r ADMIN_ID
done

print_success "Данные получены"
echo ""

print_step "ШАГ 4/7: Создание директории"

mkdir -p "$INSTALL_DIR"
print_success "Директория создана: $INSTALL_DIR"

echo ""
print_step "ШАГ 5/7: Распаковка файлов"

cp -r "$SRC_DIR/cmd" "$INSTALL_DIR/" 2>/dev/null || cp "$TEMP_DIR/cmd/bot/main.go" "$INSTALL_DIR/cmd/bot/main.go" 2>/dev/null || true
cp -r "$SRC_DIR/internal" "$INSTALL_DIR/"
cp "$SRC_DIR/go.mod" "$INSTALL_DIR/"
cp "$SRC_DIR/go.sum" "$INSTALL_DIR/" 2>/dev/null || true
cp "$SRC_DIR/update.sh" "$INSTALL_DIR/" 2>/dev/null || cp "$TEMP_DIR/update.sh" "$INSTALL_DIR/" 2>/dev/null || true
cp "$SRC_DIR/install.sh" "$INSTALL_DIR/" 2>/dev/null || cp "$TEMP_DIR/install.sh" "$INSTALL_DIR/" 2>/dev/null || true
cp "$SRC_DIR/uninstall.sh" "$INSTALL_DIR/" 2>/dev/null || cp "$TEMP_DIR/uninstall.sh" "$INSTALL_DIR/" 2>/dev/null || true
cp "$SRC_DIR/update.bat" "$INSTALL_DIR/" 2>/dev/null || cp "$TEMP_DIR/update.bat" "$INSTALL_DIR/" 2>/dev/null || true
cp "$SRC_DIR/install.bat" "$INSTALL_DIR/" 2>/dev/null || cp "$TEMP_DIR/install.bat" "$INSTALL_DIR/" 2>/dev/null || true
cp "$SRC_DIR/uninstall.bat" "$INSTALL_DIR/" 2>/dev/null || cp "$TEMP_DIR/uninstall.bat" "$INSTALL_DIR/" 2>/dev/null || true
chmod +x "$INSTALL_DIR/update.sh" "$INSTALL_DIR/install.sh" 2>/dev/null
chmod +x "$INSTALL_DIR/update.bat" "$INSTALL_DIR/install.bat" "$INSTALL_DIR/uninstall.bat" 2>/dev/null

# Save version and commit
echo "dev" > "$INSTALL_DIR/.version"
echo "$TARGET_COMMIT" > "$INSTALL_DIR/.commit"

print_success "Файлы распакованы"

echo ""
print_step "ШАГ 6/7: Сборка проекта"

cd "$INSTALL_DIR"

export GOPATH="$INSTALL_DIR/gopath"
go mod download
go build -o tgbot ./cmd/bot/

chmod +x "$INSTALL_DIR/tgbot"

print_success "Бот собран"

echo ""

cat > "$INSTALL_DIR/.env" <<EOF
BOT_TOKEN=$BOT_TOKEN
ADMIN_ID=$ADMIN_ID
EOF

chmod 600 "$INSTALL_DIR/.env"
print_success "Конфигурация сохранена"

echo ""
print_step "ШАГ 7/7: Настройка сервиса"

if [ "$HAS_SYSTEMD" = true ]; then
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Telegram Connection Bot
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/tgbot
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}
    systemctl start ${SERVICE_NAME}

    if systemctl is-active --quiet ${SERVICE_NAME}; then
        print_success "Сервис запущен и работает"
    else
        print_error "Ошибка запуска сервиса"
        print_info "Проверьте: journalctl -u ${SERVICE_NAME} -f"
    fi
else
    cat > /etc/init.d/tgbot <<'INITSCRIPT'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          tgbot
# Required-Start:    $network
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Description:       Telegram Connection Bot
### END INIT INFO

INSTALL_DIR="/opt/tgbot"

case "$1" in
    start)
        cd $INSTALL_DIR
        . $INSTALL_DIR/.env
        nohup $INSTALL_DIR/tgbot > /var/log/tgbot.log 2>&1 &
        echo "Bot started."
        ;;
    stop)
        killall tgbot 2>/dev/null
        echo "Bot stopped."
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac
exit 0
INITSCRIPT

    chmod +x /etc/init.d/tgbot
    update-rc.d tgbot defaults
    /etc/init.d/tgbot start
    print_success "Init скрипт создан и бот запущен"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}                                                          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${BOLD}${WHITE}Установка завершена успешно!${NC}                            ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                          ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${WHITE}${BOLD}Установка завершена!${NC}"
echo ""
echo -e "${WHITE}📁 Директория:${NC}       ${CYAN}$INSTALL_DIR${NC}"
echo -e "${WHITE}⚙️  Конфиг:${NC}          ${CYAN}$INSTALL_DIR/.env${NC}"
echo -e "${WHITE}🗃  База данных:${NC}      ${CYAN}$INSTALL_DIR/bot.db${NC}"
echo -e "${WHITE}🔖 Commit:${NC}            ${CYAN}${TARGET_COMMIT:0:7}${NC}"
echo ""
if [ "$HAS_SYSTEMD" = true ]; then
    echo -e "${WHITE}${BOLD}Управление сервисом:${NC}"
    echo -e "  ${CYAN}systemctl status ${SERVICE_NAME}${NC}    - статус"
    echo -e "  ${CYAN}systemctl restart ${SERVICE_NAME}${NC}   - перезапуск"
    echo -e "  ${CYAN}systemctl stop ${SERVICE_NAME}${NC}      - остановка"
    echo -e "  ${CYAN}journalctl -u ${SERVICE_NAME} -f${NC}    - логи"
else
    echo -e "${WHITE}${BOLD}Управление сервисом:${NC}"
    echo -e "  ${CYAN}/etc/init.d/tgbot status${NC}   - статус"
    echo -e "  ${CYAN}/etc/init.d/tgbot restart${NC}  - перезапуск"
    echo -e "  ${CYAN}/etc/init.d/tgbot stop${NC}     - остановка"
fi
echo ""
echo -e "${WHITE}Для настройки сообщений используйте${NC} ${CYAN}/settings${NC} ${WHITE}в боте${NC}"
echo ""
