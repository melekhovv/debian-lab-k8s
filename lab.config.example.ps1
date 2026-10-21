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
#   "0.0.0.0"   - desktops are reachable from the whole local network
#   "127.0.0.1" - only from this computer (safer)
$BindAddress = "0.0.0.0"
