@echo off
chcp 65001 >nul
title Остановка Debian Desktop (Kubernetes)

echo ==========================================================
echo   Остановка кластера Kubernetes для освобождения памяти
echo ==========================================================
echo.

set "PATH=%PATH%;C:\Users\nise0\AppData\Local\Programs"

echo Приостановка Minikube...
minikube pause
if %errorlevel% neq 0 (
    minikube stop
)

echo.
echo Кластер остановлен. Память и процессор освобождены!
echo Для повторного запуска используйте start-debian.bat
echo.
pause
