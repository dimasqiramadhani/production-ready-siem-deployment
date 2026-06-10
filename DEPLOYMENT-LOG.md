# Deployment Log

Record of actual deployment progress and verified configurations.

## Environment

- All nodes: Ubuntu 22.04.5 LTS
- Wazuh version: 4.14.5 stable version (installed pinned as 4.14.5-1 on all nodes)
- Subnet: 192.168.90.0/24
- Access method: VPN

## Stage 0: OS Baseline (COMPLETED)

All 8 server nodes configured:
- Hostname set per role
- /etc/hosts populated on all nodes
- chrony installed and synced
- Swap 4 GB + vm.swappiness=10 on all nodes
- vm.max_map_count=262144 on indexer nodes (111, 113, 114)
- Dependencies installed (curl, gnupg, apt-transport-https, etc.)
- UFW configured per role
- Connectivity validated (nc tests)

## Stage 1: Certificates (COMPLETED)

Generated on wazuh-indexer-01 (192.168.90.111):
- Tool: wazuh-certs-tool.sh -A
- Config: config.yml with all 8 nodes
- Output: wazuh-certificates.tar (50K, 18 certificate files)
- Distributed via scp to all nodes

Certificates generated:
- admin.pem + admin-key.pem
- root-ca.pem + root-ca.key
- wazuh-indexer-01/02/03 pem + key
- wazuh-manager-master/worker-01/worker-02 pem + key
- wazuh-dashboard pem + key

## Stage 2: Indexer Cluster (COMPLETED)

Installed on 192.168.90.111, 192.168.90.113, 192.168.90.114.
JVM heap: -Xms1g -Xmx1g on all indexer nodes.
Cluster initialized with indexer-security-init.sh on indexer-01.

Validation result:
- status: green
- number_of_nodes: 3
- unassigned_shards: 0
- active_shards_percent: 100.0
- Cluster manager: wazuh-indexer-02 (192.168.90.113)

## Stage 3: Server Cluster (COMPLETED)

Installed wazuh-manager 4.14.5 on all three server nodes.
Installed Filebeat 7.10.2 on all three server nodes.

Cluster config:
- Cluster key: 65eee392122e08d63ee68141da37398b
- Master: wazuh-master-01 (192.168.90.115)
- Workers: wazuh-worker-01 (192.168.90.116), wazuh-worker-02 (192.168.90.117)

Enrollment password: WazuhEnroll2024! (stored in /var/ossec/etc/authd.pass on master)

Filebeat validation: all three indexers return TLSv1.3 + talk to server OK on all
three server nodes.

cluster_control -l output:
```
NAME             TYPE    VERSION  ADDRESS
wazuh-master-01  master  4.14.5   192.168.90.115
wazuh-worker-01  worker  4.14.5   192.168.90.116
wazuh-worker-02  worker  4.14.5   192.168.90.117
```

## Stage 4: Dashboard (COMPLETED)

Installed wazuh-dashboard 4.14.5 on 192.168.90.118.
Accessible at https://192.168.90.118.

Health check results:
- Check API connection: OK
- Check API version: OK
- Check alerts index pattern: warning (expected, no agents yet)
- Check monitoring index pattern: OK
- Check statistics index pattern: OK

Note: wazuh-alerts-* warning is expected at this stage. It will resolve once
agents enroll and generate their first alerts.

## Stage 5: Load Balancer

COMPLETED. HAProxy 2.4.30 on wazuh-lb-01 (192.168.90.112).

Config:
- frontend wazuh_enrollment (1515) -> backend wazuh-master-01 (192.168.90.115)
- frontend wazuh_reporting (1514) -> roundrobin wazuh-worker-01/02 (192.168.90.116/117)
- frontend stats (8404) -> stats UI at /stats

UFW: opened 8404/tcp for stats access.

Validation: stats page shows all backends UP with L4OK health checks. Failover
verified by stopping wazuh-manager on worker-01 (showed DOWN with failed health
checks) then starting it again (returned to UP).

## Stage 6: Agent Groups and Centralized Config

COMPLETED. Run on wazuh-master-01.

Groups created:
- windows
- linux
- (default group exists as built-in fallback)

Centralized configs:
- /var/ossec/etc/shared/windows/agent.conf (Security, System, Application, Sysmon
  channels + asset.os=windows label)
- /var/ossec/etc/shared/linux/agent.conf (auth.log, syslog, audit.log + asset.os=linux
  label)

verify-agent-conf: all three group configs (windows, linux, default) report OK.
Manager restarted to distribute config.

## Stage 7A: Ubuntu Agent Deployment (Ansible)

COMPLETED. Deployed from wazuh-master-01 using Ansible.

Targets, both enrolling through the load balancer at 192.168.90.112:
- ubuntu-agent-01 (192.168.90.119) -> group: linux
- ubuntu-agent-02 (192.168.90.120) -> group: linux

Approach:
- Ansible installed on the master, SSH key based auth to the agents
- A single playbook adds the Wazuh repo, installs wazuh-agent 4.14.5, and starts the
  service, passing the manager, registration server, group, and enrollment password
  as install time variables
