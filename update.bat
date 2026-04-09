@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1

title Telegram Connection Bot - Обновление

echo.
echo ╔══════════════════════════════════════════════════════════╗
echo ║                                                          ║
echo ║         Telegram Connection Bot - Обновление             ║
echo ║         UltimateTelegramConnectionBotGO                  ║
echo ║                                                          ║
echo ╚══════════════════════════════════════════════════════════╝
echo.

set "SCRIPT_DIR=%~dp0"
set "INSTALL_DIR=%SCRIPT_DIR%"

:: ── Check Go ──
echo ┌──────────────────────────────────────────────────────────┐
echo │  ШАГ 1/4: Проверка установки
echo └──────────────────────────────────────────────────────────┘
echo.

where go >nul 2>&1
if %errorlevel% neq 0 (
    echo [X] Go не установлен! Установите с https://go.dev/dl/
    pause
    exit /b 1
)

for /f "tokens=*" %%i in ('go version') do set GO_VERSION=%%i
echo [+] Go найден: %GO_VERSION%
echo.

if not exist "%INSTALL_DIR%\cmd" (
    echo [X] Бот не установлен. Сначала запустите install.bat
    pause
    exit /b 1
)

if not exist "%INSTALL_DIR%\.env" (
    echo [X] Файл конфигурации не найден.
    pause
    exit /b 1
)

:: ── Download ZIP ──
echo ┌──────────────────────────────────────────────────────────┐
echo │  ШАГ 2/4: Загрузка последней версии
echo └──────────────────────────────────────────────────────────┘
echo.

set "TEMP_DIR=%TEMP%\tgbot-update-%RANDOM%"
mkdir "%TEMP_DIR%" 2>nul

curl -fsSL -L --max-time 120 "https://github.com/Blix-Platform/UltimateTelegramConnectionBotGO/archive/refs/heads/main.zip" -o "%TEMP_DIR%\release.zip"

if not exist "%TEMP_DIR%\release.zip" (
    echo [X] Не удалось загрузить архив
    rmdir /s /q "%TEMP_DIR%" 2>nul
    pause
    exit /b 1
)

echo [+] Архив загружен
echo.

:: ── Extract ──
echo ┌──────────────────────────────────────────────────────────┐
echo │  ШАГ 3/4: Распаковка и обновление файлов
echo └──────────────────────────────────────────────────────────┘
echo.

powershell -Command "Expand-Archive -Path '%TEMP_DIR%\release.zip' -DestinationPath '%TEMP_DIR%\extracted' -Force"

:: Find source directory
for /d %%D in ("%TEMP_DIR%\extracted\*") do set "SRC_DIR=%%D"

if not defined SRC_DIR (
    echo [X] Не удалось распаковать архив
    rmdir /s /q "%TEMP_DIR%" 2>nul
    pause
    exit /b 1
)

:: Backup .env
set "ENV_BACKUP="
if exist "%INSTALL_DIR%\.env" (
    type "%INSTALL_DIR%\.env" > "%TEMP_DIR%\.env.bak"
)

:: Copy only changed files
set UPDATED=0
set SKIPPED=0

for %%F in (
    "cmd\bot\main.go"
    "go.mod"
    "go.sum"
    "update.bat"
    "update.sh"
    "install.bat"
    "install.sh"
    "uninstall.bat"
    "uninstall.sh"
    ".gitignore"
) do (
    set "REL_PATH=%%~F"
    set "REL_PATH=!REL_PATH:"=!"

    if exist "%SRC_DIR%\!REL_PATH!" (
        set "NEED_COPY=1"
        if exist "%INSTALL_DIR%\!REL_PATH!" (
            for %%A in ("%SRC_DIR%\!REL_PATH!") do set "HASH_NEW=%%~tA"
            for %%A in ("%INSTALL_DIR%\!REL_PATH!") do set "HASH_OLD=%%~tA"
            if "!HASH_NEW!"=="!HASH_OLD!" set "NEED_COPY=0"
        )
        if "!NEED_COPY!"=="1" (
            copy /Y "%SRC_DIR%\!REL_PATH!" "%INSTALL_DIR%\!REL_PATH!" >nul
            set /a UPDATED+=1
        ) else (
            set /a SKIPPED+=1
        )
    )
)

:: Recursively copy internal\*
if exist "%SRC_DIR%\internal\" (
    robocopy "%SRC_DIR%\internal" "%INSTALL_DIR%\internal" /MIR /NJH /NJS /NFL /NDL >nul
)

:: Restore .env
if exist "%TEMP_DIR%\.env.bak" (
    copy /Y "%TEMP_DIR%\.env.bak" "%INSTALL_DIR%\.env" >nul
)

:: Cleanup temp
rmdir /s /q "%TEMP_DIR%" 2>nul

echo [+] Обновлён файлов: %UPDATED%
echo [+] Пропущен файлов: %SKIPPED%
echo.

:: ── Build ──
echo ┌──────────────────────────────────────────────────────────┐
echo │  ШАГ 4/4: Сборка и перезапуск
echo └──────────────────────────────────────────────────────────┘
echo.

cd /d "%INSTALL_DIR%"

echo     Загрузка зависимостей...
call go mod download >nul 2>&1

echo     Сборка...
call go build -o tgbot.exe .\cmd\bot\

if not exist "%INSTALL_DIR%\tgbot.exe" (
    echo [X] Ошибка сборки!
    pause
    exit /b 1
)

echo [+] Бот собран
echo.

:: Stop running bot
taskkill /im tgbot.exe /f >nul 2>&1
timeout /t 2 /nobreak >nul

:: Restart via Scheduled Task
set "SERVICE_NAME=TGConnectionBot"
schtasks /query /tn "%SERVICE_NAME%" >nul 2>&1
if %errorlevel% equ 0 (
    schtasks /run /tn "%SERVICE_NAME%" >nul 2>&1
    echo [+] Сервис перезапущен (Планировщик заданий)
) else (
    echo [i] Сервис не найден. Запустите бот вручную через StartBot.lnk
)

echo.
echo ╔══════════════════════════════════════════════════════════╗
echo ║                                                          ║
echo ║              Система обновлена!                          ║
echo ║                                                          ║
echo ╚══════════════════════════════════════════════════════════╝
echo.
echo [+] Все данные сохранены. Бот работает.
echo.
pause
