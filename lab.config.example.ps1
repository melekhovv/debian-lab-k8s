# ---------------------------------------------------------------
# Debian Lab - local settings.
# On first run the scripts copy this file to lab.config.ps1.
# Edit lab.config.ps1 (it is in .gitignore and is not committed).
# ---------------------------------------------------------------

# Tool paths. Leave empty to auto-detect:
#   1) PATH, 2) %LOCALAPPDATA%\Programs, 3) Program Files (Docker Desktop).
$MinikubePath     = ""
$KubectlPath      = ""
$DockerDesktopExe = ""

# Local ports of the browser desktops.
$ServerPort  = 3000                  # server (Zabbix at /zabbix)
$ClientPorts = @(3001, 3002, 3003)   # client 1, 2, 3

# Address for kubectl port-forward.
#   "127.0.0.1" - only from this computer (default, recommended)
#   "0.0.0.0"   - from the whole local network. The desktops have NO password and
#                 passwordless sudo, the server is privileged: anyone on the network gets root.
$BindAddress = "127.0.0.1"

# Resources of the Minikube node. Applied only when the cluster is CREATED
# (first start or after "minikube delete"), see README "Ресурсы".
$MinikubeCpus   = 4
$MinikubeMemory = 6144   # MB

# Services started by start-debian if they are installed in the machine.
$ServerServices = @("mariadb", "apache2", "zabbix-server", "zabbix-agent")
$ClientServices = @("zabbix-agent")

# Where save-state puts copies of the backups on the Windows disk.
$BackupDir = ""   # empty = <project>\backups
