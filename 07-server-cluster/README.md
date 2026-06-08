# 7. Wazuh Server Cluster Configuration

Three server nodes: wazuh-master-01 (master, 10.10.10.21), wazuh-worker-01 (worker,
10.10.10.22), wazuh-worker-02 (worker, 10.10.10.23). Reference:
https://documentation.wazuh.com/current/user-manual/wazuh-server-cluster/

## 7.1 Concept

There can be only one master node in a cluster. All other servers are workers. For
both node types the cluster configuration lives in the `<cluster>` block of
`/var/ossec/etc/ossec.conf`. The master receives and manages agent registration and
deletion and synchronizes shared state (agent keys, user defined rules, decoders,
CDB lists, SCA policies, and group files) to the workers. Workers receive agent
events. During synchronization, master data always takes precedence.

Important: changes to `ossec.conf` on the master are not auto synchronized to
workers. Replicate manually and restart. Rules, decoders, CDB lists, and group
files (centralized config) are synchronized automatically from master to workers.

## 7.2 Install the Wazuh server (each of master, worker-01, worker-02)

```bash
sudo apt -y install wazuh-manager
sudo systemctl daemon-reload
sudo systemctl enable wazuh-manager
sudo systemctl start wazuh-manager
```

## 7.3 Generate the cluster key (once, on the master)

The key must be identical on all nodes.

```bash
openssl rand -hex 16
# example output: 9c1f2a4b7d8e0c5a6b3f1e2d4c6a8b0e
```

## 7.4 Master cluster block (wazuh-master-01)

Edit `/var/ossec/etc/ossec.conf`. Full file in `configs/ossec-cluster-master.conf`.

```xml
<cluster>
  <name>wazuh</name>
  <node_name>wazuh-master-01</node_name>
  <node_type>master</node_type>
  <key>9c1f2a4b7d8e0c5a6b3f1e2d4c6a8b0e</key>
  <port>1516</port>
  <bind_addr>0.0.0.0</bind_addr>
  <nodes>
    <node>10.10.10.21</node>
  </nodes>
  <hidden>no</hidden>
  <disabled>no</disabled>
</cluster>
```

## 7.5 Worker cluster block (wazuh-worker-01 and wazuh-worker-02)

Identical except `node_name`. Full files in `configs/ossec-cluster-worker-01.conf`
and `configs/ossec-cluster-worker-02.conf`.

```xml
<cluster>
  <name>wazuh</name>
  <node_name>wazuh-worker-01</node_name>      <!-- wazuh-worker-02 on the second worker -->
  <node_type>worker</node_type>
  <key>9c1f2a4b7d8e0c5a6b3f1e2d4c6a8b0e</key>
  <port>1516</port>
  <bind_addr>0.0.0.0</bind_addr>
  <nodes>
    <node>10.10.10.21</node>                  <!-- always the master IP -->
  </nodes>
  <hidden>no</hidden>
  <disabled>no</disabled>
</cluster>
```

The `<nodes>` block lists only the master, on every node including the master itself.
`<key>` is identical everywhere. `node_name` is unique.

## 7.6 Restart and validate

Restart each node after editing:

```bash
sudo systemctl restart wazuh-manager
```

Confirm the cluster on the master:

```bash
sudo /var/ossec/bin/cluster_control -l
```

Expected output lists the master and both workers with their types and addresses:

```
NAME             TYPE    VERSION  ADDRESS
wazuh-master-01  master  4.14.0   10.10.10.21
wazuh-worker-01  worker  4.14.0   10.10.10.22
wazuh-worker-02  worker  4.14.0   10.10.10.23
```

See agents distributed per node:

```bash
sudo /var/ossec/bin/cluster_control -a
```

## 7.7 Checking for cluster errors

Cluster activity is logged separately:

```bash
sudo tail -f /var/ossec/logs/cluster.log
grep -iE "error|sync" /var/ossec/logs/cluster.log | tail -20
```

General manager errors:

```bash
sudo tail -f /var/ossec/logs/ossec.log
```

## 7.8 Operating rules

- Only one master. The `<nodes>` list must contain exactly one node (the master).
- Workers receive agent events; the master coordinates and handles enrollment.
- The master synchronizes rules, decoders, agent groups, CDB lists, and centralized
  config to workers automatically.
- Make all rule, decoder, and centralized config changes on the master so they
  propagate. Do not edit them directly on workers; they will be overwritten.
- Confirm 1516/TCP is open between all server nodes or cluster sync will fail.

## 7.9 Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Worker not in `cluster_control -l` | key mismatch or 1516 blocked | Confirm identical `<key>`, open 1516 between nodes, restart worker |
| Two masters reported | both nodes set `node_type` master | Set workers to `worker`; only one master allowed |
| Rules not appearing on worker | edits made on worker, or sync error | Edit on master, check `cluster.log` for sync errors |
| Agents register but no alerts on a worker | ruleset not synced | Restart master, watch `cluster.log` for integrity sync |
