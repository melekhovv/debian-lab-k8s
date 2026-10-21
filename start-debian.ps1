# Automatic starter for Debian Server and 3 Clients in Kubernetes
$ErrorActionPreference = "Continue"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Starting Debian Lab Network in Kubernetes...            " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

# Settings and tool paths (lab.config.ps1) -> $minikube, $kubectl, $dockerExe, ports, $BindAddress
. (Join-Path $PSScriptRoot "lab-common.ps1")
Assert-LabTool "minikube" $minikube "MinikubePath"
Assert-LabTool "kubectl"  $kubectl  "KubectlPath"
$manifestServer  = Join-Path $PSScriptRoot "k8s\debian-webtop.yaml"
$manifestClients = Join-Path $PSScriptRoot "k8s\debian-clients.yaml"

# 1. Check Docker Desktop
Write-Host "[1/4] Checking Docker Desktop..." -ForegroundColor Yellow
$dockerReady = $false
try {
    $null = docker info 2>&1
    if ($LASTEXITCODE -eq 0) { $dockerReady = $true }
} catch {}

if (-not $dockerReady) {
    Write-Host "Starting Docker Desktop..." -ForegroundColor Yellow
    Assert-LabTool "Docker Desktop" $dockerExe "DockerDesktopExe"
    Start-Process $dockerExe
    Write-Host "Waiting for Docker Engine to start..." -ForegroundColor Yellow
    $retries = 30
    while ($retries -gt 0) {
        Start-Sleep -Seconds 3
        try {
            $null = docker info 2>&1
            if ($LASTEXITCODE -eq 0) {
                $dockerReady = $true
                break
            }
        } catch {}
        Write-Host "." -NoNewline -ForegroundColor Yellow
        $retries--
    }
    Write-Host ""
    if (-not $dockerReady) {
        Write-Host "ERROR: Could not connect to Docker. Please ensure Docker Desktop is running." -ForegroundColor Red
        Read-Host "Press Enter to exit..."
        exit 1
    }
    Write-Host "Docker Engine is ready!" -ForegroundColor Green
} else {
    Write-Host "Docker Desktop is already running." -ForegroundColor Green
}

# 2. Check Minikube
Write-Host ""
Write-Host "[2/4] Checking Kubernetes cluster (Minikube)..." -ForegroundColor Yellow
$mkStatus = & $minikube status 2>&1 | Out-String
if ($mkStatus -notmatch "host: Running" -or $mkStatus -notmatch "apiserver: Running") {
    Write-Host "Starting Minikube cluster..." -ForegroundColor Yellow
    & $minikube start --driver=docker
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Minikube failed to start." -ForegroundColor Red
        Read-Host "Press Enter to exit..."
        exit 1
    }
} else {
    Write-Host "Minikube cluster is already running." -ForegroundColor Green
}

# 3. Check and deploy manifests
Write-Host ""
Write-Host "[3/4] Checking Deployments in Kubernetes..." -ForegroundColor Yellow
$depServer = & $kubectl get deployment debian-desktop -n debian-lab 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host "Deploying Debian Server manifest..." -ForegroundColor Yellow
    & $kubectl apply -f $manifestServer
}

$depClients = & $kubectl get deployment debian-client-1 -n debian-lab 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host "Deploying Debian 3 Clients manifest..." -ForegroundColor Yellow
    & $kubectl apply -f $manifestClients
}

Write-Host "Waiting for pods to be ready..." -ForegroundColor Yellow
& $kubectl rollout status deployment/debian-desktop -n debian-lab --timeout=120s
& $kubectl rollout status deployment/debian-client-1 -n debian-lab --timeout=120s
& $kubectl rollout status deployment/debian-client-2 -n debian-lab --timeout=120s
& $kubectl rollout status deployment/debian-client-3 -n debian-lab --timeout=120s

# 4. Configure Network Topology (IPs and Routing)
Write-Host ""
Write-Host "[4/4] Configuring IP Network Topology..." -ForegroundColor Yellow

docker exec minikube sysctl -w net.ipv4.conf.all.proxy_arp=1 net.ipv4.conf.default.proxy_arp=1 2>$null | Out-Null

$serverPod = (& $kubectl get pods -n debian-lab -l app=debian-desktop -o jsonpath="{.items[0].metadata.name}").Trim()
$c1Pod = (& $kubectl get pods -n debian-lab -l app=debian-client-1 -o jsonpath="{.items[0].metadata.name}").Trim()
$c2Pod = (& $kubectl get pods -n debian-lab -l app=debian-client-2 -o jsonpath="{.items[0].metadata.name}").Trim()
$c3Pod = (& $kubectl get pods -n debian-lab -l app=debian-client-3 -o jsonpath="{.items[0].metadata.name}").Trim()

