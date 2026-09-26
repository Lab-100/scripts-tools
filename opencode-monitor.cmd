@echo off
rem Оперативный монитор оркестратора (двойной клик из Explorer) - консоль скрыта.
set "TOOLS=%~dp0"
cd /d "%TOOLS%"
start "" /min pwsh -NoProfile -WindowStyle Hidden -Command "& { [Console]::Title='opencode-monitor'; & (Join-Path $env:TOOLS 'opencode-monitor.ps1') }"