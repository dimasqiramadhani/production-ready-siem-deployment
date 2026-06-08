# 15. Index and Shard Management

Managing indices and shards in the Wazuh indexer (OpenSearch) so disk does not fill,
search stays fast, the cluster stays healthy, and data is retained per policy.
Reference:
https://documentation.wazuh.com/current/user-manual/wazuh-indexer/

All API examples assume `-u admin:<PASSWORD>` and one of the indexer hosts.

## A. Index overview

| Index pattern | Contents |
|---------------|----------|
| `wazuh-alerts-*` | Events that became alerts (the main searchable data) |
| `wazuh-archives-*` | Raw event archive, only if archives are enabled |
| `wazuh-monitoring-*` | Agent status and operational monitoring data |
| `wazuh-states-*` / internal | Vulnerability and internal state indices |
| `.opensearch*`, `.kibana*` | Dashboard and indexer internal indices |

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

| Scenario | Endpoints | Est. daily ingest | Primary shards | Replicas | Retention | Notes |
|----------|-----------|-------------------|----------------|----------|-----------|-------|
| Small lab | 4 | ~0.2 GB/day | 1 | 1 | 7 to 14 days | One primary is plenty; replica still useful with 3 nodes for HA testing |
| Production sim | 200 | ~10 GB/day | 3 | 1 | 90 days | 3 primaries spread across 3 nodes, daily rollover keeps shards in the 20 to 50 GB band |

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
`configs/ism-policy-alerts.json` and `configs/ism-policy-archives.json`.

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

## E. Index templates

Templates control settings for new indices: `number_of_shards`,
`number_of_replicas`, `refresh_interval`, mapping compatibility, and the index
pattern they apply to. Conceptual template for `wazuh-alerts-*` (full file in
`configs/index-template-alerts.json`):

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
curl -k -u admin:<PASSWORD> "https://10.10.10.11:9200/_cluster/health?pretty"
curl -k -u admin:<PASSWORD> "https://10.10.10.11:9200/_nodes/stats?pretty"
curl -k -u admin:<PASSWORD> "https://10.10.10.11:9200/_cat/indices?v"
curl -k -u admin:<PASSWORD> "https://10.10.10.11:9200/_cat/shards?v"
curl -k -u admin:<PASSWORD> "https://10.10.10.11:9200/_cat/allocation?v"
curl -k -u admin:<PASSWORD> "https://10.10.10.11:9200/_cat/recovery?v"
curl -k -u admin:<PASSWORD> "https://10.10.10.11:9200/_cluster/pending_tasks?pretty"
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

| Endpoints | Est. daily ingest | Retention days | Replica factor | Overhead | Est. total storage | Recommended disk per indexer node (3 nodes) |
|-----------|-------------------|----------------|----------------|----------|--------------------|-----------------------------------------------|
| 4 (lab) | 0.2 GB | 14 | 2 | 1.2 | ~6.7 GB | 50 GB (lab headroom) |
| 50 | 2.5 GB | 90 | 2 | 1.2 | ~540 GB | ~250 GB |
| 100 | 5 GB | 90 | 2 | 1.2 | ~1080 GB | ~450 GB |
| 200 | 10 GB | 90 | 2 | 1.2 | ~2160 GB | ~850 GB |

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

Snapshot example (register repo, then snapshot):

```bash
# Register a filesystem repository (path.repo must be set in opensearch.yml)
curl -k -u admin:<PASSWORD> -X PUT "https://10.10.10.11:9200/_snapshot/wazuh_backup" \
  -H 'Content-Type: application/json' -d '{
    "type": "fs",
    "settings": { "location": "/mnt/wazuh-snapshots" }
  }'

# Take a snapshot of the alerts indices
curl -k -u admin:<PASSWORD> -X PUT \
  "https://10.10.10.11:9200/_snapshot/wazuh_backup/daily-$(date +%F)?wait_for_completion=false" \
  -H 'Content-Type: application/json' -d '{
    "indices": "wazuh-alerts-*",
    "include_global_state": false
  }'

# Restore test
curl -k -u admin:<PASSWORD> -X POST \
  "https://10.10.10.11:9200/_snapshot/wazuh_backup/<SNAPSHOT_NAME>/_restore" \
  -H 'Content-Type: application/json' -d '{
    "indices": "wazuh-alerts-2026.06.01",
    "rename_pattern": "(.+)",
    "rename_replacement": "restored-$1"
  }'
```

## J. Operational runbook

| Problem | Impact | Check command | Possible root cause | Remediation | Risk note |
|---------|--------|---------------|---------------------|-------------|-----------|
| Disk almost full | Ingestion about to stop | `_cat/allocation?v` | Retention too long, no rollover | Delete old indices, enforce ISM, add disk | Deleting indices is irreversible |
| Cluster yellow | Replicas unassigned, HA reduced | `_cluster/health?pretty` | A node down or replicas not allocated | Bring node back, check allocation | Yellow still serves search |
| Cluster red | Some primary data unavailable | `_cat/shards?v` (UNASSIGNED p) | Primary shard lost, disk full | Recover node, restore from snapshot | Possible data loss if no replica/snapshot |
| Unassigned shards | Degraded HA or search gaps | `_cat/shards?v` | Watermark hit, allocation disabled | Free disk, re enable allocation | Watch heap during recovery |
| Too many shards | Heap pressure, slow cluster | `_cat/shards?v \| wc -l` | Over sharded template / no rollover | Reduce shards in template, reindex/shrink | Reindex is heavy, schedule it |
| Index too big | Slow search, uneven node load | `_cat/indices?v` | Rollover not firing | Fix ISM rollover thresholds | New settings apply to new indices |
| Retention not running | Disk grows, old data lingers | check ISM explain API | ISM policy not attached | Attach policy to index template | Verify delete state conditions |
| Dashboard slow | Poor analyst experience | `_nodes/stats` heap, `_cat/recovery` | Heap pressure, hot node, big shards | Tune shards, add heap, spread load | Avoid heap above ~75% sustained |
| Events not arriving (indexer full) | No new alerts | `_cluster/health`, disk | Flood stage read only block | Free disk then clear read only block | Ingestion paused until cleared |
| Flood stage read only block | Indices read only, ingest stops | see command below | Disk over 95% on a node | Free disk, then clear block | Clear only after disk recovers |

Clear a flood stage read only block after freeing disk:

```bash
curl -k -u admin:<PASSWORD> -X PUT "https://10.10.10.11:9200/_all/_settings" \
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
- Index retention policy (`configs/ism-policy-alerts.json`, `configs/ism-policy-archives.json`).
- Shard sizing table (section B above).
- Storage capacity planning table (section H above).
- Index health validation checklist (section K above).
- Snapshot and restore plan (section I above).
- Index troubleshooting runbook (section J above).
