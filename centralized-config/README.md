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

Full file in `configs/agent-windows.conf`. Collects Windows Security, System, and
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

Full file in `configs/agent-linux.conf`. Collects auth and syslog, optional auditd,
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
