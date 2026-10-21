# Automatic starter for Debian Server and 3 Clients in Kubernetes
#   -NoBrowser  do not open the desktops in the browser
param([switch]$NoBrowser)
$ErrorActionPreference = "Continue"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Starting Debian Lab Network in Kubernetes...            " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

# Settings, tool paths, topology and helpers -> $minikube, $kubectl, $LabMachines, ...
. (Join-Path $PSScriptRoot "lab-common.ps1")
Assert-LabTool "minikube" $minikube "MinikubePath"
Assert-LabTool "kubectl"  $kubectl  "KubectlPath"

function Stop-Lab([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Read-Host "Press Enter to exit..."
    exit 1
}

# 1. Check Docker Desktop
Write-Host "[1/7] Checking Docker Desktop..." -ForegroundColor Yellow
$null = docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Starting Docker Desktop..." -ForegroundColor Yellow
    Assert-LabTool "Docker Desktop" $dockerExe "DockerDesktopExe"
    Start-Process $dockerExe
    Write-Host "Waiting for Docker Engine to start..." -ForegroundColor Yellow
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 3
        $null = docker info 2>&1
        if ($LASTEXITCODE -eq 0) { break }
        Write-Host "." -NoNewline -ForegroundColor Yellow
    }
    Write-Host ""
    if ($LASTEXITCODE -ne 0) { Stop-Lab "Could not connect to Docker. Please ensure Docker Desktop is running." }
    Write-Host "Docker Engine is ready!" -ForegroundColor Green
} else {
    Write-Host "Docker Desktop is already running." -ForegroundColor Green
}

# 2. Check Minikube
Write-Host ""
Write-Host "[2/7] Checking Kubernetes cluster (Minikube)..." -ForegroundColor Yellow
$mkStatus = & $minikube status 2>&1 | Out-String
if ($mkStatus -match "Paused") {
    Write-Host "Minikube is paused, resuming..." -ForegroundColor Yellow
    & $minikube unpause
}
$mkStatus = & $minikube status 2>&1 | Out-String
if ($mkStatus -notmatch "host: Running" -or $mkStatus -notmatch "apiserver: Running") {
    Write-Host "Starting Minikube cluster..." -ForegroundColor Yellow
    # --cpus/--memory only take effect when the cluster is created for the first time
    & $minikube start --driver=docker --cpus=$MinikubeCpus --memory=$MinikubeMemory
    if ($LASTEXITCODE -ne 0) { Stop-Lab "Minikube failed to start." }
} else {
    Write-Host "Minikube cluster is already running." -ForegroundColor Green
}
$nodeMemMb = [math]::Round([long]((docker inspect minikube --format "{{.HostConfig.Memory}}" | Out-String).Trim()) / 1MB)
if ($nodeMemMb -gt 0 -and $nodeMemMb -lt 6000) {
    Write-Host "WARNING: the Minikube node has only $nodeMemMb MB of RAM; 4 desktops need ~6 GB." -ForegroundColor Yellow
    Write-Host "         See README, section 'Resources', to recreate the cluster with more memory." -ForegroundColor Yellow
}

# 3. Apply manifests (idempotent: changes in k8s\*.yaml are picked up on every start)
Write-Host ""
Write-Host "[3/7] Applying manifests and waiting for pods..." -ForegroundColor Yellow
& $kubectl apply -f (Join-Path $PSScriptRoot "k8s\debian-webtop.yaml") -f (Join-Path $PSScriptRoot "k8s\debian-clients.yaml")
if ($LASTEXITCODE -ne 0) { Stop-Lab "kubectl apply failed." }
foreach ($m in $LabMachines) {
    # The first start downloads a ~1.5 GB image, so allow plenty of time
    & $kubectl rollout status "deployment/$($m.Name)" -n $LabNamespace --timeout=900s
    if ($LASTEXITCODE -ne 0) { Stop-Lab "Deployment $($m.Name) did not become ready. Check: kubectl get pods -n $LabNamespace" }
}

foreach ($m in $LabMachines) {
    $m.Pod = Get-LabPod $m.Name
    $ctr = Get-LabContainer $m.Name
    if (-not $m.Pod -or -not $ctr) { Stop-Lab "Running pod/container for $($m.Name) not found." }
    $m.Pid = $ctr.Pid
}
Install-LabStateTool

