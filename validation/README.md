# 16. Validation, Hardening, and Success Criteria

## 16.1 End to end validation

Run top to bottom. Each layer must pass before trusting the next.

### Indexer cluster
```bash
curl -k -u admin:<PASSWORD> "https://192.168.90.111:9200/_cluster/health?pretty"   # green, 3 nodes
curl -k -u admin:<PASSWORD> "https://192.168.90.111:9200/_cat/nodes?v"             # 3 nodes, one manager
```

### Server cluster
```bash
sudo /var/ossec/bin/cluster_control -l   # master + 2 workers
sudo /var/ossec/bin/cluster_control -a   # agents spread across workers
```

### Wazuh API
```bash
# Must return a token. Run on the master.
curl -sk -u wazuh-wui:wazuh-wui \
  -X POST https://192.168.90.115:55000/security/user/authenticate | python3 -m json.tool | head -3
```
A token confirms the dashboard can reach the manager API on 55000. On the Server APIs
page the Updates status column should be clear (the update check is disabled on the
master per 07-server-cluster 7.4b).

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
Generate a failed SSH login on ubuntu-agent-01:

```bash
# On ubuntu-agent-01 (192.168.90.119)
for i in {1..6}; do
  sshpass -p "wrongpassword" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=3 invaliduser@127.0.0.1 2>/dev/null || true
done
```

Confirm the alerts reached the indexer within seconds:

```bash
curl -k -u admin:<PASSWORD> \
  "https://192.168.90.111:9200/wazuh-alerts-*/_search?pretty" \
  -H "Content-Type: application/json" -d '{
    "size": 3,
    "sort": [{"timestamp": {"order": "desc"}}],
    "query": { "match": {"agent.name": "agent-linux-01"} }
  }'
```

Expected: rule 5710 (sshd: attempt to login using a non-existent user) and rule 5503
(PAM: user login failed), both at level 5, also visible in the dashboard Discover view.
This proves the full path: agent collect, worker decode and rule match, Filebeat ship,
indexer store, dashboard search.

## 16.2 Hardening checklist

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

## 16.3 Overall success criteria

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

## 16.4 Lab report template

Capture for the final report: cluster health output, `cluster_control -l` output,
agent list with groups, a screenshot of a test alert in Discover, `_cat/shards`
showing distribution across 3 nodes, the ISM explain output for `wazuh-alerts-*`, and
a successful restore test result.
