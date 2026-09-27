@echo off
rem Перезапуск opencode (двойной клик из Explorer): поднимает демон-страж
rem и ждёт готовности MCP. Запускать из ОТДЕЛЬНОГО окна: текущая сессия
rem opencode при перезапуске обрывается.
set "TOOLS=%~dp0"
cd /d "%TOOLS%"
start "" pwsh -NoProfile -NoLogo -Command "& (Join-Path $env:TOOLS 'opencode-restart.ps1')"