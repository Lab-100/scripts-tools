@echo off
rem Текстовой монитор инфраструктуры opencode (консоль, живое обновление).
set "TOOLS=%~dp0"
cd /d "%TOOLS%"
start "" /min pwsh -NoProfile -Command "& { [Console]::Title='opencode-status'; & (Join-Path $env:TOOLS 'opencode-status.ps1') -Watch 3 }"