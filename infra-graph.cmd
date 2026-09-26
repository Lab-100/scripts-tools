@echo off
rem Карта инфраструктуры оркестратора (двойной клик из Explorer) - консоль свёрнута.
rem -STA обязателен: WinForms-форма живёт в STA-апартменте, без него окно/трей разрушаются.
set "TOOLS=%~dp0"
cd /d "%TOOLS%"
start "" /min pwsh -NoProfile -STA -Command "& { [Console]::Title='infra-graph'; & (Join-Path $env:TOOLS 'infra-graph.ps1') }"