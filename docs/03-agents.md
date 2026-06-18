# Part 3: Agents, Groups, and Detection

This part covers agent grouping, centralized agent configuration, rules and
decoders, Windows agent deployment via Active Directory GPO, and Ubuntu agent
deployment via Ansible.

---

# 10. Agent Grouping

Create two groups so each OS gets its own centralized configuration: `windows` and
`linux`. Run these on the master. Reference:
https://documentation.wazuh.com/current/user-manual/agent/agent-management/grouping-agents.html

## 10.1 Create the groups

```bash
/var/ossec/bin/agent_groups -a -g windows -q
/var/ossec/bin/agent_groups -a -g linux -q
```

This creates `/var/ossec/etc/shared/windows/` and `/var/ossec/etc/shared/linux/`,
each with an empty `agent.conf` ready for centralized configuration (section 11).

## 10.2 List groups

```bash
/var/ossec/bin/agent_groups -l
```

## 10.3 List agents in a group

```bash
/var/ossec/bin/agent_groups -l -g windows
/var/ossec/bin/agent_groups -l -g linux
```

## 10.4 Manual assignment (fallback)

Agents enrolled with `WAZUH_AGENT_GROUP` land in the right group automatically. If an
agent was missed, assign it by ID:

```bash
# Find the agent ID
/var/ossec/bin/agent_control -l
# Assign agent 005 to the windows group
/var/ossec/bin/agent_groups -a -i 005 -g windows -q
```

## 10.5 Remove an agent from a group

```bash
/var/ossec/bin/agent_groups -r -i 005 -g windows -q
```

## 10.6 Check whether an agent is in a group

```bash
/var/ossec/bin/agent_groups -l -g windows
# or via the API
curl -k -u wazuh-wui:<PASSWORD> "https://192.168.90.115:55000/agents?group=windows&pretty" \
  -H "Authorization: Bearer <TOKEN>"
```

## 10.7 Notes

- Create the groups before mass deployment if you want agents to use
  `WAZUH_AGENT_GROUP=windows` or `WAZUH_AGENT_GROUP=linux` at enrollment. If the
  group does not exist at enrollment time the agent falls into `default` and you must
  reassign it.
- Groups drive centralized configuration. Every agent in a group receives that
  group's `agent.conf`.
- Rules are never sent to agents. Rules and decoders stay on the manager. Groups only
  control what the agent collects and runs, not how events are analyzed.
- Run all `agent_groups` commands on the master. Group files synchronize to the
  workers automatically.

---

# 11. Centralized Configuration

Each group has a shared `agent.conf` on the manager that is pushed to every agent in
the group. Reference:
https://documentation.wazuh.com/current/user-manual/reference/centralized-configuration.html

Files:
- `/var/ossec/etc/shared/windows/agent.conf`
- `/var/ossec/etc/shared/linux/agent.conf`

Edit these on the master. The master detects the change and distributes it to agents
on their next keepalive (default 10 seconds). With agent config hot reload (4.14),
agents apply the new config without dropping their connection.

## 11.1 Windows group agent.conf

Full file in `configs/agents/agent-windows.conf`. Collects Windows Security, System, and
Application channels, optional Sysmon, and tags the asset.

```xml
<agent_config>
  <!-- Windows Security log -->
  <localfile>
    <location>Security</location>
    <log_format>eventchannel</log_format>
  </localfile>

  <!-- Windows System log -->
  <localfile>
    <location>System</location>
    <log_format>eventchannel</log_format>
  </localfile>

  <!-- Windows Application log -->
  <localfile>
    <location>Application</location>
    <log_format>eventchannel</log_format>
  </localfile>

  <!-- Optional: Sysmon operational channel -->
  <localfile>
    <location>Microsoft-Windows-Sysmon/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>

  <labels>
    <label key="asset.os">windows</label>
  </labels>
</agent_config>
```

## 11.2 Linux group agent.conf

Full file in `configs/agents/agent-linux.conf`. Collects auth and syslog, optional auditd,
and tags the asset.

```xml
<agent_config>
  <!-- Authentication events -->
  <localfile>
    <location>/var/log/auth.log</location>
    <log_format>syslog</log_format>
  </localfile>

  <!-- System log -->
  <localfile>
    <location>/var/log/syslog</location>
    <log_format>syslog</log_format>
  </localfile>

  <!-- Optional: auditd -->
  <localfile>
    <location>/var/log/audit/audit.log</location>
    <log_format>audit</log_format>
  </localfile>

  <labels>
    <label key="asset.os">linux</label>
  </labels>
</agent_config>
```

## 11.3 Validate the agent.conf

Check for syntax errors before relying on distribution:

```bash
/var/ossec/bin/verify-agent-conf
```

