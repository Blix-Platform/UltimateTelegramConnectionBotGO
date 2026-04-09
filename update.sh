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

POST_UPDATE=false
if [ "$1" = "--post-update" ]; then
    POST_UPDATE=true
fi

if [ "$POST_UPDATE" = false ]; then
    print_step "ШАГ 1/4: Проверка установки"

    if [ ! -d "$INSTALL_DIR" ]; then
        print_error "Бот не установлен. Сначала запустите install.sh"
        exit 1
    fi

    if [ ! -f "$INSTALL_DIR/.env" ]; then
        print_error "Файл конфигурации не найден."
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq curl
    fi

    print_info "Проверка последней версии..."
    LATEST_TAG=$(curl -fsSL https://api.github.com/repos/Blix-Platform/UltimateTelegramConnectionBotGO/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')

    if [ -z "$LATEST_TAG" ]; then
        print_error "Не удалось получить информацию о релизе"
        exit 1
    fi

    LATEST_VER=$(echo "$LATEST_TAG" | sed 's/^v//')

    if [ -f "$INSTALL_DIR/.version" ]; then
        CURRENT_VER=$(cat "$INSTALL_DIR/.version")
        if [ "$CURRENT_VER" = "$LATEST_VER" ]; then
            print_success "У вас последняя версия: v$CURRENT_VER"
            exit 0
        fi
    fi

    print_success "Доступна версия: $LATEST_TAG"

    echo ""
    print_step "ШАГ 2/4: Загрузка релиза"

    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    ZIP_URL=$(curl -fsSL https://api.github.com/repos/Blix-Platform/UltimateTelegramConnectionBotGO/releases/latest | grep -oP '"zipball_url":\s*"\K[^"]+')
    curl -fsSL -L "$ZIP_URL" -o "$TEMP_DIR/release.zip"

    print_success "Релиз загружен"

    echo ""
    print_step "ШАГ 3/4: Распаковка и установка"

    unzip -q "$TEMP_DIR/release.zip" -d "$TEMP_DIR/extracted"

    SRC_DIR=$(find "$TEMP_DIR/extracted" -mindepth 1 -maxdepth 1 -type d | head -1)

    if [ -z "$SRC_DIR" ] || [ ! -d "$SRC_DIR/cmd" ]; then
        print_error "Не найдены исходные файлы"
        exit 1
    fi

    BACKUP_ENV=$(cat "$INSTALL_DIR/.env" 2>/dev/null || echo "")

    cp -r "$SRC_DIR/cmd" "$INSTALL_DIR/"
    cp -r "$SRC_DIR/internal" "$INSTALL_DIR/"
    cp "$SRC_DIR/go.mod" "$INSTALL_DIR/"
    cp "$SRC_DIR/go.sum" "$INSTALL_DIR/" 2>/dev/null || true
    cp "$SRC_DIR/update.sh" "$INSTALL_DIR/"
    cp "$SRC_DIR/install.sh" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/update.sh" "$INSTALL_DIR/install.sh"

    echo -e "$BACKUP_ENV" > "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
    echo "$LATEST_VER" > "$INSTALL_DIR/.version"

    print_success "Файлы обновлены"

    echo ""
    print_step "ШАГ 4/4: Сборка и перезапуск"
else
    POST_UPDATE=true
    INSTALL_DIR="$(dirname "$(readlink -f "$0")")"
fi

if [ "$POST_UPDATE" = true ] || true; then
    cd "$INSTALL_DIR"

    export PATH="/usr/local/go/bin:$PATH"
    export GOPATH="$INSTALL_DIR/gopath"
    export GOROOT=/usr/local/go

    go mod download 2>/dev/null
    go build -o tgbot ./cmd/bot/

    chmod +x "$INSTALL_DIR/tgbot"
    print_success "Бот собран"

    echo ""

    HAS_SYSTEMD=false
    if command -v systemctl &> /dev/null && systemctl list-unit-files | grep -q ${SERVICE_NAME}.service 2>/dev/null; then
        HAS_SYSTEMD=true
    fi

    if [ "$HAS_SYSTEMD" = true ]; then
        echo -e "${YELLOW}ℹ️  Перезапуск сервиса...${NC}"
        systemctl restart ${SERVICE_NAME}
        sleep 2
        if systemctl is-active --quiet ${SERVICE_NAME}; then
            print_success "Сервис перезапущен (systemd)"
        else
            print_error "Ошибка запуска"
            print_info "Проверьте: journalctl -u ${SERVICE_NAME} -f"
            exit 1
        fi
    elif [ -f "/etc/init.d/tgbot" ]; then
        echo -e "${YELLOW}ℹ️  Перезапуск сервиса...${NC}"
        /etc/init.d/tgbot restart
        print_success "Сервис перезапущен (init)"
    else
        echo -e "${YELLOW}ℹ️  Запуск вручную...${NC}"
        if pgrep -f "$INSTALL_DIR/tgbot" > /dev/null 2>&1; then
            kill $(pgrep -f "$INSTALL_DIR/tgbot") 2>/dev/null || true
            sleep 2
        fi
        cd "$INSTALL_DIR"
        . "$INSTALL_DIR/.env"
        nohup "$INSTALL_DIR/tgbot" > /var/log/tgbot.log 2>&1 &
        print_success "Бот запущен"
    fi
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}                                                          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${BOLD}${WHITE}Система обновлена!${NC}                                          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                          ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${WHITE}Версия: ${CYAN}v$(cat "$INSTALL_DIR/.version" 2>/dev/null || echo 'неизвестна')${NC}"
echo -e "${WHITE}Все данные сохранены. Бот работает.${NC}"
echo ""
