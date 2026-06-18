# Part 4: Index Management and Validation

This part covers index and shard management (ISM retention, snapshots) and the
end to end validation, hardening, and success criteria.

---

# 15. Index and Shard Management

Managing indices and shards in the Wazuh indexer (OpenSearch) so disk does not fill,
search stays fast, the cluster stays healthy, and data is retained per policy.
Reference:
https://documentation.wazuh.com/current/user-manual/wazuh-indexer/

All API examples assume `-u admin:<PASSWORD>` and one of the indexer hosts.

## A. Index overview

| Index pattern               | Contents                                             |
|-----------------------------|------------------------------------------------------|
| `wazuh-alerts-*`            | Events that became alerts (the main searchable data) |
| `wazuh-archives-*`          | Raw event archive, only if archives are enabled      |
| `wazuh-monitoring-*`        | Agent status and operational monitoring data         |
| `wazuh-states-*` / internal | Vulnerability and internal state indices             |
| `.opensearch*`, `.kibana*`  | Dashboard and indexer internal indices               |

Difference:
- **Alerts index**: events that triggered a rule. This is what most dashboards and
  searches use.
- **Archives index**: the full raw event stream when `<logall_json>` is enabled. Much
  larger than alerts; enable only if you need raw retention for forensics or
  compliance.
- **Monitoring / internal**: operational data about the platform itself, smaller and
  shorter lived.

## B. Shard and replica planning

- A **primary shard** holds a portion of an index's data. An index is split into one
  or more primaries.
- A **replica shard** is a copy of a primary on a different node. Replicas provide
  high availability and add read capacity.
- Too many shards burden the cluster: each shard has memory and file handle overhead,
  and thousands of tiny shards slow the cluster manager and waste heap.
- Too few shards limits distribution: a single huge shard cannot spread across nodes
  and becomes a hotspot.
- Replicas enable HA: if a node holding a primary fails, a replica on another node is
  promoted, so search and indexing continue.
- Size shards by daily volume, targeting a healthy shard size (commonly 20 to 50 GB
  per shard). Adjust to your actual workload; this is a starting heuristic, not a
  rule.

### Shard sizing table

| Scenario       | Endpoints | Est. daily ingest | Primary shards | Replicas | Retention    | Notes                                                                                  |
|----------------|-----------|-------------------|----------------|----------|--------------|----------------------------------------------------------------------------------------|
| Small lab      | 4         | ~0.2 GB/day       | 1              | 1        | 7 to 14 days | One primary is plenty; replica still useful with 3 nodes for HA testing                |
| Production sim | 200       | ~10 GB/day        | 3              | 1        | 90 days      | 3 primaries spread across 3 nodes, daily rollover keeps shards in the 20 to 50 GB band |

With 3 indexer nodes, 3 primaries plus 1 replica each gives 6 shards that distribute
two per node, which survives a single node loss.

## C. Index retention policy

- Alerts: keep 30, 60, or 90 days depending on need.
- Archives: shorter or longer than alerts depending on compliance, but they are
  large, so be conservative in a lab.
- Lab: short retention so disk does not fill. Suggested: alerts 7 to 14 days,
  archives disabled or 7 days.
- Production: retention by audit, compliance, and storage capacity. Suggested:
  alerts 90 days, archives 30 to 180 days as required.

## D. Index State Management (ISM) lifecycle policy

OpenSearch ISM rolls indices over by age or size and deletes them after retention.
Conceptual policy (adjust to your indexer/OpenSearch version). Full files in
`configs/indexer/ism-policy-alerts.json` and `configs/indexer/ism-policy-archives.json`.

Policy for `wazuh-alerts-*`:

```json
{
  "policy": {
    "description": "Wazuh alerts lifecycle: rollover then delete",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [
          {
            "rollover": {
              "min_index_age": "1d",
              "min_primary_shard_size": "40gb"
            }
          }
        ],
        "transitions": [
          { "state_name": "delete", "conditions": { "min_index_age": "90d" } }
        ]
      },
      {
        "name": "delete",
        "actions": [ { "delete": {} } ]
      }
    ],
    "ism_template": [
      { "index_patterns": ["wazuh-alerts-*"], "priority": 100 }
    ]
  }
}
```

For `wazuh-archives-*` use the same shape with a different `min_index_age` in the
delete transition (for example 30d in lab, longer in prod) and a smaller rollover
size if archives are heavy.

Rollover condition: age 1 day or primary shard size 40 GB, whichever first. Delete
condition: index age past retention.

Apply both policies to the cluster (run once, from any node). Each policy includes an
`ism_template` block so it attaches automatically to matching indices:

