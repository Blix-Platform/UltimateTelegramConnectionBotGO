@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1

title Telegram Connection Bot - Удаление

echo.
echo ╔══════════════════════════════════════════════════════════╗
echo ║                                                          ║
echo ║         Telegram Connection Bot - Полное удаление        ║
echo ║         UltimateTelegramConnectionBotGO                  ║
echo ║                                                          ║
echo ╚══════════════════════════════════════════════════════════╝
echo.

echo ⚠️  ВНИМАНИЕ: Это действие удалит:
echo    • Сервис из Планировщика заданий
echo    • Директорию tgbot
echo    • Базу данных SQLite (bot.db)
echo    • Все настройки и данные
echo.
echo Эти действия необратимы!
echo.

set /p CONFIRM="Вы уверены? Введите 'да' для подтверждения: "
if /i not "!CONFIRM!"=="да" (
    echo.
    echo [i] Удаление отменено
    pause
    exit /b 0
)

echo.
set "INSTALL_DIR=%~dp0tgbot"
set "SERVICE_NAME=TGConnectionBot"

echo [1/5] Удаление из Планировщика заданий...
schtasks /query /tn "%SERVICE_NAME%" >nul 2>&1
if %errorlevel% equ 0 (
    schtasks /delete /tn "%SERVICE_NAME%" /f >nul 2>&1
    echo [+] Задача удалена
) else (
    echo [i] Задача не найдена
)

echo.
echo [2/5] Остановка процесса...
taskkill /im tgbot.exe /f >nul 2>&1
if %errorlevel% equ 0 (
    echo [+] Процесс остановлен
) else (
    echo [i] Процесс не запущен
)

echo.
echo [3/5] Удаление директории...
if exist "%INSTALL_DIR%" (
    rmdir /s /q "%INSTALL_DIR%"
    echo [+] Директория удалена: %INSTALL_DIR%
) else (
    echo [i] Директория не найдена
)

echo.
echo [4/5] Удаление файлов из текущей папки...
del /f /q "%~dp0tgbot.exe" >nul 2>&1
del /f /q "%~dp0bot.db" >nul 2>&1
del /f /q "%~dp0.settings" >nul 2>&1
echo [+] Временные файлы удалены

echo.
echo [5/5] Очистка логов...
del /f /q "%INSTALL_DIR%.log" >nul 2>&1
echo [+] Логи очищены

echo.
echo ╔══════════════════════════════════════════════════════════╗
echo ║                                                          ║
echo ║              Программа полностью удалена!                ║
echo ║                                                          ║
echo ╚══════════════════════════════════════════════════════════╝
echo.
echo Все данные, настройки и сервисы удалены.
echo Для повторной установки запустите: install.bat
echo.
pause
