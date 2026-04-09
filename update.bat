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
set "REPO=Blix-Platform/UltimateTelegramConnectionBotGO"

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

:: ── Check commits ──
echo ┌──────────────────────────────────────────────────────────┐
echo │  ШАГ 2/4: Проверка коммитов [UP]
echo └──────────────────────────────────────────────────────────┘
echo.

set "CURRENT_COMMIT="
if exist "%INSTALL_DIR%\.commit" (
    set /p CURRENT_COMMIT=<"%INSTALL_DIR%\.commit"
)

echo [+] Проверка коммитов с GitHub...

:: Get commits
set "COMMITS_FILE=%TEMP%\tgbot_commits.json"
curl -fsSL --max-time 15 "https://api.github.com/repos/%REPO%/commits?per_page=50" -o "%COMMITS_FILE%" 2>nul
if not exist "%COMMITS_FILE%" (
    echo [X] Не удалось получить коммиты
    pause
    exit /b 1
)

:: Find first [UP] commit
set "UP_COMMIT="
set "UP_MESSAGE="

for /f "tokens=*" %%A in ('powershell -Command "$c=Get-Content '%COMMITS_FILE%' -Raw | ConvertFrom-Json; foreach($x in $c){ $m=$x.commit.message; if($m -match '^\[UP\]'){Write-Host \"$($x.sha)|$($m -replace '^\[UP\]\s*',''); break}}"') do (
    for /f "tokens=1,2 delims=|" %%B in ("%%A") do (
        set "UP_COMMIT=%%B"
        set "UP_MESSAGE=%%C"
    )
)

if not defined UP_COMMIT (
    if defined CURRENT_COMMIT (
        echo [i] Нет новых коммитов [UP]
        pause
        exit /b 0
    )
    echo [i] Коммитов [UP] не найдено, используется последний коммит
    for /f "tokens=*" %%A in ('powershell -Command "$c=Get-Content '%COMMITS_FILE%' -Raw | ConvertFrom-Json; Write-Host $c[0].sha"') do set "UP_COMMIT=%%A"
)

if not defined UP_COMMIT (
    echo [X] Не найдено коммитов для обновления
    del "%COMMITS_FILE%" 2>nul
    pause
    exit /b 1
)

echo [+] Коммит: %UP_COMMIT:~0,7% — %UP_MESSAGE%
echo.

del "%COMMITS_FILE%" 2>nul

:: ── Download changed files ──
echo ┌──────────────────────────────────────────────────────────┐
echo │  ШАГ 3/4: Загрузка изменённых файлов
echo └──────────────────────────────────────────────────────────┘
echo.

set "TEMP_DIR=%TEMP%\tgbot-update-%RANDOM%"
mkdir "%TEMP_DIR%" 2>nul

:: Get file list from commit
set "DETAIL_FILE=%TEMP%\tgbot_detail.json"
curl -fsSL --max-time 15 "https://api.github.com/repos/%REPO%/commits/%UP_COMMIT%" -o "%DETAIL_FILE%" 2>nul

set UPDATED=0
set SKIPPED=0
set ERRORS=0

:: Download each relevant file
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

    curl -fsSL --max-time 30 "https://raw.githubusercontent.com/%REPO%/%UP_COMMIT%/!REL_PATH!" -o "%TEMP_DIR%\new_file" 2>nul
    if not exist "%TEMP_DIR%\new_file" (
        echo [!] Пропуск !REL_PATH! (не найден)
        set /a SKIPPED+=1
    ) else (
        if exist "%INSTALL_DIR%\!REL_PATH!" (
            fc /b "%TEMP_DIR%\new_file" "%INSTALL_DIR%\!REL_PATH!" >nul 2>&1
            if !errorlevel! equ 0 (
                set /a SKIPPED+=1
            ) else (
                copy /Y "%TEMP_DIR%\new_file" "%INSTALL_DIR%\!REL_PATH!" >nul
                set /a UPDATED+=1
            )
        ) else (
            mkdir "%INSTALL_DIR%\!REL_PATH!\.." 2>nul
            copy /Y "%TEMP_DIR%\new_file" "%INSTALL_DIR%\!REL_PATH!" >nul
            set /a UPDATED+=1
        )
    )
    del "%TEMP_DIR%\new_file" 2>nul
)

:: Download internal/ as ZIP
curl -fsSL --max-time 120 "https://github.com/%REPO%/archive/%UP_COMMIT%.zip" -o "%TEMP_DIR%\source.zip" 2>nul
if exist "%TEMP_DIR%\source.zip" (
    powershell -Command "Expand-Archive -Path '%TEMP_DIR%\source.zip' -DestinationPath '%TEMP_DIR%\extracted' -Force"
    for /d %%D in ("%TEMP_DIR%\extracted\*") do (
        if exist "%%D\internal\" (
            robocopy "%%D\internal" "%INSTALL_DIR%\internal" /MIR /NJH /NJS /NFL /NDL
        )
    )
)

:: Save commit
echo %UP_COMMIT%>"%INSTALL_DIR%\.commit"

del "%TEMP_DIR%\source.zip" 2>nul
rmdir /s /q "%TEMP_DIR%" 2>nul

echo [+] Обновлено файлов: %UPDATED%
echo [+] Пропущено файлов: %SKIPPED%
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
echo Commit: %UP_COMMIT:~0,7%
echo [+] Все данные сохранены. Бот работает.
echo.
pause
