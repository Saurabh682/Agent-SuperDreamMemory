@echo off
rem Double-click to open the Agent Memory Kit menu.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
echo.
pause
