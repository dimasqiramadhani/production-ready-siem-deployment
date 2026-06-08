# 16. Validation, Troubleshooting, Hardening, and Success Criteria

## 16.1 End to end validation

Run top to bottom. Each layer must pass before trusting the next.

### Indexer cluster
```bash
curl -k -u admin:<PASSWORD> "https://10.10.10.11:9200/_cluster/health?pretty"   # green, 3 nodes
curl -k -u admin:<PASSWORD> "https://10.10.10.11:9200/_cat/nodes?v"             # 3 nodes, one manager
```

### Server cluster
```bash
sudo /var/ossec/bin/cluster_control -l   # master + 2 workers
sudo /var/ossec/bin/cluster_control -a   # agents spread across workers
```

### Filebeat to indexer
```bash
sudo filebeat test output    # on each server node, expect connection OK to all indexers
```

### Dashboard
- Log in at https://wazuh-dashboard.lab.local
- Agents and cluster views populate (API on 55000 OK)
- Discover shows alerts (indexer on 9200 OK)

### Load balancer
```bash
sudo ss -lntp | grep -E '1514|1515'      # HAProxy listening
nc -vz wazuh-lb.lab.local 1514           # from an agent host
nc -vz wazuh-lb.lab.local 1515
```

### Agents and groups
```bash
sudo /var/ossec/bin/agent_control -l         # 4 agents Active
sudo /var/ossec/bin/agent_groups -l -g windows   # 2 windows agents
sudo /var/ossec/bin/agent_groups -l -g linux     # 2 linux agents
```

### Event ingestion
- Generate a failed SSH login on ubuntu-agent-01 and a failed logon on win-agent-01.
- Confirm alerts 100200 / 100100 appear in Discover within seconds.

## 16.2 Common cross layer troubleshooting

| Symptom | Where to look |
|---------|---------------|
| Agent enrolled but no events | LB 1514 backend health, worker `ossec.log`, agent `ossec.log` |
| Events on worker but not in dashboard | `filebeat test output`, indexer health, index template |
| Agent in wrong group | enrolled before group existed; reassign with `agent_groups`, re enroll with correct `WAZUH_AGENT_GROUP` |
| Dashboard management views empty | server API on 55000, `wazuh.yml` creds, master API running |
| Cluster sync errors | `/var/ossec/logs/cluster.log`, 1516 open, identical `<key>` |

## 16.3 Hardening checklist

- Change all default passwords (indexer admin, kibanaserver, wazuh-wui, dashboard
  admin) after install.
- Enable the agent enrollment password and distribute it only via the deployment
  variable, not in plaintext repos.
- Restrict 9200 and 55000 to the server cluster, dashboard, and indexer subnet only.
- Restrict 1516 to the server nodes only.
- Keep RDP/WinRM/SSH admin ports closed to the internet; allow from a jump host.
- Use real certificates from an internal CA instead of the self signed lab certs for
  any non lab use.
- Disable the Wazuh package repository after install to prevent accidental upgrades.
- Enable disk watermark alerts so you act before flood stage.
- Snapshot VMs after a known good deployment as a rollback point.
- Restrict the HAProxy stats page or disable it outside the lab.

## 16.4 Overall success criteria

- 3 indexer nodes in one green cluster, no unassigned shards.
- Server cluster shows 1 master and 2 workers via `cluster_control -l`.
- Filebeat ships alerts from all server nodes to the indexer.
- Dashboard reachable over HTTPS, both backends (9200 and 55000) working.
- HAProxy forwards 1515 to master and balances 1514 across workers, failover proven.
- 4 agents active: 2 in `windows`, 2 in `linux`, all enrolled through the LB.
- Centralized `agent.conf` delivered to each group.
- Custom rules fire on test events and alerts are searchable in the dashboard.
- ISM retention and rollover attached, capacity planning documented.
- Snapshot repository configured and a restore test completed.

## 16.5 Lab report template

Capture for the final report: cluster health output, `cluster_control -l` output,
agent list with groups, a screenshot of a test alert in Discover, `_cat/shards`
showing distribution across 3 nodes, the ISM explain output for `wazuh-alerts-*`, and
a successful restore test result.
