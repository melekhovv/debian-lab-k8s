# Common loader for Debian Lab scripts. Use: . (Join-Path $PSScriptRoot "lab-common.ps1")
# Loads lab.config.ps1 (created from the example if missing) and resolves tool paths.

$LabRoot    = $PSScriptRoot
$cfgFile    = Join-Path $LabRoot "lab.config.ps1"
$cfgExample = Join-Path $LabRoot "lab.config.example.ps1"

if (-not (Test-Path -LiteralPath $cfgFile) -and (Test-Path -LiteralPath $cfgExample)) {
    Copy-Item -LiteralPath $cfgExample -Destination $cfgFile
    Write-Host "Created lab.config.ps1 from lab.config.example.ps1" -ForegroundColor Yellow
}
if (Test-Path -LiteralPath $cfgFile) { . $cfgFile }

# Defaults for anything missing in the config
if (-not $ServerPort)  { $ServerPort  = 3000 }
if (-not $ClientPorts) { $ClientPorts = @(3001, 3002, 3003) }
if (-not $BindAddress) { $BindAddress = "0.0.0.0" }
if (@($ClientPorts).Count -ne 3) {
    Write-Host "ERROR: `$ClientPorts in lab.config.ps1 must contain exactly 3 ports." -ForegroundColor Red
    Read-Host "Press Enter to exit..."
    exit 1
}

# Make docker/minikube/kubectl reachable by name
$extraPaths = @(
    "$env:LOCALAPPDATA\Programs",
    "$env:LOCALAPPDATA\Programs\DockerDesktop\resources\bin",
    "$env:ProgramFiles\Docker\Docker\resources\bin"
)
foreach ($p in $extraPaths) {
    if ((Test-Path -LiteralPath $p) -and ($env:Path -notlike "*$p*")) { $env:Path += ";$p" }
}

function Resolve-LabTool {
    param([string]$Configured, [string]$Name, [string[]]$Candidates)
    if ($Configured -and (Test-Path -LiteralPath $Configured)) { return $Configured }
    if ($Name) {
        $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Assert-LabTool {
    param([string]$Label, $Path, [string]$ConfigVar)
    if (-not $Path) {
        Write-Host "ERROR: $Label not found. Install it or set `$$ConfigVar in lab.config.ps1" -ForegroundColor Red
        Read-Host "Press Enter to exit..."
        exit 1
    }
}

$minikube  = Resolve-LabTool $MinikubePath "minikube" @("$env:LOCALAPPDATA\Programs\minikube.exe")
$kubectl   = Resolve-LabTool $KubectlPath  "kubectl"  @("$env:LOCALAPPDATA\Programs\kubectl.exe")
$dockerExe = Resolve-LabTool $DockerDesktopExe "" @(
    "$env:LOCALAPPDATA\Programs\DockerDesktop\Docker Desktop.exe",
    "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
)
