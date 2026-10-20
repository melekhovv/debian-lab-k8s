@echo off
title Сохранение состояния Debian Lab
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0save-state.ps1"
if %errorlevel% neq 0 pause
