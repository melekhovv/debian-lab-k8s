# Сохраняет текущее состояние всех машин (сервер + 3 клиента).
# Запускать после установки пакетов / настройки конфигов и перед остановкой кластера.
#   -NoExport  не копировать бэкапы на диск Windows (быстрее, но копия только в ноде Minikube)
#   -Force     сохранить даже машину, состояние которой ещё не было восстановлено после перезапуска
#   -NoPause   не ждать Enter в конце (для вызова из других скриптов)
param([switch]$NoExport, [switch]$Force, [switch]$NoPause)
$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "lab-common.ps1")
Assert-LabTool "kubectl" $kubectl "KubectlPath"

# Сервисы, которые пишут файлы базы данных: на время копирования их останавливаем,
# иначе копия базы может оказаться несогласованной.
$dbServices = @("zabbix-server", "mariadb", "mysql", "postgresql")

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Сохранение состояния машин...             " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

$null = Invoke-Node "true"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Нода Minikube не запущена: сохранять нечего." -ForegroundColor Red
    if (-not $NoPause) { Read-Host "Нажмите Enter для выхода" }
    exit 1
}
$excludes = Get-LabExcludeArgs
$saved = @()

foreach ($m in $LabMachines) {
    $name = $m.Name
    $bak  = $m.Backup
    Write-Host ""
    Write-Host "[$name] Ищу контейнер..." -ForegroundColor Yellow

    $pod = Get-LabPod $name
    $ctr = Get-LabContainer $name
    if (-not $pod -or -not $ctr) { Add-LabProblem "[$name] контейнер не запущен, пропущен"; continue }

    # Свежий контейнер (после перезапуска, до start-debian) пуст: его сохранение затёрло бы бэкап.
    & $kubectl exec -n $LabNamespace $pod -- test -e /run/lab-restored 2>$null
    $restored = ($LASTEXITCODE -eq 0)
    # (start-debian ставит отметку и машинам без бэкапа, поэтому её отсутствие = контейнер не подготовлен)
    if (-not $restored -and -not $Force) {
        Add-LabProblem "[$name] машина ещё не подготовлена после перезапуска (сначала запустите start-debian.bat); бэкап не тронут. Перезаписать всё равно: save-state.ps1 -Force"
        continue
    }

    $upper = Get-LabUpperDir $ctr
    if (-not $upper) { Add-LabProblem "[$name] не удалось найти upperdir, пропущен"; continue }

    # Останавливаем сервисы БД, которые реально работают
    $stopped = @()
    foreach ($svc in $dbServices) {
        & $kubectl exec -n $LabNamespace $pod -- sh -c "test -x /etc/init.d/$svc && service $svc status >/dev/null 2>&1" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[$name] Останавливаю $svc на время копирования..." -ForegroundColor Gray
            & $kubectl exec -n $LabNamespace $pod -- service $svc stop 2>&1 | Out-Null
            $stopped += $svc
        }
    }

    Write-Host "[$name] Сохраняю слой $upper в $bak ..." -ForegroundColor Yellow
    # Новая копия пишется рядом и подменяет старую только после успешного завершения
    Invoke-Node "rm -rf '$bak/fs.new' && mkdir -p '$bak' && rsync -aHAX --numeric-ids $excludes '$upper/' '$bak/fs.new/'"
    $ok = ($LASTEXITCODE -eq 0)
    if ($ok) {
        Invoke-Node "rm -rf '$bak/fs.old'; if [ -d '$bak/fs' ]; then mv '$bak/fs' '$bak/fs.old'; fi; mv '$bak/fs.new' '$bak/fs' && rm -rf '$bak/fs.old' && date -Iseconds > '$bak/saved-at'"
        $ok = ($LASTEXITCODE -eq 0)
    }

    # Возвращаем сервисы в обратном порядке (сначала база, потом zabbix-server)
    [array]::Reverse($stopped)
    foreach ($svc in $stopped) { & $kubectl exec -n $LabNamespace $pod -- service $svc start 2>&1 | Out-Null }

    if ($ok) {
        $size = (Invoke-Node "du -sh '$bak/fs' | cut -f1" | Out-String).Trim()
        Write-Host "[$name] OK, сохранено: $size" -ForegroundColor Green
        $saved += $m
    } else {
        Invoke-Node "rm -rf '$bak/fs.new'" | Out-Null
        Add-LabProblem "[$name] ошибка копирования, прежний бэкап оставлен без изменений"
    }
}

# Копия на диск Windows: переживает minikube delete и сброс Docker Desktop
if (-not $NoExport -and $saved.Count -gt 0) {
    Write-Host ""
    Write-Host "Копирую бэкапы на диск Windows: $BackupDir" -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    foreach ($m in $saved) {
        $tgz  = Join-Path $BackupDir "$($m.Export).tgz"
        $node = "/var/tmp/lab-export-$($m.Export).tgz"   # не /tmp: docker cp не читает из tmpfs
        Invoke-Node "tar --numeric-owner --xattrs --xattrs-include='*' -czf '$node' -C '$($m.Backup)' fs saved-at"
        $ok = ($LASTEXITCODE -eq 0)
        if ($ok) { docker cp "minikube:$node" "$tgz.tmp"; $ok = ($LASTEXITCODE -eq 0) }
        Invoke-Node "rm -f '$node'" | Out-Null
        if ($ok) {
            if (Test-Path -LiteralPath $tgz) { Move-Item -Force -LiteralPath $tgz -Destination "$tgz.prev" }
            Move-Item -Force -LiteralPath "$tgz.tmp" -Destination $tgz
            Write-Host "[$($m.Name)] -> $tgz ($([math]::Round((Get-Item $tgz).Length / 1MB)) МБ)" -ForegroundColor Green
        } else {
            Remove-Item -Force -LiteralPath "$tgz.tmp" -ErrorAction SilentlyContinue
            Add-LabProblem "[$($m.Name)] не удалось скопировать бэкап на диск Windows"
        }
    }
}

Write-Host ""
if ($LabProblems.Count -eq 0) {
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Состояние всех машин сохранено.           " -ForegroundColor Green
    Write-Host "  При следующем запуске start-debian.bat    " -ForegroundColor Green
    Write-Host "  оно восстановится автоматически.          " -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
} else {
    Write-Host "============================================" -ForegroundColor Red
    Write-Host "  Сохранено не всё ($($saved.Count) из $($LabMachines.Count)). Проблемы:" -ForegroundColor Red
    $LabProblems | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
    Write-Host "============================================" -ForegroundColor Red
}
Write-Host ""
if (-not $NoPause) { Read-Host "Нажмите Enter для выхода" }
if ($LabProblems.Count -gt 0) { exit 1 }
