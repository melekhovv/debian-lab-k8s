@echo off
chcp 65001 >nul
title Остановка Debian Desktop (Kubernetes)

echo ==========================================================
echo   Остановка кластера Kubernetes для освобождения памяти
echo ==========================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-debian.ps1"

echo.
echo Кластер остановлен. Память и процессор освобождены!
echo Для повторного запуска используйте start-debian.bat
echo.
pause
