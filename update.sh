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

    if ! command -v unzip &> /dev/null; then
        apt-get install -y -qq unzip
    fi

    print_info "Проверка последней версии..."

    RELEASES=$(curl -fsSL --max-time 10 https://api.github.com/repos/Blix-Platform/UltimateTelegramConnectionBotGO/releases 2>/dev/null || echo "[]")
    HAS_RELEASES=$(echo "$RELEASES" | grep -c '"tag_name"' || true)

    if [ "$HAS_RELEASES" -gt 0 ]; then
        LATEST_TAG=$(echo "$RELEASES" | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"//;s/".*//')
    else
        LATEST_TAG=""
    fi

    LATEST_VER=""
    if [ -n "$LATEST_TAG" ]; then
        LATEST_VER=$(echo "$LATEST_TAG" | sed 's/^v//')
        ZIP_URL="https://github.com/Blix-Platform/UltimateTelegramConnectionBotGO/archive/refs/tags/${LATEST_TAG}.zip"
    else
        LATEST_TAG="main"
        LATEST_VER="dev"
        ZIP_URL="https://github.com/Blix-Platform/UltimateTelegramConnectionBotGO/archive/refs/heads/main.zip"
    fi

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

    curl -fsSL -L "$ZIP_URL" -o "$TEMP_DIR/release.zip"

    if [ ! -f "$TEMP_DIR/release.zip" ] || [ ! -s "$TEMP_DIR/release.zip" ]; then
        print_error "Не удалось загрузить релиз"
        exit 1
    fi

    print_success "Релиз загружен"

    echo ""
    print_step "ШАГ 3/4: Распаковка и обновление файлов"

    unzip -q "$TEMP_DIR/release.zip" -d "$TEMP_DIR/extracted"

    SRC_DIR=$(find "$TEMP_DIR/extracted" -mindepth 1 -maxdepth 1 -type d | head -1)

    if [ -z "$SRC_DIR" ]; then
        print_error "Не удалось распаковать архив"
        exit 1
    fi

    BACKUP_ENV=$(cat "$INSTALL_DIR/.env" 2>/dev/null || echo "")

    UPDATED=0
    SKIPPED=0

    for FILE in cmd/bot/main.go go.mod go.sum update.sh install.sh uninstall.sh update.bat install.bat uninstall.bat; do
        if [ -f "$SRC_DIR/$FILE" ]; then
            if [ -f "$INSTALL_DIR/$FILE" ] && diff -q "$SRC_DIR/$FILE" "$INSTALL_DIR/$FILE" > /dev/null 2>&1; then
                SKIPPED=$((SKIPPED + 1))
            else
                mkdir -p "$(dirname "$INSTALL_DIR/$FILE")"
                cp "$SRC_DIR/$FILE" "$INSTALL_DIR/$FILE"
                UPDATED=$((UPDATED + 1))
            fi
        fi
    done

    if [ -d "$SRC_DIR/internal" ]; then
        rsync -a --delete "$SRC_DIR/internal/" "$INSTALL_DIR/internal/" 2>/dev/null || cp -r "$SRC_DIR/internal" "$INSTALL_DIR/"
    fi

    echo -e "$BACKUP_ENV" > "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
    echo "$LATEST_VER" > "$INSTALL_DIR/.version"

    chmod +x "$INSTALL_DIR/update.sh" "$INSTALL_DIR/install.sh" 2>/dev/null
    chmod +x "$INSTALL_DIR/update.bat" "$INSTALL_DIR/install.bat" "$INSTALL_DIR/uninstall.bat" "$INSTALL_DIR/uninstall.sh" 2>/dev/null

    print_success "Обновлено файлов: $UPDATED"
    print_info "Пропущено файлов: $SKIPPED"

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

    # Fetch latest [UP] commit SHA
    LATEST_COMMIT=$(curl -fsSL --max-time 5 "https://api.github.com/repos/Blix-Platform/UltimateTelegramConnectionBotGO/commits?per_page=1" 2>/dev/null | grep -o '"sha":"[^"]*"' | head -1 | sed 's/"sha":"//;s/"//')
    if [ -n "$LATEST_COMMIT" ]; then
        echo "$LATEST_COMMIT" > "$INSTALL_DIR/.commit"
        print_success "Commit SHA сохранён: ${LATEST_COMMIT:0:7}"
    fi

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
if [ -f "$INSTALL_DIR/.commit" ]; then
    COMMIT_SHA=$(cat "$INSTALL_DIR/.commit")
    echo -e "${WHITE}Commit: ${CYAN}${COMMIT_SHA:0:7}${NC}"
fi
echo -e "${WHITE}Все данные сохранены. Бот работает.${NC}"
echo ""