# Assign Client IPs
& $kubectl exec -n debian-lab $c1Pod -- sudo ip addr replace 192.168.2.1/24 dev eth0 2>$null
& $kubectl exec -n debian-lab $c2Pod -- sudo ip addr replace 192.168.3.1/24 dev eth0 2>$null
& $kubectl exec -n debian-lab $c3Pod -- sudo ip addr replace 192.168.4.1/24 dev eth0 2>$null

# Server Gateway IPs (only .254)
$serverCid = (docker exec minikube crictl ps --name debian-desktop -q).Trim()
$serverPid = (docker exec minikube crictl inspect $serverCid | ConvertFrom-Json).info.pid

docker exec minikube nsenter -t $serverPid -n sysctl -w net.ipv4.ip_forward=1 2>$null | Out-Null
docker exec minikube nsenter -t $serverPid -n ip addr replace 192.168.2.254/24 dev eth0 2>$null
docker exec minikube nsenter -t $serverPid -n ip addr replace 192.168.3.254/24 dev eth0 2>$null
docker exec minikube nsenter -t $serverPid -n ip addr replace 192.168.4.254/24 dev eth0 2>$null
docker exec minikube nsenter -t $serverPid -n ip addr del 192.168.2.100/24 dev eth0 2>$null
docker exec minikube nsenter -t $serverPid -n ip addr del 192.168.3.100/24 dev eth0 2>$null
docker exec minikube nsenter -t $serverPid -n ip addr del 192.168.4.100/24 dev eth0 2>$null

# Client routes via Server Gateway (.254)
& $kubectl exec -n debian-lab $c1Pod -- sudo ip route replace 192.168.3.0/24 via 192.168.2.254 dev eth0 2>$null
& $kubectl exec -n debian-lab $c1Pod -- sudo ip route replace 192.168.4.0/24 via 192.168.2.254 dev eth0 2>$null

& $kubectl exec -n debian-lab $c2Pod -- sudo ip route replace 192.168.2.0/24 via 192.168.3.254 dev eth0 2>$null
& $kubectl exec -n debian-lab $c2Pod -- sudo ip route replace 192.168.4.0/24 via 192.168.3.254 dev eth0 2>$null

& $kubectl exec -n debian-lab $c3Pod -- sudo ip route replace 192.168.2.0/24 via 192.168.4.254 dev eth0 2>$null
& $kubectl exec -n debian-lab $c3Pod -- sudo ip route replace 192.168.3.0/24 via 192.168.4.254 dev eth0 2>$null

# Find peer veth interfaces
$sLink = (& $kubectl exec -n debian-lab $serverPod -- cat /sys/class/net/eth0/iflink).Trim()
$c1Link = (& $kubectl exec -n debian-lab $c1Pod -- cat /sys/class/net/eth0/iflink).Trim()
$c2Link = (& $kubectl exec -n debian-lab $c2Pod -- cat /sys/class/net/eth0/iflink).Trim()
$c3Link = (& $kubectl exec -n debian-lab $c3Pod -- cat /sys/class/net/eth0/iflink).Trim()

$links = docker exec minikube ip link show
$sVeth = ($links | Select-String "(\d+): (veth\w+)@if" | Where-Object { $_.Matches.Groups[1].Value -eq $sLink }).Matches.Groups[2].Value
$c1Veth = ($links | Select-String "(\d+): (veth\w+)@if" | Where-Object { $_.Matches.Groups[1].Value -eq $c1Link }).Matches.Groups[2].Value
$c2Veth = ($links | Select-String "(\d+): (veth\w+)@if" | Where-Object { $_.Matches.Groups[1].Value -eq $c2Link }).Matches.Groups[2].Value
$c3Veth = ($links | Select-String "(\d+): (veth\w+)@if" | Where-Object { $_.Matches.Groups[1].Value -eq $c3Link }).Matches.Groups[2].Value

# Host routes
docker exec minikube ip route replace 192.168.2.1 dev $c1Veth scope host
docker exec minikube ip route replace 192.168.3.1 dev $c2Veth scope host
docker exec minikube ip route replace 192.168.4.1 dev $c3Veth scope host
docker exec minikube ip route replace 192.168.2.254 dev $sVeth scope host
docker exec minikube ip route replace 192.168.3.254 dev $sVeth scope host
docker exec minikube ip route replace 192.168.4.254 dev $sVeth scope host

