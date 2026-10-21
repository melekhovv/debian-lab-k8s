@echo off
chcp 65001 >nul
title Остановка Debian Lab
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-debian.ps1"
echo.
pause
