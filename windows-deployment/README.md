# 13. Windows Agent Mass Deployment (Active Directory GPO)

The Windows side of the lab is built around a small Active Directory domain so the
Wazuh agent can be rolled out to every Windows machine at once, the same pattern used
across a real fleet. Three Windows Server 2022 VMs:

- windows-ad-dc (192.168.90.121): Active Directory domain controller and DNS, domain lab.local
- win-agent-01 (192.168.90.122): domain member, agent target, group windows
- win-agent-02 (192.168.90.123): domain member, agent target, group windows

The idea is simple. Instead of logging into each Windows box and installing the agent
by hand, you publish the installer once, define a Group Policy startup script once, and
every machine in the target organizational unit installs the agent automatically on
its next reboot. Add more machines to the domain later and they pick up the same policy
with no extra work.

Common deployment variables (all enrollment goes through the load balancer):
- `WAZUH_MANAGER=192.168.90.112`
- `WAZUH_REGISTRATION_SERVER=192.168.90.112`
- `WAZUH_AGENT_GROUP=windows`
- `WAZUH_REGISTRATION_PASSWORD=WazuhEnroll2024!`

The `windows` group must already exist on the manager (section 10) so agents land
there automatically at enrollment.

## 13.1 Promote the domain controller

On windows-ad-dc, with the static IP 192.168.90.121 already set, open PowerShell as
Administrator.

Set the hostname and reboot:

```powershell
Rename-Computer -NewName "windows-ad-dc" -Restart
```

Install the AD DS and DNS roles:

```powershell
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools
```

Promote the server to a new forest. The domain controller points its own DNS client
at itself as part of promotion:

```powershell
Import-Module ADDSDeployment

Install-ADDSForest `
  -DomainName "lab.local" `
  -DomainNetbiosName "LAB" `
  -ForestMode "WinThreshold" `
  -DomainMode "WinThreshold" `
  -InstallDns:$true `
  -SafeModeAdministratorPassword (ConvertTo-SecureString "WazuhLab2024!" -AsPlainText -Force) `
  -Force:$true
```

The server reboots automatically. Log back in as `LAB\Administrator`.

Confirm the domain is healthy:

```powershell
Get-ADDomain | Select-Object DNSRoot, DomainMode, PDCEmulator
Resolve-DnsName lab.local
Get-SmbShare | Where-Object { $_.Name -eq "SYSVOL" -or $_.Name -eq "NETLOGON" }
```

DNSRoot should be lab.local, lab.local should resolve to 192.168.90.121, and both
SYSVOL and NETLOGON shares should be present.

## 13.2 Create the OU and installer share

Keep the agent machines in their own organizational unit so the GPO scope stays clean:

```powershell
New-ADOrganizationalUnit -Name "WazuhEndpoints" -Path "DC=lab,DC=local"
```

Publish the MSI on a share that domain computers can read:

```powershell
New-Item -Path "C:\Software\Wazuh" -ItemType Directory -Force

New-SmbShare -Name "Software" -Path "C:\Software" `
  -FullAccess "LAB\Domain Admins" `
  -ReadAccess "LAB\Domain Computers"
```

Download the agent installer to the share:

```powershell
$url = "https://packages.wazuh.com/4.x/windows/wazuh-agent-4.14.5-1.msi"
Invoke-WebRequest -Uri $url -OutFile "C:\Software\Wazuh\wazuh-agent.msi" -UseBasicParsing
Get-Item "C:\Software\Wazuh\wazuh-agent.msi" | Select-Object Name, Length
```

The file is roughly 5.9 MB. The URL points at the stable version (`4.14.5-1.msi`). The
agent version should match the manager so
the whole fleet stays on one build.

## 13.3 Create the deployment GPO

Create the GPO and the startup script folder in SYSVOL:

```powershell
New-GPO -Name "Deploy-Wazuh-Agent" -Comment "Deploys Wazuh agent to endpoints in WazuhEndpoints OU"

$gpo = Get-GPO -Name "Deploy-Wazuh-Agent"
$scriptsPath = "\\windows-ad-dc\SYSVOL\lab.local\Policies\{$($gpo.Id)}\Machine\Scripts\Startup"
New-Item -Path $scriptsPath -ItemType Directory -Force
```

Write the startup script. It is idempotent: it skips the install if the service is
already present and only ensures the service is running, so it is safe to run on every
boot:

```powershell
$scriptContent = @'
@echo off
setlocal
set LOGFILE=C:\Windows\Temp\wazuh-agent-install.log
set MSI=\\windows-ad-dc\Software\Wazuh\wazuh-agent.msi
set WAZUH_MANAGER=192.168.90.112
set WAZUH_REGISTRATION_SERVER=192.168.90.112
set WAZUH_AGENT_GROUP=windows
set WAZUH_REGISTRATION_PASSWORD=WazuhEnroll2024!

echo [%DATE% %TIME%] Starting Wazuh agent deployment >> "%LOGFILE%"

