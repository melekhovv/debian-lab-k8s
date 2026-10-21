# Common loader for Debian Lab scripts. Use: . (Join-Path $PSScriptRoot "lab-common.ps1")
# Loads lab.config.ps1 (created from the example if missing), resolves tool paths,
# describes the lab topology and provides helpers shared by start/save/stop scripts.

$LabRoot    = $PSScriptRoot
$cfgFile    = Join-Path $LabRoot "lab.config.ps1"
$cfgExample = Join-Path $LabRoot "lab.config.example.ps1"

if (-not (Test-Path -LiteralPath $cfgFile) -and (Test-Path -LiteralPath $cfgExample)) {
    Copy-Item -LiteralPath $cfgExample -Destination $cfgFile
    Write-Host "Created lab.config.ps1 from lab.config.example.ps1" -ForegroundColor Yellow
}
if (Test-Path -LiteralPath $cfgFile) { . $cfgFile }

# Defaults for anything missing in the config
if (-not $ServerPort)     { $ServerPort     = 3000 }
if (-not $ClientPorts)    { $ClientPorts    = @(3001, 3002, 3003) }
if (-not $BindAddress)    { $BindAddress    = "127.0.0.1" }
if (-not $MinikubeCpus)   { $MinikubeCpus   = 4 }
if (-not $MinikubeMemory) { $MinikubeMemory = 6144 }
if ($null -eq $ServerServices) { $ServerServices = @("mariadb", "apache2", "zabbix-server", "zabbix-agent") }
if ($null -eq $ClientServices) { $ClientServices = @("zabbix-agent") }
if (-not $BackupDir)      { $BackupDir      = Join-Path $LabRoot "backups" }
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

# ---------------------------------------------------------------
# Lab topology: the single place that lists machines, ports and addresses.
# Client N lives in subnet $LabSubnets[N-1] as .1, the server is .254 in every subnet.
# ---------------------------------------------------------------
$LabNamespace = "debian-lab"
$LabSubnets   = @("192.168.2", "192.168.3", "192.168.4")

$LabServer = @{
    Name = "debian-desktop"; Service = "debian-desktop-service"; Port = $ServerPort
    Title = "Server (Zabbix)"; Backup = "/var/backup_desktop"; Export = "desktop"
    Services = @($ServerServices)
    Ips = @($LabSubnets | ForEach-Object { "$_.254" })
}
$LabClients = @()
for ($i = 0; $i -lt $LabSubnets.Count; $i++) {
    $n = $i + 1
    $LabClients += @{
        Name = "debian-client-$n"; Service = "debian-client-$n-service"; Port = $ClientPorts[$i]
        Title = "Client $n ($($LabSubnets[$i]).1)"; Backup = "/var/backup_client$n"; Export = "client$n"
        Services = @($ClientServices)
        Ip = "$($LabSubnets[$i]).1"; Subnet = $LabSubnets[$i]; Gateway = "$($LabSubnets[$i]).254"
    }
}
$LabMachines = @($LabServer) + $LabClients

# Paths never saved or restored: runtime sockets, locks and pid files of the previous session.
# Restoring them is what used to leave the desktop with "stale display/audio sockets".
$LabStateExcludes = @("/tmp/", "/run/", "/var/run/", "/dev/", "/proc/", "/sys/",
                      "/defaults/native", "/defaults/pid", "/var/lib/mysql/*.sock", "/var/cache/apt/archives/*.deb")

# ---------------------------------------------------------------
# Warnings collected during a run, printed in the final summary.
# ---------------------------------------------------------------
$script:LabProblems = New-Object System.Collections.Generic.List[string]
function Add-LabProblem([string]$Text) {
    $script:LabProblems.Add($Text)
    Write-Host "  ! $Text" -ForegroundColor Red
}

# Runs a shell command inside the Minikube node; returns stdout lines, sets $LASTEXITCODE.
function Invoke-Node([string]$Command) {
    docker exec minikube sh -c $Command
}

# Copies a text (script) into the node as a file without quoting problems.
function Set-NodeFile([string]$Path, [string]$Content) {
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Content.Replace("`r`n", "`n")))
    Invoke-Node "echo '$b64' | base64 -d > '$Path'"
}

