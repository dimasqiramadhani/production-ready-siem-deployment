# 13. Windows Agent Mass Deployment Simulation

Two Windows endpoints: win-agent-01 (10.10.10.101), win-agent-02 (10.10.10.102),
deployed as if part of a large rollout. All enrollment variables point at the load
balancer.

Common deployment variables:
- `WAZUH_MANAGER=wazuh-lb.lab.local`
- `WAZUH_REGISTRATION_SERVER=wazuh-lb.lab.local`
- `WAZUH_AGENT_GROUP=windows`
- `WAZUH_REGISTRATION_PASSWORD=<password>` (only if enrollment password is enabled)

The `windows` group must already exist (section 10) so agents land there at
enrollment.

## Method A: GPO Startup Script

### A.1 Prepare the installer file share

Host the MSI on a share, for example `\\fileserver\software\wazuh\wazuh-agent.msi`.
Permissions: grant Read and Execute to `Domain Computers` (startup scripts run as
SYSTEM, which uses the computer account) on both the share and NTFS.

### A.2 Startup script

`scripts/install-wazuh-agent.bat` (idempotent: skips install if WazuhSvc exists,
logs to `C:\Windows\Temp\wazuh-agent-install.log`):

```bat
@echo off
setlocal
set LOGFILE=C:\Windows\Temp\wazuh-agent-install.log
set MSI=\\fileserver\software\wazuh\wazuh-agent.msi
set WAZUH_MANAGER=wazuh-lb.lab.local
set WAZUH_REGISTRATION_SERVER=wazuh-lb.lab.local
set WAZUH_AGENT_GROUP=windows
set WAZUH_REGISTRATION_PASSWORD=ChangeMeEnrollPass

echo [%DATE% %TIME%] Starting Wazuh agent deployment check >> "%LOGFILE%"

sc query WazuhSvc >nul 2>&1
if %ERRORLEVEL%==0 (
    echo [%DATE% %TIME%] WazuhSvc already present, skipping install >> "%LOGFILE%"
    goto :ensure_running
)

echo [%DATE% %TIME%] Installing from %MSI% >> "%LOGFILE%"
msiexec.exe /i "%MSI%" /q ^
    WAZUH_MANAGER="%WAZUH_MANAGER%" ^
    WAZUH_REGISTRATION_SERVER="%WAZUH_REGISTRATION_SERVER%" ^
    WAZUH_AGENT_GROUP="%WAZUH_AGENT_GROUP%" ^
    WAZUH_REGISTRATION_PASSWORD="%WAZUH_REGISTRATION_PASSWORD%" >> "%LOGFILE%" 2>&1

echo [%DATE% %TIME%] msiexec exit code %ERRORLEVEL% >> "%LOGFILE%"

:ensure_running
sc query WazuhSvc | find "RUNNING" >nul 2>&1
if not %ERRORLEVEL%==0 (
    echo [%DATE% %TIME%] Starting WazuhSvc >> "%LOGFILE%"
    net start WazuhSvc >> "%LOGFILE%" 2>&1
)
echo [%DATE% %TIME%] Done >> "%LOGFILE%"
endlocal
```

### A.3 Link the GPO to the OU

1. Open Group Policy Management.
2. Create a GPO, for example `Deploy-Wazuh-Agent`.
3. Edit it: Computer Configuration > Policies > Windows Settings > Scripts >
   Startup > Add, and point at `install-wazuh-agent.bat`.
4. Link the GPO to the OU containing the target computers (for the lab, the OU that
   holds win-agent-01 and win-agent-02).

### A.4 Test on a pilot endpoint

1. On win-agent-01 force policy refresh:
   ```cmd
   gpupdate /force
   ```
2. Reboot so the startup script runs as SYSTEM:
   ```cmd
   shutdown /r /t 0
   ```
3. After reboot, validate the service (see A.5). Only after the pilot succeeds, let
   the rest of the OU pick it up.

### A.5 Validate the service

```cmd
sc query WazuhSvc
type C:\Windows\Temp\wazuh-agent-install.log
```

## Method B: PowerShell Remoting

### B.1 Prerequisites

WinRM enabled on targets (`Enable-PSRemoting -Force`), the admin host trusts them, and
5985/5986 open. The installer share is reachable from the targets.

### B.2 Deployment script

`scripts/Deploy-WazuhAgent.ps1`:

```powershell
$targets = @("win-agent-01.lab.local", "win-agent-02.lab.local")
$msiSource = "\\fileserver\software\wazuh\wazuh-agent.msi"
$cred = Get-Credential   # domain admin

Invoke-Command -ComputerName $targets -Credential $cred -ScriptBlock {
    param($msiSource)

    $log = "C:\Windows\Temp\wazuh-agent-install.log"
    "$(Get-Date) start on $env:COMPUTERNAME" | Out-File -Append $log

    if (Get-Service -Name WazuhSvc -ErrorAction SilentlyContinue) {
        "$(Get-Date) WazuhSvc present, skipping install" | Out-File -Append $log
    } else {
        $local = "C:\Windows\Temp\wazuh-agent.msi"
        Copy-Item -Path $msiSource -Destination $local -Force

        $args = @(
            "/i", $local, "/q",
            'WAZUH_MANAGER=wazuh-lb.lab.local',
            'WAZUH_REGISTRATION_SERVER=wazuh-lb.lab.local',
            'WAZUH_AGENT_GROUP=windows',
            'WAZUH_REGISTRATION_PASSWORD=ChangeMeEnrollPass'
        )
        $p = Start-Process msiexec.exe -ArgumentList $args -Wait -PassThru
        "$(Get-Date) msiexec exit $($p.ExitCode)" | Out-File -Append $log
    }

    if ((Get-Service WazuhSvc).Status -ne 'Running') {
        Start-Service WazuhSvc
    }
    "$(Get-Date) service status $((Get-Service WazuhSvc).Status)" | Out-File -Append $log
} -ArgumentList $msiSource

# Pull the install logs back
foreach ($t in $targets) {
    Write-Host "==== $t ===="
    Invoke-Command -ComputerName $t -Credential $cred -ScriptBlock {
        Get-Content C:\Windows\Temp\wazuh-agent-install.log -Tail 20
    }
}
```

## 13.1 Windows validation commands

Run on each Windows endpoint:

```powershell
Get-Service WazuhSvc
Test-NetConnection wazuh-lb.lab.local -Port 1514
Test-NetConnection wazuh-lb.lab.local -Port 1515
Get-Content "C:\Program Files (x86)\ossec-agent\ossec.log" -Tail 50
```

Healthy result: WazuhSvc Running, both TCP tests succeed, and ossec.log shows
successful enrollment and connection to the manager. The agent should appear in the
`windows` group on the dashboard.