# 4. Restore saved state of machines whose container is fresh
Write-Host ""
Write-Host "[4/7] Restoring saved machine state..." -ForegroundColor Yellow
foreach ($m in $LabMachines) {
    $name = $m.Name
    $bak = $m.Backup
    # /run/lab-restored lives in the container layer: it disappears when the container is recreated
    $null = Invoke-Node "test -e /proc/$($m.Pid)/root/run/lab-restored"
    if ($LASTEXITCODE -eq 0) { Write-Host "[$name] state already in place." -ForegroundColor Green; continue }

    # Backup missing in the node (e.g. after minikube delete) -> import the copy from the Windows disk
    $null = Invoke-Node "test -d '$bak/fs'"
    $tgz = Join-Path $BackupDir "$($m.Export).tgz"
    if ($LASTEXITCODE -ne 0 -and (Test-Path -LiteralPath $tgz)) {
        Write-Host "[$name] importing backup from $tgz ..." -ForegroundColor Yellow
        $node = "/var/tmp/lab-import-$($m.Export).tgz"
        docker cp $tgz "minikube:$node"
        Invoke-Node "mkdir -p '$bak' && tar --numeric-owner --xattrs --xattrs-include='*' -xzf '$node' -C '$bak'; rc=`$?; rm -f '$node'; exit `$rc"
        if ($LASTEXITCODE -ne 0) { Add-LabProblem "[$name] import of $tgz failed" }
    }

    $null = Invoke-Node "test -d '$bak/fs'"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[$name] no saved state, starting clean." -ForegroundColor Gray
    } else {
        Write-Host "[$name] restoring from $bak ..." -ForegroundColor Yellow
        $exArgs = ($LabStateExcludes | ForEach-Object { "'$_'" }) -join " "
        Invoke-Node "python3 /usr/local/bin/lab-state.py restore '$bak/fs' /proc/$($m.Pid)/root $exArgs"
        if ($LASTEXITCODE -ne 0) {
            # No marker: save-state will refuse to overwrite the good backup with this broken state
            Add-LabProblem "[$name] restore failed; fix the problem and run start-debian again"
            continue
        }
    }
    Invoke-Node "mkdir -p /proc/$($m.Pid)/root/run && touch /proc/$($m.Pid)/root/run/lab-restored" | Out-Null
}

# 5. Network topology: server routes between the three client subnets
Write-Host ""
Write-Host "[5/7] Configuring IP network topology..." -ForegroundColor Yellow
$s = $LabServer
$net = @"
err=0
fail() { echo "network: `$*"; err=`$((err+1)); }
# Node-side veth of a pod (its eth0 is 'eth0@ifN', N = index of the peer in the node)
peer() {
  idx=`$(nsenter -t `$1 -n ip -o link show eth0 | sed -n 's/.*eth0@if\([0-9]*\).*/\1/p')
  ip -o link | awk -F': ' -v i="`$idx" '`$1==i { split(`$2, a, "@"); print a[1] }'
}
sysctl -qw net.ipv4.conf.all.proxy_arp=1 net.ipv4.conf.all.rp_filter=0 || fail "node sysctl"

SPID=$($s.Pid)
SV=`$(peer `$SPID); [ -n "`$SV" ] || fail "server veth not found"
SIP=`$(nsenter -t `$SPID -n ip -4 -o addr show dev eth0 | awk '{print `$4}' | cut -d/ -f1 | grep -v '^192\.168\.' | head -1)
# Packets forwarded by the server come back in through its veth with client source addresses
sysctl -qw net.ipv4.conf.`$SV.rp_filter=0 net.ipv4.conf.`$SV.proxy_arp=1 || fail "server veth sysctl"
nsenter -t `$SPID -n sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.send_redirects=0 net.ipv4.conf.eth0.send_redirects=0 || fail "server sysctl"
for ip in $($s.Ips -join " "); do
  nsenter -t `$SPID -n ip addr replace `$ip/24 dev eth0 || fail "server addr `$ip"
  ip route replace `$ip dev `$SV scope host || fail "node route `$ip"
