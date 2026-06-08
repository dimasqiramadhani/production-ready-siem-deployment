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
`configs/windows_custom_rules.xml`). Wazuh already decodes Windows eventchannel logs,
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
`configs/linux_custom_rules.xml`). Built on the default sshd decoders:

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
`configs/custom_decoders.xml`) shows the pattern for a hypothetical app log:

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