# Set custom tab titles
$titleList = @(
    @{ Pod = $serverPod; Title = "Server (Zabbix)" },
    @{ Pod = $c1Pod;     Title = "Client 1 (192.168.2.1)" },
    @{ Pod = $c2Pod;     Title = "Client 2 (192.168.3.1)" },
    @{ Pod = $c3Pod;     Title = "Client 3 (192.168.4.1)" }
)
foreach ($t in $titleList) {
    $p = $t.Pod
    $tit = $t.Title
    $py = "with open('/usr/share/selkies/web/index.html') as f: c=f.read()`nimport re; c=re.sub(r'<title>.*?</title>', '<title>$tit</title><script>document.title=\`"$tit\`";setInterval(function(){if(document.title!=\`"$tit\`")document.title=\`"$tit\`"},500);</script>', c)`nwith open('/usr/share/selkies/web/index.html','w') as f: f.write(c)`nwith open('/usr/share/selkies/web/manifest.json') as f: m=f.read()`nwith open('/usr/share/selkies/web/manifest.json','w') as f: f.write(m.replace('Debian XFCE', '$tit'))"
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($py))
    & $kubectl exec -n debian-lab $p -- python3 -c "import base64; exec(base64.b64decode('$b64'))" 2>$null
}

# 5. Ensure Hostname wrappers and Sync Service
$hostnameScript = @'
#!/bin/bash
TARGET="$1"
if [ "$1" = "set-hostname" ] || [ "$1" = "hostname" ]; then
    TARGET="$2"
fi

if [ -z "$TARGET" ] || [[ "$TARGET" == -* ]]; then
    /bin/hostname "$@"
    exit 0
fi

echo "$TARGET" > /etc/hostname
sed -i "/127.0.0.1\s\+$TARGET/d" /etc/hosts 2>/dev/null
echo "127.0.0.1 $TARGET" >> /etc/hosts
sleep 1.2
echo "Hostname set to: $(/bin/hostname)"
'@
$hB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($hostnameScript))
foreach ($p in @($serverPod, $c1Pod, $c2Pod, $c3Pod)) {
    & $kubectl exec -n debian-lab $p -- bash -c "echo '$hB64' | base64 -d > /usr/local/bin/hostname && chmod +x /usr/local/bin/hostname && cp /usr/local/bin/hostname /usr/local/bin/hostnamectl" 2>$null
}

# 6. Ensure Zabbix, MariaDB, and Apache are running on Server
Write-Host "Checking Zabbix and database services on Server..." -ForegroundColor Yellow
$hasZbx = (& $kubectl exec -n debian-lab $serverPod -- which zabbix_server 2>$null)
if (-not $hasZbx) {
    Write-Host "Restoring Zabbix packages and database from persistent snapshot..." -ForegroundColor Yellow
    $sCid = (docker exec minikube crictl ps --name debian-desktop -q).Trim()
    $sPid = (docker exec minikube python3 -c "import json, subprocess; d=json.loads(subprocess.check_output(['crictl', 'inspect', '$sCid'])); print(d['info']['pid'])").Trim()
    $bDir = "/var/backup_desktop/fs"
    $checkB = (docker exec minikube ls -d /var/backup_desktop/fs 2>$null)
    if (-not $checkB) { $bDir = "/var/backup_desktop_106/fs" }
    docker exec minikube cp -a "$bDir/." "/proc/$sPid/root/" 2>$null
}

# 7. Check and restore Clients if backups exist
$clientList = @(
    @{ Name = "debian-client-1"; Pod = $c1Pod; Backup = "/var/backup_client1/fs" },
    @{ Name = "debian-client-2"; Pod = $c2Pod; Backup = "/var/backup_client2/fs" },
    @{ Name = "debian-client-3"; Pod = $c3Pod; Backup = "/var/backup_client3/fs" }
)
foreach ($cl in $clientList) {
    $cpod = $cl.Pod
    $cname = $cl.Name
    $cbak = $cl.Backup
    $hasPing = (& $kubectl exec -n debian-lab $cpod -- which ping 2>$null)
    if (-not $hasPing) {
        $hasBak = (docker exec minikube ls -d $cbak 2>$null)
        if ($hasBak) {
            Write-Host "Restoring $cname from persistent backup..." -ForegroundColor Yellow
            $cid = (docker exec minikube crictl ps --name $cname -q).Trim()
            $cpid = (docker exec minikube python3 -c "import json, subprocess; d=json.loads(subprocess.check_output(['crictl', 'inspect', '$cid'])); print(d['info']['pid'])").Trim()
            docker exec minikube cp -a "$cbak/." "/proc/$cpid/root/" 2>$null
        }
    }
    # Ensure zabbix-agent service is started if installed
    & $kubectl exec -n debian-lab $cpod -- service zabbix-agent start 2>$null
}