done
# Table 100: everything from clients to lab subnets goes to the server first
ip route replace default via `$SIP dev `$SV onlink table 100 || fail "table 100"
while ip rule del pref 1000 2>/dev/null; do :; done
# Lab packets cross the node twice (client -> node -> server -> node -> client); conntrack
# marks the second pass INVALID and kube-proxy drops it, so lab-to-lab traffic is not tracked.
iptables -t raw -N LAB-NOTRACK 2>/dev/null; iptables -t raw -F LAB-NOTRACK
iptables -t raw -C PREROUTING -j LAB-NOTRACK 2>/dev/null || iptables -t raw -I PREROUTING -j LAB-NOTRACK || fail "raw PREROUTING"
for src in $(($LabSubnets | ForEach-Object { "$_.0/24" }) -join " "); do
  for dst in $(($LabSubnets | ForEach-Object { "$_.0/24" }) -join " "); do
    iptables -t raw -A LAB-NOTRACK -s `$src -d `$dst -j NOTRACK || fail "notrack `$src `$dst"
  done
done

"@
foreach ($c in $LabClients) {
    $others = $LabSubnets | Where-Object { $_ -ne $c.Subnet }
    $net += @"
CPID=$($c.Pid)
CV=`$(peer `$CPID); [ -n "`$CV" ] || fail "$($c.Name) veth not found"
sysctl -qw net.ipv4.conf.`$CV.proxy_arp=1 || fail "$($c.Name) veth sysctl"
nsenter -t `$CPID -n ip addr replace $($c.Ip)/24 dev eth0 || fail "$($c.Name) addr"
ip route replace $($c.Ip) dev `$CV scope host || fail "node route $($c.Ip)"
$(($others | ForEach-Object { "nsenter -t `$CPID -n ip route replace $_.0/24 via $($c.Gateway) dev eth0 || fail `"$($c.Name) route $_`"" }) -join "`n")
$(($LabSubnets | ForEach-Object { "ip rule add pref 1000 iif `$CV to $_.0/24 lookup 100 || fail `"$($c.Name) rule $_`"" }) -join "`n")

"@
}
$net += "exit `$err`n"
Set-NodeFile "/var/tmp/lab-network.sh" $net | Out-Null
Invoke-Node "sh /var/tmp/lab-network.sh"
if ($LASTEXITCODE -ne 0) { Add-LabProblem "network setup reported $LASTEXITCODE error(s), see messages above" }

# 6. Machine setup: hostname, tab titles, /zabbix proxy, services
Write-Host ""
Write-Host "[6/7] Configuring machines and starting services..." -ForegroundColor Yellow

# hostname/hostnamectl wrappers. /etc/hostname in a pod is managed by Kubernetes and is lost
# with the pod, so the name is also kept in /etc/lab-hostname (saved with the machine state)
# and applied to the kernel by this script on every start.
$hostnameScript = @'
#!/bin/bash
TARGET="$1"
if [ "$1" = "set-hostname" ] || [ "$1" = "hostname" ]; then
    TARGET="$2"
fi

if [ -z "$TARGET" ] || [[ "$TARGET" == -* ]]; then
    exec /bin/hostname "$@"
fi

echo "$TARGET" > /etc/lab-hostname
echo "$TARGET" > /etc/hostname 2>/dev/null
sed -i '/# lab-hostname$/d' /etc/hosts 2>/dev/null
echo "127.0.1.1 $TARGET # lab-hostname" >> /etc/hosts
if /bin/hostname "$TARGET" 2>/dev/null; then
    echo "Hostname set to: $(/bin/hostname)"
else
    echo "Hostname saved as '$TARGET'. It becomes active after the next start-debian (no permission to change it from inside the container)."
fi
'@
$hB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($hostnameScript.Replace("`r`n", "`n")))
Set-NodeFile "/var/tmp/lab-hostname.sh" @'
h=$(cat /proc/$1/root/etc/lab-hostname 2>/dev/null)
[ -n "$h" ] || exit 0
nsenter -t $1 -u hostname "$h" && echo "$h" > /proc/$1/root/etc/hostname && echo "[$2] hostname: $h"
'@ | Out-Null

# Tab title: idempotent (the injected script is replaced, not appended, on every run)
$titlePy = @'
import json, re, sys
t = sys.argv[1]
idx = '/usr/share/selkies/web/index.html'
c = open(idx).read()
c = re.sub(r'<script id="lab-title">.*?</script>', '', c, flags=re.S)
js = json.dumps(t)
c = re.sub(r'<title>.*?</title>', lambda m: '<title>%s</title><script id="lab-title">document.title=%s;setInterval(function(){if(document.title!=%s)document.title=%s},500);</script>' % (t, js, js, js), c, count=1, flags=re.S)
open(idx, 'w').write(c)
mf = '/usr/share/selkies/web/manifest.json'
m = json.load(open(mf))
m['name'] = m['short_name'] = t
json.dump(m, open(mf, 'w'))
'@
$tB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($titlePy.Replace("`r`n", "`n")))