# Name of the running (not terminating) pod of a deployment, or $null.
function Get-LabPod([string]$App) {
    $json = & $kubectl get pods -n $LabNamespace -l "app=$App" -o json 2>$null | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    $pod = (ConvertFrom-Json $json).items |
        Where-Object { $_.status.phase -eq "Running" -and -not $_.metadata.deletionTimestamp } |
        Select-Object -First 1
    if ($pod) { return $pod.metadata.name }
    return $null
}

# crictl data of the running container: Id, Pid, SnapshotKey, PodIp. $null if not found.
function Get-LabContainer([string]$Name) {
    $ids = @(Invoke-Node "crictl ps --state running --name '^$Name`$' -q")
    if ($LASTEXITCODE -ne 0 -or -not $ids -or -not $ids[0]) { return $null }
    $info = (Invoke-Node "crictl inspect $($ids[0])" | Out-String | ConvertFrom-Json).info
    return @{ Id = $ids[0].Trim(); Pid = $info.pid; SnapshotKey = $info.snapshotKey }
}

# overlayfs upperdir (the container's own writable layer) of a container.
function Get-LabUpperDir($Container) {
    $mounts = Invoke-Node "ctr -n k8s.io snapshots --snapshotter overlayfs mounts /mnt/tmp $($Container.SnapshotKey)" | Out-String
    if ($mounts -match "upperdir=([^,\s]+)") { return $Matches[1] }
    return $null
}

# Helper script inside the node that saves/restores a container layer correctly:
# overlay whiteouts (deleted files) and opaque directories are applied as deletions
# instead of being copied as character devices.
$LabStateTool = @'
#!/usr/bin/env python3
import fnmatch, os, shutil, stat, subprocess, sys

def whiteouts(src):
    """Paths (relative) deleted in the layer and directories marked opaque."""
    deleted, opaque = [], []
    for root, dirs, files in os.walk(src):
        for n in dirs + files:
            p = os.path.join(root, n)
            st = os.lstat(p)
            rel = os.path.relpath(p, src)
            if stat.S_ISCHR(st.st_mode) and st.st_rdev == 0:
                deleted.append(rel)
        try:
            if os.getxattr(root, "trusted.overlay.opaque") == b"y" and root != src:
                opaque.append(os.path.relpath(root, src))
        except OSError:
            pass
    return deleted, opaque

def remove(path):
    if os.path.islink(path) or os.path.isfile(path) or (os.path.exists(path) and not os.path.isdir(path)):
        os.unlink(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)

def restore(src, root, excludes):
    deleted, opaque = whiteouts(src)
    def excluded(rel):
        p = "/" + rel
        return any(fnmatch.fnmatch(p, e.rstrip("/")) or (p + "/").startswith(e.rstrip("/") + "/")
                   for e in excludes)
    for rel in deleted:
        if not excluded(rel):
            try: remove(os.path.join(root, rel))
            except OSError as e: print("warn: cannot delete /%s: %s" % (rel, e))
    for rel in opaque:
        if excluded(rel): continue
        target = os.path.join(root, rel)
        keep = set(os.listdir(os.path.join(src, rel)))
        if os.path.isdir(target):
            for n in os.listdir(target):
                if n not in keep:
                    try: remove(os.path.join(target, n))
                    except OSError as e: print("warn: cannot clear /%s/%s: %s" % (rel, n, e))
    exclude_file = "/var/tmp/lab-restore-excludes"
    with open(exclude_file, "w") as f:
        for e in excludes: f.write(e + "\n")
        for rel in deleted: f.write("/" + rel + "\n")
    r = subprocess.run(["rsync", "-aHAX", "--numeric-ids", "--exclude-from=" + exclude_file,
                        src.rstrip("/") + "/", root.rstrip("/") + "/"])
    print("restored: %d deleted, %d opaque dirs" % (len(deleted), len(opaque)))
    return r.returncode

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "restore":
        sys.exit(restore(sys.argv[2], sys.argv[3], sys.argv[4:]))
    print("usage: lab-state.py restore SRC ROOT [EXCLUDE...]"); sys.exit(2)
'@

function Install-LabStateTool {
    Set-NodeFile "/usr/local/bin/lab-state.py" $LabStateTool | Out-Null
    Invoke-Node "chmod +x /usr/local/bin/lab-state.py" | Out-Null
}

function Get-LabExcludeArgs {
    ($LabStateExcludes | ForEach-Object { "--exclude='$_'" }) -join " "
}
