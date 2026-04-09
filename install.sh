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
REPO_URL="https://github.com/Blix-Platform/UltimateTelegramConnectionBotGO.git"

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

if ! command -v go &> /dev/null; then
    print_info "Go не установлен. Установка..."
    apt-get update -qq
    apt-get install -y -qq golang-go
    print_success "Go установлен"
else
    GO_VERSION=$(go version)
    print_success "Go найден: $GO_VERSION"
fi

print_info "Установка build-зависимостей для SQLite..."
apt-get update -qq
apt-get install -y -qq build-essential gcc libsqlite3-dev git
print_success "Build-зависимости установлены"

if command -v systemctl &> /dev/null; then
    print_success "systemd найден"
    HAS_SYSTEMD=true
else
    print_info "systemd не найден, сервис не будет создан"
    HAS_SYSTEMD=false
fi

echo ""
print_step "ШАГ 2/7: Получение исходного кода"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_CLONE=false

if [ -d "$SCRIPT_DIR/cmd" ] && [ -d "$SCRIPT_DIR/internal" ]; then
    print_success "Исходный код найден в текущей директории"
    SOURCE_DIR="$SCRIPT_DIR"
else
    print_info "Исходный код не найден. Клонирование репозитория..."

    TEMP_DIR=$(mktemp -d)
    git clone --depth 1 "$REPO_URL" "$TEMP_DIR" 2>/dev/null

    if [ -d "$TEMP_DIR/cmd" ] && [ -d "$TEMP_DIR/internal" ]; then
        SOURCE_DIR="$TEMP_DIR"
        TEMP_CLONE=true
        print_success "Репозиторий клонирован"
    else
        print_error "Не удалось клонировать репозиторий"
        exit 1
    fi
fi

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
print_step "ШАГ 5/7: Копирование файлов"

cp -r "$SOURCE_DIR/cmd" "$INSTALL_DIR/"
cp -r "$SOURCE_DIR/internal" "$INSTALL_DIR/"
cp "$SOURCE_DIR/go.mod" "$INSTALL_DIR/"
cp "$SOURCE_DIR/go.sum" "$INSTALL_DIR/" 2>/dev/null || true

print_success "Файлы скопированы"

if [ "$TEMP_CLONE" = true ]; then
    rm -rf "$TEMP_DIR"
fi

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
