@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1

title Telegram Connection Bot - Установка

echo.
echo ╔══════════════════════════════════════════════════════════╗
echo ║                                                          ║
echo ║         Telegram Connection Bot - Установка              ║
echo ║         UltimateTelegramConnectionBotGO                  ║
echo ║                                                          ║
echo ╚══════════════════════════════════════════════════════════╝
echo.

:: ── Check Go ──
echo ┌──────────────────────────────────────────────────────────┐
echo │  ШАГ 1/5: Проверка Go
echo └──────────────────────────────────────────────────────────┘
echo.

where go >nul 2>&1
if %errorlevel% neq 0 (
    echo [!] Go не установлен!
    echo     Скачайте и установите с: https://go.dev/dl/
    echo     Выберите версию с установщиком (рекомендуется .msi)
    echo     При установке убедитесь что gcc доступен (TDM-GCC или MinGW)
    echo     Затем перезапустите этот скрипт.
    echo.
    pause
    exit /b 1
)

for /f "tokens=*" %%i in ('go version') do set GO_VERSION=%%i
echo [+] Go найден: %GO_VERSION%
echo.

:: ── Bot Data Input ──
echo ┌──────────────────────────────────────────────────────────┐
echo │  ШАГ 2/5: Ввод данных бота
echo └──────────────────────────────────────────────────────────┘
echo.

echo Введите токен бота от @BotFather:
echo Пример: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz
echo.
set /p BOT_TOKEN="BOT_TOKEN -> "

if "!BOT_TOKEN!"=="" (
    echo [X] Токен не может быть пустым!
    pause
    exit /b 1
)

echo.
echo Введите ваш Telegram ID:
echo Узнать ID можно через бота @userinfobot
echo.
set /p ADMIN_ID="ADMIN_ID -> "

echo.
echo [+] Данные получены
echo.

:: ── Create Directory ──
echo ┌──────────────────────────────────────────────────────────┐
echo │  ШАГ 3/5: Создание директории
echo └──────────────────────────────────────────────────────────┘
echo.

set "INSTALL_DIR=%~dp0tgbot"
if exist "%INSTALL_DIR%" (
    echo [!] Директория уже существует: %INSTALL_DIR%
    echo     Нажмите Enter чтобы продолжить (файлы будут перезаписаны)
    pause >nul
)

mkdir "%INSTALL_DIR%" 2>nul
echo [+] Директория создана: %INSTALL_DIR%
echo.

:: ── Copy & Build ──
echo ┌──────────────────────────────────────────────────────────┐
echo │  ШАГ 4/5: Копирование и сборка
echo └──────────────────────────────────────────────────────────┘
echo.

set "SCRIPT_DIR=%~dp0"

xcopy "%SCRIPT_DIR%cmd" "%INSTALL_DIR%\cmd\" /E /I /Q >nul
xcopy "%SCRIPT_DIR%internal" "%INSTALL_DIR%\internal\" /E /I /Q >nul
copy "%SCRIPT_DIR%go.mod" "%INSTALL_DIR%\" >nul
copy "%SCRIPT_DIR%go.sum" "%INSTALL_DIR%\" >nul 2>nul
copy "%SCRIPT_DIR%update.bat" "%INSTALL_DIR%\" >nul 2>nul
copy "%SCRIPT_DIR%install.bat" "%INSTALL_DIR%\" >nul 2>nul
copy "%SCRIPT_DIR%uninstall.bat" "%INSTALL_DIR%\" >nul 2>nul
copy "%SCRIPT_DIR%update.sh" "%INSTALL_DIR%\" >nul 2>nul
copy "%SCRIPT_DIR%install.sh" "%INSTALL_DIR%\" >nul 2>nul
copy "%SCRIPT_DIR%uninstall.sh" "%INSTALL_DIR%\" >nul 2>nul

echo [+] Файлы скопированы
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

echo [+] Бот собран успешно
echo.

:: ── Save Config ──
echo ┌──────────────────────────────────────────────────────────┐
echo │  ШАГ 5/5: Настройка сервиса
echo └──────────────────────────────────────────────────────────┘
echo.

(
echo BOT_TOKEN=%BOT_TOKEN%
echo ADMIN_ID=%ADMIN_ID%
) > "%INSTALL_DIR%\.env"

echo [+] Конфигурация сохранена
echo.

set "SERVICE_NAME=TGConnectionBot"

sc query "%SERVICE_NAME%" >nul 2>&1
if %errorlevel% equ 0 (
    echo [!] Сервис уже существует. Удаление...
    sc stop "%SERVICE_NAME%" >nul 2>&1
    timeout /t 2 /nobreak >nul
    sc delete "%SERVICE_NAME%" >nul 2>&1
    timeout /t 2 /nobreak >nul
)

set "BATCH_PATH=%INSTALL_DIR%\run.bat"
(
echo @echo off
echo chcp 65001 ^>nul
echo cd /d "%INSTALL_DIR%"
echo for /f "tokens=1,* delims==" %%%%a in ^(.env^) do set %%%%a=%%%%b
echo tgbot.exe
) > "%BATCH_PATH%"

powershell -Command "$batchPath = '%BATCH_PATH%'; $shortcutPath = '%INSTALL_DIR%\StartBot.lnk'; $WshShell = New-Object -ComObject WScript.Shell; $Shortcut = $WshShell.CreateShortcut($shortcutPath); $Shortcut.TargetPath = $batchPath; $Shortcut.WorkingDirectory = '%INSTALL_DIR%'; $Shortcut.Save()"

echo [+] Создан ярлык: %INSTALL_DIR%\StartBot.lnk
echo.

powershell -Command "$action = New-ScheduledTaskAction -Execute '%BATCH_PATH%'; $trigger = New-ScheduledTaskTrigger -AtLogOn; $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable; $principal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Limited; Register-ScheduledTask -TaskName '%SERVICE_NAME%' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force >$null 2>&1; if ($?) { Write-Host '[+] Сервис добавлен в автозагрузку (Планировщик заданий)' } else { Write-Host '[!] Не удалось добавить в автозагрузку' }"

echo.
echo ╔══════════════════════════════════════════════════════════╗
echo ║                                                          ║
echo ║              Установка завершена успешно!                ║
echo ║                                                          ║
echo ╚══════════════════════════════════════════════════════════╝
echo.
echo Директория:      %INSTALL_DIR%
echo Конфиг:          %INSTALL_DIR%\.env
echo Настройки бота:  %INSTALL_DIR%\settings.json
echo.
echo Управление:
echo   Запуск:        %INSTALL_DIR%\StartBot.lnk
echo   Остановка:     Закройте окно терминала
echo   Автозапуск:    Добавлен в Планировщик заданий
echo.
echo Для настройки сообщений используйте /settings в боте
echo.
pause
