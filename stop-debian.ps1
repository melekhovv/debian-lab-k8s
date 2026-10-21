# Pauses the Minikube cluster (falls back to stop) to free CPU and RAM.
. (Join-Path $PSScriptRoot "lab-common.ps1")
Assert-LabTool "minikube" $minikube "MinikubePath"

Write-Host "Pausing Minikube..." -ForegroundColor Yellow
& $minikube pause
if ($LASTEXITCODE -ne 0) {
    Write-Host "Pause failed, stopping Minikube..." -ForegroundColor Yellow
    & $minikube stop
}