sc query WazuhSvc >nul 2>&1
if %ERRORLEVEL%==0 (
    echo [%DATE% %TIME%] WazuhSvc already present, skipping >> "%LOGFILE%"
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
'@

$scriptContent | Out-File -FilePath (Join-Path $scriptsPath "install-wazuh-agent.bat") -Encoding ASCII
```

Register the script as a machine startup script and link the GPO to the OU:

```powershell
$gpoId = (Get-GPO -Name "Deploy-Wazuh-Agent").Id
$iniPath = "\\windows-ad-dc\SYSVOL\lab.local\Policies\{$gpoId}\Machine\Scripts\scripts.ini"

@"
[Startup]
0CmdLine=install-wazuh-agent.bat
0Parameters=
"@ | Out-File -FilePath $iniPath -Encoding Unicode

New-GPLink -Name "Deploy-Wazuh-Agent" `
  -Target "OU=WazuhEndpoints,DC=lab,DC=local" `
  -LinkEnabled Yes
```

A startup script lives in the machine half of the GPO, so make sure the computer
configuration version is non zero. Registering a machine extension with
Set-GPRegistryValue stamps the version cleanly:

```powershell
Set-GPRegistryValue -Name "Deploy-Wazuh-Agent" `
  -Key "HKLM\Software\Policies\Wazuh" `
  -ValueName "Managed" `
  -Type DWord `
  -Value 1

Get-GPO -Name "Deploy-Wazuh-Agent" | Select-Object DisplayName, ComputerVersion
```

ComputerVersion should now report AD Version 1, SysVol Version 1.

## 13.4 Prepare each Windows agent before joining

Do this on win-agent-01 (192.168.90.122) and win-agent-02 (192.168.90.123). Set
everything up before the domain join so the machine is reachable by RDP and WinRM the
moment it comes back on the domain.

Pick a hostname of 15 characters or fewer (the NetBIOS limit). `win-agent-01` and
`win-agent-02` both fit:

```powershell
# win-agent-01
Rename-Computer -NewName "win-agent-01" -Restart
# win-agent-02
Rename-Computer -NewName "win-agent-02" -Restart
```

After the rename reboot, point DNS at the domain controller, enable Remote Management,
and allow RDP with a plain login:

```powershell
$adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex `
  -ServerAddresses ("192.168.90.121")

Enable-PSRemoting -Force

Set-ItemProperty `
  -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
  -Name "UserAuthentication" -Value 0

Resolve-DnsName lab.local
```

lab.local must resolve to 192.168.90.121 before the join.

## 13.5 Join the domain

Still on each agent, join the domain straight into the WazuhEndpoints OU:

```powershell
Add-Computer `
  -DomainName "lab.local" `
  -OUPath "OU=WazuhEndpoints,DC=lab,DC=local" `
  -Credential (Get-Credential -Message "Enter LAB\Administrator") `
  -Restart -Force
```

The machine reboots and joins the domain. Log back in as `LAB\Administrator`.

Confirm both machines registered from the domain controller:

```powershell
Get-ADComputer -Filter * | Select-Object Name, DistinguishedName
```

You should see win-agent-01 and win-agent-02 under OU=WazuhEndpoints.

## 13.6 Apply the policy and deploy

The startup script runs at boot. Pull the policy down and reboot so it fires:

```powershell
gpupdate /force
gpresult /r /scope computer | findstr /i "deploy-wazuh"
Restart-Computer -Force
```

`Deploy-Wazuh-Agent` should appear under the applied policy objects. After the reboot
the agent is installed and the service is running. Confirm on each agent:

```powershell
Get-Service WazuhSvc
Get-Content "C:\Windows\Temp\wazuh-agent-install.log"
```

WazuhSvc should be Running and the log should show msiexec exit code 0.

## 13.7 Validate enrollment on the manager

On wazuh-master-01:

```bash
/var/ossec/bin/agent_control -l
/var/ossec/bin/agent_groups -l -g windows
```

Both Windows agents should be listed as active and both should be members of the
windows group. They enroll through the load balancer on 1515 and report on 1514, so
their traffic is spread across the workers just like the Linux agents.

## Notes

- Keep computer names to 15 characters or fewer. A longer name is silently truncated
  by NetBIOS, which breaks the match between the machine and its AD account.
- Set DNS to the domain controller before joining. The join and all later Kerberos
  authentication depend on resolving lab.local through the DC.
- Turning on Remote Management and relaxing the RDP login requirement before the join
  keeps the machine reachable as soon as it returns on the domain.

## Method B: PowerShell Remoting (no Active Directory)

For a smaller environment without a domain, the same install can be driven over
WinRM from a single admin workstation. The logic is identical, only the trigger
changes from a GPO startup script to a remote invocation.

`scripts/Deploy-WazuhAgent.ps1`:

```powershell
$targets = @("win-agent-01.lab.local", "win-agent-02.lab.local")
$msiSource = "\\windows-ad-dc\Software\Wazuh\wazuh-agent.msi"

foreach ($t in $targets) {
    Invoke-Command -ComputerName $t -ScriptBlock {
        param($msi)
        if (-not (Get-Service WazuhSvc -ErrorAction SilentlyContinue)) {
            $args = @(
                "/i", $msi, "/q",
                "WAZUH_MANAGER=192.168.90.112",
                "WAZUH_REGISTRATION_SERVER=192.168.90.112",
                "WAZUH_AGENT_GROUP=windows",
                "WAZUH_REGISTRATION_PASSWORD=WazuhEnroll2024!"
            )
            Start-Process msiexec.exe -ArgumentList $args -Wait
        }
        Start-Service WazuhSvc -ErrorAction SilentlyContinue
    } -ArgumentList $msiSource
}
```

Validate the same way from the manager with agent_control -l.
