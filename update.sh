#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="/opt/tgbot"
REPO_URL="https://github.com/Blix-Platform/UltimateTelegramConnectionBotGO.git"
SERVICE_NAME="tgbot"

print_header() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}${WHITE}Telegram Connection Bot - Обновление${NC}                     ${CYAN}║${NC}"
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
    print_error "Запустите от имени root (sudo)"
    exit 1
fi

print_step "ШАГ 1/6: Проверка установки"

if [ ! -d "$INSTALL_DIR" ]; then
    print_error "Бот не установлен. Сначала запустите install.sh"
    exit 1
fi

if [ ! -f "$INSTALL_DIR/.env" ]; then
    print_error "Файл конфигурации не найден. Бот установлен некорректно."
    exit 1
fi

if [ ! -f "$INSTALL_DIR/tgbot" ]; then
    print_error "Бинарный файл бота не найден. Бот установлен некорректно."
    exit 1
fi

if ! systemctl list-unit-files | grep -q ${SERVICE_NAME}.service 2>/dev/null; then
    if [ ! -f "/etc/init.d/tgbot" ]; then
        print_error "Сервис бота не найден. Бот установлен некорректно."
        exit 1
    fi
fi

print_success "Бот найден: $INSTALL_DIR"

echo ""
print_step "ШАГ 2/6: Клонирование репозитория"

TEMP_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if ! command -v git &> /dev/null; then
    print_info "Установка git..."
    apt-get update -qq
    apt-get install -y -qq git
fi

git clone --depth 1 "$REPO_URL" "$TEMP_DIR" 2>/dev/null

if [ ! -d "$TEMP_DIR/cmd" ] || [ ! -d "$TEMP_DIR/internal" ]; then
    print_error "Не удалось клонировать репозиторий"
    exit 1
fi

print_success "Репозиторий клонирован"

echo ""
print_step "ШАГ 3/6: Остановка сервиса"

if systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
    systemctl stop ${SERVICE_NAME}
    print_success "Сервис остановлен"
elif [ -f "/etc/init.d/tgbot" ]; then
    /etc/init.d/tgbot stop
    print_success "Сервис остановлен (init)"
else
    print_info "Сервис не запущен"
fi

echo ""
print_step "ШАГ 4/6: Сохранение данных"

BACKUP_ENV=$(cat "$INSTALL_DIR/.env" 2>/dev/null || echo "")
BACKUP_DB_EXISTS=false
if [ -f "$INSTALL_DIR/bot.db" ]; then
    BACKUP_DB_EXISTS=true
fi

print_success "Конфигурация сохранена"
if [ "$BACKUP_DB_EXISTS" = true ]; then
    print_success "База данных сохранена"
else
    print_info "База данных не найдена (создастся новая)"
fi

echo ""
print_step "ШАГ 5/6: Копирование и сборка"

cp -r "$TEMP_DIR/cmd" "$INSTALL_DIR/"
cp -r "$TEMP_DIR/internal" "$INSTALL_DIR/"
cp "$TEMP_DIR/go.mod" "$INSTALL_DIR/"
cp "$TEMP_DIR/go.sum" "$INSTALL_DIR/" 2>/dev/null || true
cp "$TEMP_DIR/update.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/update.sh"

echo -e "$BACKUP_ENV" > "$INSTALL_DIR/.env"
chmod 600 "$INSTALL_DIR/.env"

cd "$INSTALL_DIR"

export PATH="/usr/local/go/bin:$PATH"
export GOPATH="$INSTALL_DIR/gopath"
export GOROOT=/usr/local/go

go mod download 2>/dev/null
go build -o tgbot ./cmd/bot/

chmod +x "$INSTALL_DIR/tgbot"

print_success "Файлы обновлены и собраны"

echo ""
print_step "ШАГ 6/6: Запуск сервиса"

if command -v systemctl &> /dev/null; then
    systemctl start ${SERVICE_NAME}
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        print_success "Сервис запущен (systemd)"
    else
        print_error "Ошибка запуска"
        print_info "Проверьте: journalctl -u ${SERVICE_NAME} -f"
        exit 1
    fi
elif [ -f "/etc/init.d/tgbot" ]; then
    /etc/init.d/tgbot start
    print_success "Сервис запущен (init)"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}                                                          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${BOLD}${WHITE}Обновление завершено успешно!${NC}                               ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                          ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${WHITE}Все данные сохранены. Бот работает с новой версией.${NC}"
echo ""