```bash
# Alerts policy (90 day retention)
curl -k -u admin:<PASSWORD> -X PUT \
  "https://192.168.90.111:9200/_plugins/_ism/policies/wazuh-alerts-policy" \
  -H "Content-Type: application/json" \
  --data-binary @configs/indexer/ism-policy-alerts.json

# Archives policy (30 day retention)
curl -k -u admin:<PASSWORD> -X PUT \
  "https://192.168.90.111:9200/_plugins/_ism/policies/wazuh-archives-policy" \
  -H "Content-Type: application/json" \
  --data-binary @configs/indexer/ism-policy-archives.json
```

Confirm both are registered:

```bash
curl -k -u admin:<PASSWORD> \
  "https://192.168.90.111:9200/_plugins/_ism/policies" | grep -o '"_id" : "[^"]*"'
```

You should see `wazuh-alerts-policy` and `wazuh-archives-policy`.

## E. Index templates

Templates control settings for new indices: `number_of_shards`,
`number_of_replicas`, `refresh_interval`, mapping compatibility, and the index
pattern they apply to. Conceptual template for `wazuh-alerts-*` (full file in
`configs/indexer/index-template-alerts.json`):

```json
{
  "index_patterns": ["wazuh-alerts-*"],
  "priority": 100,
  "template": {
    "settings": {
      "number_of_shards": 3,
      "number_of_replicas": 1,
      "refresh_interval": "5s"
    }
  }
}
```

For `wazuh-archives-*` use the same structure with shard counts suited to the larger
volume.

Notes:
- Do not blindly overwrite the Wazuh shipped template without a backup; you can break
  mappings.
- A shard change applies to new indices only, not existing ones.
- To change shards on existing indices you must reindex, shrink, or split, which is a
  planned operation, not a casual edit.

## F. Disk watermark and storage monitoring

OpenSearch disk watermarks:
- **low watermark** (default 85%): stops allocating new shards to the node.
- **high watermark** (default 90%): tries to move shards off the node.
- **flood stage watermark** (default 95%): sets indices on the node to read only,
  which stops ingestion until disk is freed.

Monitoring checklist:
- cluster health green / yellow / red
- disk usage per node
- shard allocation
- unassigned shards
- indexing rate
- search latency
- JVM heap pressure
- CPU, RAM, disk IO

Check commands:

```bash
curl -k -u admin:<PASSWORD> "https://192.168.90.111:9200/_cluster/health?pretty"
curl -k -u admin:<PASSWORD> "https://192.168.90.111:9200/_nodes/stats?pretty"
curl -k -u admin:<PASSWORD> "https://192.168.90.111:9200/_cat/indices?v"
curl -k -u admin:<PASSWORD> "https://192.168.90.111:9200/_cat/shards?v"
curl -k -u admin:<PASSWORD> "https://192.168.90.111:9200/_cat/allocation?v"
curl -k -u admin:<PASSWORD> "https://192.168.90.111:9200/_cat/recovery?v"
curl -k -u admin:<PASSWORD> "https://192.168.90.111:9200/_cluster/pending_tasks?pretty"
```

## G. Shard allocation awareness

With 3 indexer nodes:
- Primaries and replicas distribute across the three nodes.
- A replica is never placed on the same node as its primary, so one node holds at
  most one copy of any given shard.
- If one indexer node dies, every primary on it has a replica elsewhere that gets
  promoted, so the cluster keeps serving search (it goes yellow until replicas are
  rebuilt, not red).
- Reading `_cat/shards`: columns are index, shard number, `p` (primary) or `r`
  (replica), state (STARTED, RELOCATING, UNASSIGNED), and the node. Confirm each
  shard's primary and replica sit on different nodes.

## H. Capacity planning

Rough formula:

```
total_storage = daily_ingest_size * retention_days * replica_factor * overhead_factor
```

`replica_factor` is 2 when you keep 1 replica (primary + 1 copy). `overhead_factor`
of about 1.2 covers indexing overhead and merges.

Worked example: 5 GB/day, 90 days, 1 replica, 1.2 overhead:
`5 * 90 * 2 * 1.2 = 1080 GB`.

| Endpoints | Est. daily ingest | Retention days | Replica factor | Overhead | Est. total storage | Recommended disk per indexer node (3 nodes)   |
|-----------|-------------------|----------------|----------------|----------|--------------------|-----------------------------------------------|
| 4 (lab)   | 0.2 GB            | 14             | 2              | 1.2      | ~6.7 GB            | 50 GB (lab headroom)                          |
| 50        | 2.5 GB            | 90             | 2              | 1.2      | ~540 GB            | ~250 GB                                       |
| 100       | 5 GB              | 90             | 2              | 1.2      | ~1080 GB           | ~450 GB                                       |
| 200       | 10 GB             | 90             | 2              | 1.2      | ~2160 GB           | ~850 GB                                       |

Per node disk is total divided across 3 nodes plus headroom to stay under the high
watermark.

## I. Backup and snapshot

- The indexer cluster is not a backup of itself. Replicas protect against node loss,
  not against accidental deletion or corruption.
- Configure a snapshot repository (shared filesystem or S3 compatible) before you
  need it.