foreach ($m in $LabMachines) {
    $p = $m.Pod
    & $kubectl exec -n $LabNamespace $p -- bash -c "echo '$hB64' | base64 -d > /usr/local/bin/hostname && chmod +x /usr/local/bin/hostname && cp /usr/local/bin/hostname /usr/local/bin/hostnamectl"
    if ($LASTEXITCODE -ne 0) { Add-LabProblem "[$($m.Name)] hostname wrapper not installed" }
    # Apply the saved hostname to the pod's UTS namespace (needs node privileges)
    Invoke-Node "sh /var/tmp/lab-hostname.sh $($m.Pid) $($m.Name)"

    & $kubectl exec -n $LabNamespace $p -- sh -c "test -f /usr/share/selkies/web/index.html" 2>$null
    if ($LASTEXITCODE -eq 0) {
        & $kubectl exec -n $LabNamespace $p -- python3 -c "import base64; exec(base64.b64decode('$tB64'))" $m.Title
        if ($LASTEXITCODE -ne 0) { Add-LabProblem "[$($m.Name)] tab title not set" }
    } else {
        Write-Host "[$($m.Name)] selkies web UI not found (image changed?), tab title skipped." -ForegroundColor Gray
    }
}

# Nginx (webtop front end) reverse proxies /zabbix to Apache on the server
$nginxPy = @'
import os
f = '/etc/nginx/sites-available/default'
c = open(f).read()
if '/zabbix' not in c:
    block = """  location /zabbix {
    proxy_pass http://127.0.0.1:80/zabbix;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }\n"""
    if '  location / {' not in c:
        raise SystemExit("location / not found in " + f)
    c = c.replace('  location / {', block + '  location / {', 1)
    open(f, 'w').write(c)
'@
$ngB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($nginxPy.Replace("`r`n", "`n")))
& $kubectl exec -n $LabNamespace $LabServer.Pod -- python3 -c "import base64; exec(base64.b64decode('$ngB64'))"
if ($LASTEXITCODE -eq 0) { & $kubectl exec -n $LabNamespace $LabServer.Pod -- nginx -s reload 2>&1 | Out-Null }
if ($LASTEXITCODE -ne 0) { Add-LabProblem "[server] nginx /zabbix proxy not configured" }

# Services from lab.config.ps1 ($ServerServices / $ClientServices), if installed
foreach ($m in $LabMachines) {
    foreach ($svc in $m.Services) {
        & $kubectl exec -n $LabNamespace $m.Pod -- test -x "/etc/init.d/$svc" 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "[$($m.Name)] $svc is not installed, skipped." -ForegroundColor Gray; continue }
        & $kubectl exec -n $LabNamespace $m.Pod -- sh -c "service $svc status >/dev/null 2>&1 || service $svc start" 2>&1 | Out-Null
        & $kubectl exec -n $LabNamespace $m.Pod -- sh -c "service $svc status >/dev/null 2>&1"
        if ($LASTEXITCODE -eq 0) { Write-Host "[$($m.Name)] $svc running." -ForegroundColor Green }
        else { Add-LabProblem "[$($m.Name)] service $svc failed to start (see: kubectl exec -n $LabNamespace $($m.Pod) -- service $svc status)" }
    }
}

# Desktop audio/video health check (restarts the session only if it is really broken)
foreach ($m in $LabMachines) {
    $uiCheck = (& $kubectl exec -n $LabNamespace $m.Pod -- su - abc -c "PULSE_RUNTIME_PATH=/defaults pactl info" 2>&1) | Out-String
    if ($uiCheck -match "Connection refused") {
        Write-Host "[$($m.Name)] fixing stale display/audio sockets (desktop session restarts)..." -ForegroundColor Yellow
        & $kubectl exec -n $LabNamespace $m.Pod -- bash -c "killall -9 Xvfb xfce4-session selkies pulseaudio 2>/dev/null; rm -rf /tmp/.X1-lock /tmp/.X11-unix/* /defaults/native /defaults/pid /dev/shm/*" 2>$null
    }
}

