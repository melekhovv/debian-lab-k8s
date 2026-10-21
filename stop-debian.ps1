# Stops the lab. Offers to save machine state first, then stops or pauses Minikube.
. (Join-Path $PSScriptRoot "lab-common.ps1")
Assert-LabTool "minikube" $minikube "MinikubePath"

$mkStatus = & $minikube status 2>&1 | Out-String
if ($mkStatus -notmatch "host: Running") {
    Write-Host "Minikube is not running, nothing to stop." -ForegroundColor Gray
    exit 0
}

Write-Host "Everything not saved by save-state is lost when the cluster stops." -ForegroundColor Yellow
$answer = Read-Host "Save machine state first? [Y/n]"
if ($answer -notmatch '^(n|no|н|нет)$') {
    & (Join-Path $PSScriptRoot "save-state.ps1") -NoPause
    if ($LASTEXITCODE -ne 0) {
        $go = Read-Host "Saving reported problems (see above). Stop anyway? [y/N]"
        if ($go -notmatch '^(y|yes|д|да)$') { exit 1 }
    }
}

Write-Host ""
Write-Host "  1 - stop  (frees RAM and CPU; machines restart on next start-debian)"
Write-Host "  2 - pause (keeps machines running in memory, resumes instantly; RAM is NOT freed)"
$mode = Read-Host "Choose [1]"
if ($mode -eq "2") {
    Write-Host "Pausing Minikube..." -ForegroundColor Yellow
    & $minikube pause
} else {
    Write-Host "Stopping Minikube..." -ForegroundColor Yellow
    & $minikube stop
}
exit $LASTEXITCODE
