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
REPO="Blix-Platform/UltimateTelegramConnectionBotGO"

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

if [ "$1" = "--post-update" ]; then
    POST_UPDATE=true
    INSTALL_DIR="$(dirname "$(readlink -f "$0")")"
else
    POST_UPDATE=false
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

    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    echo ""
    print_step "ШАГ 2/4: Проверка коммитов [UP]"

    CURRENT_COMMIT=""
    if [ -f "$INSTALL_DIR/.commit" ]; then
        CURRENT_COMMIT=$(cat "$INSTALL_DIR/.commit")
    fi

    print_info "Запрос коммитов с [UP]..."

    # Get commit list — parse with python3 if available, else fallback
    COMMITS_FILE="$TEMP_DIR/commits.json"
    curl -fsSL --max-time 15 "https://api.github.com/repos/$REPO/commits?per_page=50" -o "$COMMITS_FILE" 2>/dev/null

    if [ ! -f "$COMMITS_FILE" ]; then
        print_error "Не удалось получить коммиты"
        exit 1
    fi

    UP_COMMIT=""
    UP_MESSAGE=""
    FOUND_CURRENT=false

    if command -v python3 &> /dev/null; then
        # Parse with Python
        while IFS='|' read -r LINE; do
            [ -z "$LINE" ] && continue
            SHA=$(echo "$LINE" | cut -d'|' -f1)
            MSG=$(echo "$LINE" | cut -d'|' -f2-)

            if [ -n "$CURRENT_COMMIT" ] && [ "$SHA" = "$CURRENT_COMMIT" ]; then
                FOUND_CURRENT=true
                break
            fi

            if echo "$MSG" | grep -qi '^\[UP\]'; then
                MSG_CLEAN=$(echo "$MSG" | sed 's/^\[UP\][[:space:]]*//;s/^\[up\][[:space:]]*//')
                UP_COMMIT="$SHA"
                UP_MESSAGE="$MSG_CLEAN"
                break
            fi
        done < <(python3 -c "
import json, sys
try:
    data = json.load(open('$COMMITS_FILE'))
    for c in data:
        sha = c.get('sha','')
        msg = c.get('commit',{}).get('message','')
        print(f'{sha}|{msg}')
except: pass
" 2>/dev/null)
    else
        # Fallback: just use latest commit
        UP_COMMIT=$(curl -fsSL --max-time 10 "https://api.github.com/repos/$REPO/commits?per_page=1" 2>/dev/null | grep -o '"sha":"[^"]*"' | head -1 | sed 's/"sha":"//;s/"//')
        UP_MESSAGE="latest commit"
    fi

    if [ -z "$UP_COMMIT" ]; then
        if [ -n "$CURRENT_COMMIT" ] && [ "$FOUND_CURRENT" = true ]; then
            print_success "У вас последняя версия: ${CURRENT_COMMIT:0:7}"
            rm -rf "$TEMP_DIR"
            exit 0
        fi
        print_info "Коммитов [UP] не найдено, используется последний коммит"
        UP_COMMIT=$(grep -o '"sha":"[^"]*"' "$COMMITS_FILE" | head -1 | sed 's/"sha":"//;s/"//')
        if [ -n "$CURRENT_COMMIT" ] && [ "$UP_COMMIT" = "$CURRENT_COMMIT" ]; then
            print_success "У вас последняя версия: ${CURRENT_COMMIT:0:7}"
            rm -rf "$TEMP_DIR"
            exit 0
        fi
    fi

    if [ -z "$UP_COMMIT" ]; then
        print_error "Не найдено коммитов для обновления"
        exit 1
    fi

    print_success "Найден коммит: ${UP_COMMIT:0:7} — $UP_MESSAGE"

    echo ""
    print_step "ШАГ 3/4: Загрузка изменённых файлов"

    # Get commit detail to list changed files
    COMMIT_DETAIL=$(curl -fsSL --max-time 15 "https://api.github.com/repos/$REPO/commits/$UP_COMMIT" 2>/dev/null || echo "")

    if [ -z "$COMMIT_DETAIL" ]; then
        print_error "Не удалось получить детали коммита"
        exit 1
    fi

    # Extract filenames
    FILE_LIST=$(echo "$COMMIT_DETAIL" | grep -o '"filename":"[^"]*"' | sed 's/"filename":"//;s/"//')

    UPDATED=0
    SKIPPED=0
    ERRORS=0

    while IFS= read -r FILE; do
        [ -z "$FILE" ] && continue

        # Only update relevant files
        case "$FILE" in
            cmd/*|internal/*|go.mod|go.sum|*.sh|*.bat)
                ;;
            *)
                SKIPPED=$((SKIPPED + 1))
                continue
                ;;
        esac

        # Download file to temp
        FILE_URL="https://raw.githubusercontent.com/$REPO/$UP_COMMIT/$FILE"
        curl -fsSL --max-time 30 "$FILE_URL" -o "$TEMP_DIR/downloaded_file" 2>/dev/null || {
            print_error "Ошибка загрузки $FILE"
            ERRORS=$((ERRORS + 1))
            continue
        }

        LOCAL_PATH="$INSTALL_DIR/$FILE"

        # Compare with local version using md5sum
        if [ -f "$LOCAL_PATH" ]; then
            EXISTING_HASH=$(md5sum "$LOCAL_PATH" 2>/dev/null | awk '{print $1}')
            NEW_HASH=$(md5sum "$TEMP_DIR/downloaded_file" | awk '{print $1}')
            if [ "$EXISTING_HASH" = "$NEW_HASH" ]; then
                SKIPPED=$((SKIPPED + 1))
                continue
            fi
        fi

        # Write file
        mkdir -p "$(dirname "$LOCAL_PATH")"
        cp "$TEMP_DIR/downloaded_file" "$LOCAL_PATH"
        UPDATED=$((UPDATED + 1))

    done <<< "$FILE_LIST"

    # Save commit SHA
    echo "$UP_COMMIT" > "$INSTALL_DIR/.commit"

    chmod +x "$INSTALL_DIR/update.sh" "$INSTALL_DIR/install.sh" 2>/dev/null
    chmod +x "$INSTALL_DIR/update.bat" "$INSTALL_DIR/install.bat" "$INSTALL_DIR/uninstall.bat" "$INSTALL_DIR/uninstall.sh" 2>/dev/null

    print_success "Обновлено файлов: $UPDATED"
    print_info "Пропущено файлов: $SKIPPED"
    if [ "$ERRORS" -gt 0 ]; then
        print_error "Ошибок: $ERRORS"
    fi

    echo ""
    print_step "ШАГ 4/4: Сборка и перезапуск"
fi

# ── Build & Restart ──
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

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}                                                          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${BOLD}${WHITE}Система обновлена!${NC}                                          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                          ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${WHITE}Commit: ${CYAN}$(cat "$INSTALL_DIR/.commit" 2>/dev/null | cut -c1-7 || echo 'неизвестен')${NC}"
echo -e "${WHITE}Все данные сохранены. Бот работает.${NC}"
echo ""