# Self-test: client 1 -> client 2 must get an answer (a TCP RST from a closed port is enough)
# and the server's forwarding counter must grow, i.e. traffic really goes through the server.
$c1 = $LabClients[0]; $c2 = $LabClients[1]
$fwdCount = { [long]((Invoke-Node "nsenter -t $($LabServer.Pid) -n cat /proc/net/snmp" | Select-String '^Ip: \d' | Select-Object -First 1).ToString() -split ' ')[6] }
$probe = "import socket`ns=socket.socket(); s.settimeout(3)`ntry:`n s.connect(('$($c2.Ip)', 9)); print('ok')`nexcept ConnectionRefusedError: print('ok')`nexcept Exception as e: print(e)"
$probeB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($probe))
$fwdBefore = & $fwdCount
$probeOut = (& $kubectl exec -n $LabNamespace $c1.Pod -- python3 -c "import base64; exec(base64.b64decode('$probeB64'))" 2>&1 | Out-String).Trim()
$fwdAfter = & $fwdCount
if ($probeOut -ne "ok") { Add-LabProblem "network test: $($c1.Ip) cannot reach $($c2.Ip) ($probeOut)" }
elseif ($fwdAfter - $fwdBefore -lt 2) { Add-LabProblem "network test: $($c1.Ip) -> $($c2.Ip) bypasses the server" }
else { Write-Host "Network test: $($c1.Ip) -> $($c2.Ip) OK, routed via the server." -ForegroundColor Green }

# 7. Port-forwards (supervised: restarted automatically if kubectl drops the connection)
Write-Host ""
Write-Host "[7/7] Starting port-forwards..." -ForegroundColor Yellow
function Test-PortListening([int]$Port) {
    [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}
function Start-LabForward($m) {
    Start-Process $kubectl -ArgumentList "port-forward svc/$($m.Service) -n $LabNamespace $($m.Port):3000 --address $BindAddress" -PassThru -WindowStyle Hidden
}
foreach ($m in $LabMachines) {
    $busy = Get-NetTCPConnection -State Listen -LocalPort $m.Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($busy) {
        $owner = (Get-Process -Id $busy.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        Stop-Lab "Port $($m.Port) is already in use by '$owner' (PID $($busy.OwningProcess)). Close it (another start-debian window?) or change the port in lab.config.ps1."
    }
}
foreach ($m in $LabMachines) { $m.Proc = Start-LabForward $m }
for ($i = 0; $i -lt 30 -and @($LabMachines | Where-Object { -not (Test-PortListening $_.Port) }).Count -gt 0; $i++) {
    Start-Sleep -Milliseconds 500
}
foreach ($m in $LabMachines) {
    if (-not (Test-PortListening $m.Port)) { Add-LabProblem "port-forward for $($m.Name) on port $($m.Port) did not start" }
}

Write-Host ""
if ($LabProblems.Count -eq 0) {
    Write-Host "==========================================================" -ForegroundColor Green
    Write-Host "  SUCCESS! All 4 machines are connected and ready!         " -ForegroundColor Green
} else {
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host "  Started with $($LabProblems.Count) problem(s):" -ForegroundColor Red
    $LabProblems | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
}
Write-Host "  Server GUI: http://localhost:$ServerPort" -ForegroundColor Cyan
Write-Host "  Zabbix Web: http://localhost:$ServerPort/zabbix" -ForegroundColor Magenta
foreach ($c in $LabClients) { Write-Host "  $($c.Title): http://localhost:$($c.Port)" -ForegroundColor Cyan }
if ($BindAddress -ne "127.0.0.1") {
    Write-Host "  WARNING: desktops have no password and listen on $BindAddress (whole network)." -ForegroundColor Yellow
}
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "NOTE: Keep this window open while working in the lab!" -ForegroundColor Yellow
Write-Host "Before shutting down run save-state.bat (or stop-debian.bat, it offers to save)." -ForegroundColor Yellow
Write-Host ""

if (-not $NoBrowser) { foreach ($m in $LabMachines) { Start-Process "http://localhost:$($m.Port)" } }

try {
    Write-Host "All port forwards running. Press Ctrl+C or close the window to stop..." -ForegroundColor Green
    while ($true) {
        Start-Sleep -Seconds 3
        foreach ($m in $LabMachines) {
            if ($m.Proc.HasExited) {
                Write-Host "$(Get-Date -Format HH:mm:ss) port-forward for $($m.Name) stopped, restarting..." -ForegroundColor Yellow
                $m.Proc = Start-LabForward $m
            }
        }
    }
} finally {
    $LabMachines | ForEach-Object { if ($_.Proc) { Stop-Process -Id $_.Proc.Id -Force -ErrorAction SilentlyContinue } }
}
