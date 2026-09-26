@echo off
REM Перезапуск opencode Desktop + подъём mcp-watchdog и MCP-серверов.
REM Текущая сессия opencode при этом оборвётся. Сгенерировано вручную (инсталлер opencode-plugins делает только шимы мониторов).
setlocal
pwsh -NoProfile -NoLogo -File "%~dp0opencode-restart.ps1" %*
echo.
echo Завершено. Если окно закрылось сразу - запусти opencode из меню Пуск.
pause
