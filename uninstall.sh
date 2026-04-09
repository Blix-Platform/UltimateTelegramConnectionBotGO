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
    echo -e "${CYAN}║${NC}  ${BOLD}${WHITE}Telegram Connection Bot - Полное удаление${NC}                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${WHITE}UltimateTelegramConnectionBotGO${NC}                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_header

if [ "$EUID" -ne 0 ]; then
    print_error "Запустите скрипт от имени root (sudo)"
    exit 1
fi

echo -e "${RED}${BOLD}⚠️  ВНИМАНИЕ: Это действие удалит:${NC}"
echo -e "   • Сервис ${SERVICE_NAME}"
echo -e "   • Директорию: ${INSTALL_DIR}"
echo -e "   • Базу данных SQLite (bot.db)"
echo -e "   • Все настройки и данные"
echo ""
echo -e "${RED}Эти действия необратимы!${NC}"
echo ""
echo -n -e "${CYAN}Вы уверены? Введите 'да' для подтверждения: ${NC}"
read -r CONFIRM

if [ "$CONFIRM" != "да" ]; then
    echo ""
    print_info "Удаление отменено"
    exit 0
fi

echo ""
print_info "Остановка сервиса..."
if systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null; then
    systemctl stop ${SERVICE_NAME}
    print_success "Сервис остановлен"
else
    print_info "Сервис не запущен"
fi

echo ""
print_info "Отключение сервиса из автозагрузки..."
if systemctl is-enabled --quiet ${SERVICE_NAME} 2>/dev/null; then
    systemctl disable ${SERVICE_NAME}
    print_success "Сервис отключён"
else
    print_info "Сервис не был в автозагрузке"
fi

echo ""
print_info "Удаление сервиса systemd..."
if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
    systemctl daemon-reload
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload
    print_success "Сервис удалён"
else
    print_info "Файл сервиса не найден"
fi

echo ""
print_info "Удаление init-скрипта (если есть)..."
if [ -f "/etc/init.d/tgbot" ]; then
    update-rc.d -f tgbot remove
    rm -f /etc/init.d/tgbot
    print_success "Init-скрипт удалён"
else
    print_info "Init-скрипт не найден"
fi

echo ""
print_info "Удаление директории установки..."
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    print_success "Директория удалена: $INSTALL_DIR"
else
    print_info "Директория не найдена"
fi

echo ""
print_info "Удаление логов..."
rm -f /var/log/tgbot.log 2>/dev/null
journalctl --flush 2>/dev/null
print_success "Логи очищены"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}                                                          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${BOLD}${WHITE}Программа полностью удалена!${NC}                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                          ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${WHITE}Все данные, настройки и сервисы удалены.${NC}"
echo -e "${WHITE}Для повторной установки запустите:${NC}"
echo -e "${CYAN}  sudo bash install.sh${NC}"
echo ""
