@echo off
chcp 65001 >nul
title Сохранение состояния Debian Lab
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0save-state.ps1"