- Backing up Wazuh configuration is separate from backing up index data.
- Always test restoring a snapshot; an untested backup is not a backup.

Backup plan:
- Daily snapshot of `wazuh-alerts-*`.
- Weekly full retention kept for a defined window.
- Monthly restore test into a scratch index.
- Configuration backups of: Wazuh manager config (`/var/ossec/etc/ossec.conf`),
  rules, decoders, `agent.conf` group files, certificates, and the HAProxy config.

What each backup covers:
- **Index data backup**: snapshots of OpenSearch indices (the alert/archive data).
- **Wazuh manager config backup**: `ossec.conf`, rules, decoders, CDB lists, group
  shared configs, client.keys.
- **Dashboard config backup**: `opensearch_dashboards.yml`, `wazuh.yml`, saved
  objects.
- **Certificate backup**: the `wazuh-certificates.tar` and deployed certs.
- **HAProxy config backup**: `/etc/haproxy/haproxy.cfg`.

Snapshot setup and use:

Step 1: confirm the repository path is ready. The indexer config already declares
`path.repo: ["/mnt/wazuh-snapshots"]` and the directory was created on every node
during indexer setup (section 6.5b), so no restart is needed here. Confirm on each
node if you want:

```bash
ls -ld /mnt/wazuh-snapshots          # exists, owned by wazuh-indexer
grep path.repo /etc/wazuh-indexer/opensearch.yml
```

Step 2: register the repository (run once, from any node). In this lab each node has
its own local `/mnt/wazuh-snapshots`, so register with `verify=false`; the verify step
expects a single shared location across nodes. For production use one shared location
(NFS or S3) and you can drop `verify=false`.

```bash
curl -k -u admin:<PASSWORD> -X PUT \
  "https://192.168.90.111:9200/_snapshot/wazuh_backup?verify=false" \
  -H 'Content-Type: application/json' -d '{
    "type": "fs",
    "settings": {
      "location": "/mnt/wazuh-snapshots",
      "compress": true
    }
  }'
```

Step 3: take a snapshot of the alerts indices:

```bash
curl -k -u admin:<PASSWORD> -X PUT \
  "https://192.168.90.111:9200/_snapshot/wazuh_backup/daily-$(date +%F)?wait_for_completion=true" \
  -H 'Content-Type: application/json' -d '{
    "indices": "wazuh-alerts-*",
    "ignore_unavailable": true,
    "include_global_state": false
  }'
```

A successful snapshot returns `"state": "SUCCESS"`.

Step 4: restore test into a renamed index so it never overwrites live data:

```bash
curl -k -u admin:<PASSWORD> -X POST \
  "https://192.168.90.111:9200/_snapshot/wazuh_backup/<SNAPSHOT_NAME>/_restore" \
  -H 'Content-Type: application/json' -d '{
    "indices": "wazuh-alerts-2026.06.01",
    "rename_pattern": "(.+)",
    "rename_replacement": "restored-$1"
  }'
```

## J. Routine index maintenance

Day to day index operations for this lab:

- Watch disk against the watermarks with `_cat/allocation?v`. Keep usage well below
  the low watermark so ISM rollover and delete have room to work.
- Confirm rollover is firing on schedule by checking index ages in `_cat/indices?v`
  against the ISM thresholds.
- Confirm retention is running by reading the ISM explain API for `wazuh-alerts-*`.
- Keep the shard count healthy (`_cat/shards?v | wc -l`) by relying on the template
  sizing in section B and rollover rather than letting indices grow unbounded.
- Keep heap comfortable (`_nodes/stats`) by spreading shards evenly across the three
  nodes.

If disk ever crosses the flood stage watermark, OpenSearch sets indices read only.
After freeing disk, clear the read only block:

```bash
curl -k -u admin:<PASSWORD> -X PUT "https://192.168.90.111:9200/_all/_settings" \
  -H 'Content-Type: application/json' -d '{
    "index.blocks.read_only_allow_delete": null
  }'
```

## K. Validation and success criteria for index management

- All three Wazuh indexer nodes join the cluster.
- Cluster health is green under normal conditions.
- No unassigned shards.
- `wazuh-alerts-*` index exists.
- Shards distribute across all three indexer nodes.
- Replicas are active per design.
- Retention policy (ISM) is attached.
- Rollover policy runs or is ready to test.
- Disk usage is safely below the low watermark.
- Dashboard can still search alerts.
- No flood stage read only block on any index.

## L. Additional deliverables for index management

These are produced as part of this section and live in `configs/`:
- Index and shard management plan (this document).
- Index retention policy (`configs/indexer/ism-policy-alerts.json`, `configs/indexer/ism-policy-archives.json`).
- Shard sizing table (section B above).
- Storage capacity planning table (section H above).
- Index health validation checklist (section K above).
- Snapshot and restore plan (section I above).
- Routine index maintenance guide (section J above).

---

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
master per Part 2, server cluster section 7.4b).

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