## 11.4 Restart the manager (optional, speeds distribution)

```bash
sudo systemctl restart wazuh-manager
```

The manager distributes the new file on the next agent keepalive even without a
restart; restarting just pushes it faster.

## 11.5 Confirm an agent received the config

On the agent, the merged shared config arrives as `merged.mg`:

```bash
# Linux agent
ls -l /var/ossec/etc/shared/merged.mg
tail -n 30 /var/ossec/logs/ossec.log | grep -i "merged"
```

```powershell
# Windows agent
Get-Content "C:\Program Files (x86)\ossec-agent\shared\merged.mg" -Tail 30
```

You can also confirm group sync status from the manager:

```bash
/var/ossec/bin/agent_groups -l -g windows
```

## 11.6 Notes

- `agent.conf` controls what the agent collects and runs. Rules and decoders stay on
  the manager.
- In a cluster, always build the config on the master node so it propagates to
  workers and out to agents.

---

# 12. Custom Rules and Decoder Management

Rules and decoders live only on the manager. Agents ship logs; the manager decodes
and matches them. In a cluster, manage them on the master so they synchronize to
workers automatically. Reference:
https://documentation.wazuh.com/current/user-manual/ruleset/

## 12.1 File locations

- Custom rules: `/var/ossec/etc/rules/`
- Custom decoders: `/var/ossec/etc/decoders/`

Example structure (files provided in `configs/`):

```
/var/ossec/etc/rules/windows_custom_rules.xml
/var/ossec/etc/rules/linux_custom_rules.xml
/var/ossec/etc/decoders/custom_decoders.xml
```

## 12.2 Why rules are not pushed to endpoints

The agent only collects and forwards logs. The manager performs decoding and rule
matching centrally. This keeps detection logic in one place, lets you update
detections without touching endpoints, and ensures every worker applies the same
ruleset because the master synchronizes it.

## 12.3 Windows: failed login Event ID 4625

`/var/ossec/etc/rules/windows_custom_rules.xml` (full file in
`configs/server/windows_custom_rules.xml`). Wazuh already decodes Windows eventchannel logs,
so this builds on the built in Windows decoders:

```xml
<group name="windows,authentication_failures,lab_custom,">

  <rule id="100100" level="5">
    <if_sid>60000</if_sid>
    <field name="win.system.eventID">^4625$</field>
    <description>Windows: failed logon (Event ID 4625) for $(win.eventdata.targetUserName)</description>
    <mitre>
      <id>T1110</id>
    </mitre>
  </rule>

  <rule id="100101" level="10" frequency="5" timeframe="120">
    <if_matched_sid>100100</if_matched_sid>
    <same_field>win.eventdata.targetUserName</same_field>
    <description>Windows: possible brute force, 5 failed logons in 120s for $(win.eventdata.targetUserName)</description>
    <mitre>
      <id>T1110</id>
    </mitre>
  </rule>

</group>
```

## 12.4 Linux: failed SSH login

`/var/ossec/etc/rules/linux_custom_rules.xml` (full file in
`configs/server/linux_custom_rules.xml`). Built on the default sshd decoders:

```xml
<group name="linux,syslog,sshd,lab_custom,">

  <rule id="100200" level="5">
    <if_sid>5700</if_sid>
    <match>Failed password</match>
    <description>Linux: failed SSH login from $(srcip)</description>
    <mitre>
      <id>T1110</id>
    </mitre>
  </rule>

  <rule id="100201" level="10" frequency="5" timeframe="120">
    <if_matched_sid>100200</if_matched_sid>
    <same_source_ip />
    <description>Linux: possible SSH brute force, 5 failures in 120s from $(srcip)</description>
    <mitre>
      <id>T1110</id>
    </mitre>
  </rule>

</group>
```

## 12.5 Example custom decoder

Most lab logs are already decoded by built in decoders. Use a custom decoder only
for a custom log format. `/var/ossec/etc/decoders/custom_decoders.xml` (full file in
`configs/server/custom_decoders.xml`) shows the pattern for a hypothetical app log:

```xml
<decoder name="lab-app">
  <prematch>^labapp: </prematch>
</decoder>

<decoder name="lab-app-fields">
  <parent>lab-app</parent>
  <regex>user=(\S+) action=(\S+) result=(\S+)</regex>
  <order>user, action, result</order>
</decoder>
```

## 12.6 Test and apply

Test decoding and rule matching with the logtest tool before restarting:

```bash
/var/ossec/bin/wazuh-logtest
# paste a sample log line, confirm decoder and rule id fire
```

Set ownership and restart the master (sync propagates to workers):

