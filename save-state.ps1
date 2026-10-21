# Сохраняет текущее состояние всех контейнеров (сервер + 3 клиента)
# Запускать после установки пакетов / настройки конфигов
$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "lab-common.ps1")   # adds docker to PATH

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Сохранение состояния контейнеров...       " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

$containers = @(
    @{ Name = "debian-desktop";  Backup = "/var/backup_desktop" },
    @{ Name = "debian-client-1"; Backup = "/var/backup_client1" },
    @{ Name = "debian-client-2"; Backup = "/var/backup_client2" },
    @{ Name = "debian-client-3"; Backup = "/var/backup_client3" }
)

foreach ($c in $containers) {
    $name = $c.Name
    $backupDir = $c.Backup

    Write-Host ""
    Write-Host "[$name] Ищу контейнер..." -ForegroundColor Yellow

    # Get container ID and PID
    $cid = (docker exec minikube crictl ps --name $name -q).Trim()
    if (-not $cid) {
        Write-Host "[$name] Контейнер не найден, пропускаю." -ForegroundColor Red
        continue
    }

    # Get snapshot key
    $snapshotKey = (docker exec minikube python3 -c "import json, subprocess; d=json.loads(subprocess.check_output(['crictl', 'inspect', '$cid'])); print(d['info']['snapshotKey'])").Trim()

    # Get upperdir from snapshot
    $mountInfo = (docker exec minikube ctr -n k8s.io snapshots --snapshotter overlayfs mounts /mnt/tmp $snapshotKey) | Out-String
    $upperdir = ""
    if ($mountInfo -match "upperdir=([^,]+)") {
        $upperdir = $Matches[1]
    }

    if (-not $upperdir) {
        Write-Host "[$name] Не удалось найти upperdir, пропускаю." -ForegroundColor Red
        continue
    }

    $size = (docker exec minikube du -sh $upperdir 2>$null) | Out-String
    Write-Host "[$name] Overlay: $upperdir ($($size.Trim()))" -ForegroundColor Gray

    # Remove old backup and create new
    Write-Host "[$name] Сохраняю состояние в $backupDir ..." -ForegroundColor Yellow
    docker exec minikube rm -rf "$backupDir" 2>$null
    docker exec minikube mkdir -p "$backupDir"
    docker exec minikube cp -a "$upperdir" "$backupDir/fs"

    if ($LASTEXITCODE -eq 0) {
        $backupSize = (docker exec minikube du -sh "$backupDir/fs" 2>$null) | Out-String
        Write-Host "[$name] OK! Сохранено: $($backupSize.Trim())" -ForegroundColor Green
    } else {
        Write-Host "[$name] ОШИБКА при сохранении!" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Состояние всех контейнеров сохранено!     " -ForegroundColor Green
Write-Host "  При следующем запуске start-debian.bat    " -ForegroundColor Green
Write-Host "  всё восстановится автоматически.          " -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Read-Host "Нажмите Enter для выхода"
