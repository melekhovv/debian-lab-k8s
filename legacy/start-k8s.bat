@echo off
chcp 65001 >nul
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Запрос прав Администратора (нажмите ДА в окне UAC)...
    powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
title Minikube Kubernetes - Debian Desktop
echo ==========================================================
echo Запуск кластера Kubernetes и Debian с графическим интерфейсом
echo ==========================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-in-k8s.ps1"
pause