```bash
chown wazuh:wazuh /var/ossec/etc/rules/*.xml /var/ossec/etc/decoders/*.xml
sudo systemctl restart wazuh-manager
sudo tail -f /var/ossec/logs/cluster.log   # watch integrity sync to workers
```

## 12.7 Cluster reminder

Edit rules and decoders only on the master. The integrity sync thread pushes user
defined rules, decoders, CDB lists, and group files from master to workers. Edits on
a worker are overwritten on the next sync.

---

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

---

# 14. Ubuntu Linux Agent Mass Deployment with Ansible

Two Ubuntu endpoints: ubuntu-agent-01 (192.168.90.119), ubuntu-agent-02
(192.168.90.120). Deployed with Ansible, all enrollment variables pointing at the load
balancer.

Deployment variables:
- `WAZUH_MANAGER=192.168.90.112` (LB IP)
- `WAZUH_REGISTRATION_SERVER=192.168.90.112` (LB IP)
- `WAZUH_AGENT_GROUP=linux`
- `WAZUH_REGISTRATION_PASSWORD=<password>` (only if enrollment password enabled)

The `linux` group must already exist (section 10).

All four files below are also in `configs/ansible/`.

## 14.1 inventory.ini

```ini
[linux_agents]
ubuntu-agent-01 ansible_host=192.168.90.119
ubuntu-agent-02 ansible_host=192.168.90.120

[linux_agents:vars]
ansible_user=root
ansible_become=true
```

## 14.2 ansible.cfg

```ini
[defaults]
inventory = inventory.ini
host_key_checking = False
retry_files_enabled = False
deprecation_warnings = False

[privilege_escalation]
become = True
become_method = sudo
```

## 14.3 group_vars/linux_agents.yml

```yaml
wazuh_manager: "192.168.90.112"
wazuh_registration_server: "192.168.90.112"
wazuh_agent_group: "linux"
wazuh_registration_password: "WazuhEnroll2024!"
wazuh_agent_version: "4.14.5-1"
```

## 14.4 install-wazuh-agent.yml

```yaml
---
- name: Deploy Wazuh agent to Ubuntu endpoints
  hosts: linux_agents
  become: true
  tasks:

    - name: Install dependencies
      apt:
        name:
          - curl
          - gnupg
          - apt-transport-https
          - lsb-release
        state: present
        update_cache: true

    - name: Add Wazuh GPG key
      ansible.builtin.shell: |
        curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
        gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
        chmod 644 /usr/share/keyrings/wazuh.gpg
      args:
        creates: /usr/share/keyrings/wazuh.gpg

    - name: Add Wazuh repository
      ansible.builtin.apt_repository:
        repo: "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main"
        filename: wazuh
        state: present

    - name: Install wazuh-agent with enrollment variables
      ansible.builtin.apt:
        name: "wazuh-agent={{ wazuh_agent_version }}"
        state: present
        update_cache: true
      environment:
        WAZUH_MANAGER: "{{ wazuh_manager }}"
        WAZUH_REGISTRATION_SERVER: "{{ wazuh_registration_server }}"
        WAZUH_AGENT_GROUP: "{{ wazuh_agent_group }}"
        WAZUH_REGISTRATION_PASSWORD: "{{ wazuh_registration_password }}"

    - name: Reload systemd
      ansible.builtin.systemd:
        daemon_reload: true

    - name: Enable and start wazuh-agent
      ansible.builtin.systemd:
        name: wazuh-agent
        enabled: true
        state: started

    - name: Validate service is active
      ansible.builtin.command: systemctl is-active wazuh-agent
      register: agent_status
      changed_when: false

    - name: Show service status
      ansible.builtin.debug:
        msg: "wazuh-agent on {{ inventory_hostname }} is {{ agent_status.stdout }}"
```

## 14.5 Run the playbook

```bash
# Connectivity check
ansible -i inventory.ini linux_agents -m ping

# Deploy
ansible-playbook -i inventory.ini install-wazuh-agent.yml
```

## 14.6 Linux validation commands

Run on each Ubuntu endpoint:

```bash
systemctl status wazuh-agent
tail -f /var/ossec/logs/ossec.log
nc -vz 192.168.90.112 1514
nc -vz 192.168.90.112 1515
```

Healthy result: service active (running), ossec.log shows successful enrollment via
the registration server and connection to the manager, both nc tests succeed. The
agent appears in the `linux` group on the dashboard.

## 14.7 Note on enrollment via load balancer

Because enrollment (1515) is forwarded only to the master and reporting (1514) is
balanced across workers, `WAZUH_REGISTRATION_SERVER` and `WAZUH_MANAGER` can both be
`wazuh-lb.lab.local`. The agent registers through the LB to the master, then reports
through the LB to whichever worker the LB selects.
