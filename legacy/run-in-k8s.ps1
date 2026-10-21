# Скрипт автоматического развёртывания Debian Desktop в Kubernetes (Minikube + Hyper-V)
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  [1/4] Запуск кластера Kubernetes (Minikube + Hyper-V)..." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Добавляем пользователя в группу Hyper-V (на будущее)
try {
    Add-LocalGroupMember -Group "Администраторы Hyper-V" -Member "$env:USERNAME" -ErrorAction SilentlyContinue
} catch {}

# Paths to minikube/kubectl come from ..\lab.config.ps1 (see ..\lab-common.ps1)
. (Join-Path $PSScriptRoot "..\lab-common.ps1")
Assert-LabTool "minikube" $minikube "MinikubePath"
Assert-LabTool "kubectl"  $kubectl  "KubectlPath"

# Запуск Minikube
& $minikube start --driver=hyperv --memory=4096 --cpus=2

if ($LASTEXITCODE -ne 0) {
    Write-Host "Повторная попытка запуска с виртуальным свитчем..." -ForegroundColor Yellow
    & $minikube start --driver=hyperv --hyperv-virtual-switch="Default Switch" --memory=4096 --cpus=2
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  [2/4] Проверка статуса кластера..." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

& $kubectl get nodes

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  [3/4] Развёртывание Debian с графическим интерфейсом XFCE..." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$manifest = Join-Path $PSScriptRoot "..\k8s\debian-webtop.yaml"
& $kubectl apply -f $manifest

Write-Host ""
Write-Host "Ожидание запуска контейнера Debian Desktop (скачивание образа)..." -ForegroundColor Yellow
& $kubectl rollout status deployment/debian-desktop -n debian-lab --timeout=600s

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  [4/4] Запуск доступа к графическому интерфейсу..." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$nodeIp = & $minikube ip 2>$null
$directUrl = "http://${nodeIp}:30080"
$localUrl = "http://localhost:3000"

Write-Host ""
Write-Host "****************************************************************" -ForegroundColor Green
Write-Host "  УСПЕХ! Debian Linux с рабочим столом XFCE запущен в Kubernetes!" -ForegroundColor Green
Write-Host ""
Write-Host "  Адрес в браузере:  $localUrl" -ForegroundColor Cyan
Write-Host "  Или напрямую:      $directUrl" -ForegroundColor Cyan
Write-Host "  Пользователь:      abc (sudo без пароля)" -ForegroundColor Yellow
Write-Host "****************************************************************" -ForegroundColor Green
Write-Host ""

# Открываем браузер
Start-Process $localUrl

Write-Host "Проксирование портов запущено. Не закрывайте это окно во время работы с Debian!" -ForegroundColor Green
Write-Host "Для завершения нажмите Ctrl+C." -ForegroundColor Yellow
Write-Host ""

& $kubectl port-forward svc/debian-desktop-service -n debian-lab 3000:3000
