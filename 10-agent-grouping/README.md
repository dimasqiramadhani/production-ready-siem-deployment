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
curl -k -u wazuh-wui:<PASSWORD> "https://10.10.10.21:55000/agents?group=windows&pretty" \
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