# Ensure Nginx reverse proxies /zabbix
$nginxPy = @'
with open('/etc/nginx/sites-available/default') as f:
    c = f.read()
if '/zabbix' not in c:
    block = """  location /zabbix {
    proxy_pass http://127.0.0.1:80/zabbix;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }\n"""
    c = c.replace('  location / {', block + '  location / {', 1)
    with open('/etc/nginx/sites-available/default', 'w') as f:
        f.write(c)
'@
$ngB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($nginxPy))
& $kubectl exec -n debian-lab $serverPod -- python3 -c "import base64; exec(base64.b64decode('$ngB64'))" 2>$null
& $kubectl exec -n debian-lab $serverPod -- nginx -s reload 2>$null

# Start MariaDB, Apache2, Zabbix Server and Agent
& $kubectl exec -n debian-lab $serverPod -- service mariadb start 2>$null
& $kubectl exec -n debian-lab $serverPod -- service apache2 start 2>$null
& $kubectl exec -n debian-lab $serverPod -- service zabbix-server start 2>$null
& $kubectl exec -n debian-lab $serverPod -- service zabbix-agent start 2>$null

# Ensure UI audio/video streaming is healthy on Server and all Clients
foreach ($targetPod in @($serverPod, $c1Pod, $c2Pod, $c3Pod)) {
    $uiCheck = (& $kubectl exec -n debian-lab $targetPod -- su - abc -c "PULSE_RUNTIME_PATH=/defaults pactl info" 2>&1)
    if ($uiCheck -match "Connection refused") {
        Write-Host "Fixing stale display/audio stream sockets on $targetPod..." -ForegroundColor Yellow
        & $kubectl exec -n debian-lab $targetPod -- bash -c "killall -9 Xvfb xfce4-session selkies pulseaudio 2>/dev/null; rm -rf /tmp/.X1-lock /tmp/.X11-unix/* /defaults/native /defaults/pid /dev/shm/*" 2>$null
    }
}

Write-Host "Network topology, Zabbix, and tab titles are active!" -ForegroundColor Green

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  SUCCESS! All 4 machines are connected and ready!         " -ForegroundColor Green
Write-Host "  Server GUI: http://localhost:$ServerPort" -ForegroundColor Cyan
Write-Host "  Zabbix Web: http://localhost:$ServerPort/zabbix" -ForegroundColor Magenta
Write-Host "  Client 1:   http://localhost:$($ClientPorts[0]) (IP: 192.168.2.1)" -ForegroundColor Cyan
Write-Host "  Client 2:   http://localhost:$($ClientPorts[1]) (IP: 192.168.3.1)" -ForegroundColor Cyan
Write-Host "  Client 3:   http://localhost:$($ClientPorts[2]) (IP: 192.168.4.1)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "NOTE: Keep this window open while working in the lab!" -ForegroundColor Yellow
Write-Host "To stop the session - close this window." -ForegroundColor Gray
Write-Host ""

# Open 4 browser tabs
Start-Process "http://localhost:$ServerPort"
foreach ($cp in $ClientPorts) { Start-Process "http://localhost:$cp" }

# Start port-forwards
$ports = @(
    @{ Svc = "debian-desktop-service";  Port = $ServerPort },
    @{ Svc = "debian-client-1-service"; Port = $ClientPorts[0] },
    @{ Svc = "debian-client-2-service"; Port = $ClientPorts[1] },
    @{ Svc = "debian-client-3-service"; Port = $ClientPorts[2] }
)

$procs = @()
foreach ($entry in $ports) {
    $svc = $entry.Svc
    $p   = $entry.Port
    $proc = Start-Process $kubectl -ArgumentList "port-forward svc/$svc -n debian-lab ${p}:3000 --address $BindAddress" -PassThru -WindowStyle Hidden
    $procs += $proc
}

try {
    Write-Host "All port forwards running. Press Ctrl+C to stop..." -ForegroundColor Green
    while ($true) {
        Start-Sleep -Seconds 2
    }
} finally {
    $procs | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
}
