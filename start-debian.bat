@echo off
title Debian Desktop в Kubernetes
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-debian.ps1"
if %errorlevel% neq 0 pause