- Adding more Linux endpoints later is just a matter of extending the inventory, the
  same playbook scales to any number of hosts

Result:
- Both agents report active with zero failures in the play recap
- Both auto-assigned to the linux group via WAZUH_AGENT_GROUP
- Both visible in the dashboard, connected through the load balancer to wazuh-worker-02
- Dashboard confirms: Active (2), OS Ubuntu (2), Group linux (2)

## Stage 7B: Windows Agent Deployment (Active Directory GPO)

COMPLETED. Three Windows Server 2022 VMs:
- windows-ad-dc (192.168.90.121) -> Active Directory domain controller + DNS, domain lab.local
- win-agent-01 (192.168.90.122) -> domain member, group: windows
- win-agent-02 (192.168.90.123) -> domain member, group: windows

Approach:
- windows-ad-dc promoted to a new forest lab.local (NetBIOS LAB), DNS installed during
  promotion, OU WazuhEndpoints created for the agent machines
- Wazuh MSI published on the \\windows-ad-dc\Software share, readable by domain computers
- A GPO named Deploy-Wazuh-Agent runs a machine startup script that installs the agent
  silently and points enrollment at the load balancer, the script is idempotent so it is
  safe on every boot
- Both agents joined the domain into WazuhEndpoints and picked up the policy, the agent
  installs fleet-wide with no per machine interaction

Result:
- Both Windows agents report active with the Wazuh service running (msiexec exit code 0)
- Both auto-assigned to the windows group via WAZUH_AGENT_GROUP
- agent_control -l on the master shows all four agents active: 001 agent-linux-01,
  002 agent-linux-02, 003 win-agent-02, 004 win-agent-01
- agent_groups confirms windows group holds win-agent-01 and win-agent-02


## Stage 8: Index Management (COMPLETED)

### 8A: ISM Policies

Applied two ISM lifecycle policies to the indexer cluster:

- `wazuh-alerts-policy`: rollover at 1d age or 40 GB primary shard size, delete at 90d.
  Attached to all `wazuh-alerts-*` indices via ISM template (priority 100).
- `wazuh-archives-policy`: rollover at 1d age or 40 GB primary shard size, delete at 30d.
  Attached to all `wazuh-archives-*` indices via ISM template (priority 100).

Both policies confirmed via `_plugins/_ism/policies`.

### 8B: Snapshot Repository

Added `path.repo: ["/mnt/wazuh-snapshots"]` to `/etc/wazuh-indexer/opensearch.yml`
on all three indexer nodes, created the directory, set ownership to `wazuh-indexer`,
and restarted each indexer in turn. Cluster remained green throughout.

Registered filesystem snapshot repository `wazuh-snapshots` with compression enabled.
Note: each indexer node uses its own local `/mnt/wazuh-snapshots` directory (not
shared storage), so the repository is registered with `verify=false` to skip the
cross-node path check. For production, replace with a shared NFS mount or S3
repository so all nodes write to one location.

Test snapshots:
- `snapshot-test-01`: SUCCESS (wazuh-alerts-*)
- `snapshot-test-02`: SUCCESS (wazuh-alerts-*, taken after clean repository registration)

## Stage 9: Final Validation (COMPLETED)

### Indexer cluster
- Status: green
- Nodes: 3 (wazuh-indexer-01/02/03)
- Active shards: 25, unassigned: 0, active_shards_percent: 100.0
- Cluster manager: wazuh-indexer-02 (192.168.90.113)
- Indices present: wazuh-alerts-4.x-2026.06.10 (1491 docs), wazuh-monitoring, wazuh-statistics

### Server cluster
```
NAME             TYPE    VERSION  ADDRESS
wazuh-master-01  master  4.14.5   192.168.90.115
wazuh-worker-01  worker  4.14.5   192.168.90.116
wazuh-worker-02  worker  4.14.5   192.168.90.117
```

### Wazuh API
- authenticate: HTTP 200, token returned
- Dashboard Server APIs page: Online, no errors

### Filebeat
- All three server nodes (master, worker-01, worker-02): talk to server OK on all
  three indexers over TLSv1.3

### Agents and groups
```
ID: 001  Name: agent-linux-01   Group: linux   Status: Active
ID: 002  Name: agent-linux-02   Group: linux   Status: Active
ID: 003  Name: win-agent-02     Group: windows Status: Active
ID: 004  Name: win-agent-01     Group: windows Status: Active
```

### End-to-end event ingestion
Triggered 6 failed SSH login attempts (invaliduser@127.0.0.1) on agent-linux-01.
Alerts confirmed in OpenSearch within seconds:

- rule 5710: sshd: Attempt to login using a non-existent user (level 5)
- rule 5503: PAM: User login failed (level 5)

Full chain verified: agent collect -> worker decode and rule match -> Filebeat ship ->
indexer store -> searchable in OpenSearch and visible in dashboard.

### Overall result
All success criteria met. The lab is fully operational.
