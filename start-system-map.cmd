@echo off
REM system-map: long-running local server via run-watch -Detach.
REM Owner may stop it; the watchdog does not unload it automatically.
pwsh -NoProfile -File "%~dp0system-map.ps1" -DetachServe -Port 8765
if errorlevel 1 exit /b %errorlevel%
echo system-map: http://127.0.0.1:8765
