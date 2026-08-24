# Deployment

Record of actual deployment progress and verified configurations.

## Environment

* All nodes: Ubuntu 22.04.5 LTS
* Wazuh version: 4.14.5 stable version (installed pinned as 4.14.5-1 on all nodes)
* Subnet: <SUBNET>
* Access method: VPN

## Stage 0: OS Baseline (COMPLETED)

All 8 server nodes configured:
* Hostname set per role
* /etc/hosts populated on all nodes
* chrony installed and synced
* Swap 4 GB + vm.swappiness=10 on all nodes
* vm.max_map_count=262144 on indexer nodes (111, 113, 114)
* Dependencies installed (curl, gnupg, apt-transport-https, etc.)
* UFW configured per role
* Connectivity validated (nc tests)

## Stage 1: Certificates (COMPLETED)

Generated on wazuh-indexer-01 (<INDEXER_01_IP>):
* Tool: wazuh-certs-tool.sh -A
* Config: config.yml with all 8 nodes
* Output: wazuh-certificates.tar (50K, 18 certificate files)
* Distributed via scp to all nodes

Certificates generated:
* admin.pem + admin-key.pem
* root-ca.pem + root-ca.key
* wazuh-indexer-01/02/03 pem + key
* wazuh-master-01/worker-01/worker-02 pem + key
* wazuh-dashboard pem + key

## Stage 2: Indexer Cluster (COMPLETED)

Installed on <INDEXER_01_IP>, <INDEXER_02_IP>, <INDEXER_03_IP>.
JVM heap: -Xms1g -Xmx1g on all indexer nodes.
Cluster initialized with indexer-security-init.sh on indexer-01.

Validation result:
* status: green
* number_of_nodes: 3
* unassigned_shards: 0
* active_shards_percent: 100.0
* Cluster manager: wazuh-indexer-02 (<INDEXER_02_IP>)

## Stage 3: Server Cluster (COMPLETED)

Installed wazuh-manager 4.14.5 on all three server nodes.
Installed Filebeat 7.10.2 on all three server nodes.

Cluster config:
* Cluster key: <CLUSTER_KEY>
* Master: wazuh-master-01 (<MASTER_IP>)
* Workers: wazuh-worker-01 (<WORKER_01_IP>), wazuh-worker-02 (<WORKER_02_IP>)

Enrollment password: <ENROLLMENT_PASSWORD> (stored in /var/ossec/etc/authd.pass on master)

Filebeat validation: all three indexers return TLSv1.3 + talk to server OK on all
three server nodes.

cluster_control -l output:
```
NAME             TYPE    VERSION  ADDRESS
wazuh-master-01  master  4.14.5   <MASTER_IP>
wazuh-worker-01  worker  4.14.5   <WORKER_01_IP>
wazuh-worker-02  worker  4.14.5   <WORKER_02_IP>
```

## Stage 4: Dashboard (COMPLETED)

Installed wazuh-dashboard 4.14.5 on <DASHBOARD_IP>.
Accessible at https://<DASHBOARD_IP>.

Health check results:
* Check API connection: OK
* Check API version: OK
* Check alerts index pattern: warning (expected, no agents yet)
* Check monitoring index pattern: OK
* Check statistics index pattern: OK

Note: wazuh-alerts-* warning is expected at this stage. It will resolve once
agents enroll and generate their first alerts.

## Stage 5: Load Balancer

COMPLETED. HAProxy 2.4.30 on wazuh-lb-01 (<LB_IP>).

Config:
* frontend wazuh_enrollment (1515) -> backend wazuh-master-01 (<MASTER_IP>)
* frontend wazuh_reporting (1514) -> roundrobin wazuh-worker-01/02 (<WORKER_01_IP>/117)
* frontend stats (8404) -> stats UI at /stats

UFW: opened 8404/tcp for stats access.

Validation: stats page shows all backends UP with L4OK health checks. Failover
verified by stopping wazuh-manager on worker-01 (showed DOWN with failed health
checks) then starting it again (returned to UP).

## Stage 6: Agent Groups and Centralized Config

COMPLETED. Run on wazuh-master-01.

Groups created:
* windows
* linux
* (default group exists as built in fallback)

A third group named `win` also exists on the cluster and holds two agents, but it is not
created by this stage and has no centralized config recorded here. See
`docs/EVALUATION.md`, finding 4.

Centralized configs:
* /var/ossec/etc/shared/windows/agent.conf (Security, System, Application, Sysmon
  channels + asset.os=windows label)
* /var/ossec/etc/shared/linux/agent.conf (auth.log, syslog, audit.log + asset.os=linux
  label)

verify-agent-conf: all three group configs (windows, linux, default) report OK.
Manager restarted to distribute config.

## Stage 7A: Ubuntu Agent Deployment (Ansible)

COMPLETED. Deployed from wazuh-master-01 using Ansible.

Targets, both enrolling through the load balancer at <LB_IP>:
* ubuntu-agent-01 (<UBUNTU_AGENT_01_IP>) -> group: linux
* ubuntu-agent-02 (<UBUNTU_AGENT_02_IP>) -> group: linux

Approach:
* Ansible installed on the master, SSH key based auth to the agents
* A single playbook adds the Wazuh repo, installs wazuh-agent 4.14.5, and starts the
  service, passing the manager, registration server, group, and enrollment password
  as install time variables
* Adding more Linux endpoints later is just a matter of extending the inventory, the
  same playbook scales to any number of hosts

Result:
* Both agents report active with zero failures in the play recap
* Both assigned automatically to the linux group via WAZUH_AGENT_GROUP
* Both visible in the dashboard, enrolled through the load balancer
* Dashboard confirms: Active (2), OS Ubuntu (2), Group linux (2)
* The two agents landed on different workers, `agent-linux-01` on wazuh-worker-02 and
  `agent-linux-02` on wazuh-worker-01, which is the round robin on 1514 doing its job
* Both registered under the names `agent-linux-01` and `agent-linux-02` rather than
  their hostnames `ubuntu-agent-01` and `ubuntu-agent-02`

## Stage 7B: Windows Agent Deployment (Active Directory GPO)

COMPLETED. Three Windows Server 2022 VMs:
* windows-ad-dc (<AD_DC_IP>) -> Active Directory domain controller + DNS, domain lab.local
* win-agent-01 (<WIN_AGENT_01_IP>) -> domain member, group: windows
* win-agent-02 (<WIN_AGENT_02_IP>) -> domain member, group: windows

Approach:
* windows-ad-dc promoted to a new forest lab.local (NetBIOS LAB), DNS installed during
  promotion, OU WazuhEndpoints created for the agent machines
* Wazuh MSI published on the \\windows-ad-dc\Software share, readable by domain computers
* A GPO named Deploy-Wazuh-Agent runs a machine startup script that installs the agent
  silently and points enrollment at the load balancer, the script is idempotent so it is
  safe on every boot
* Both agents joined the domain into WazuhEndpoints and picked up the policy, the agent
  installs across the fleet with no per machine interaction

Result:
* Both Windows agents report active with the Wazuh service running (msiexec exit code 0)
* Both assigned automatically to the windows group via WAZUH_AGENT_GROUP
* agent_control -l on the master shows five agents active: 001 agent-linux-01,
  002 agent-linux-02, 003 win-agent-02, 004 win-agent-01, 005 windows-ad-dc.
  The domain controller runs an agent as well, so the fleet is five endpoints rather
  than the four the group deployment accounts for
* agent_groups confirms windows group holds win-agent-01 and win-agent-02


## Stage 8: Index Management (COMPLETED)

### 8A: ISM Policies

Applied two ISM lifecycle policies to the indexer cluster:

* `wazuh-alerts-policy`: rollover at 1d age or 40 GB primary shard size, delete at 90d.
  Attached to all `wazuh-alerts-*` indices via ISM template (priority 100).
* `wazuh-archives-policy`: rollover at 1d age or 40 GB primary shard size, delete at 30d.
  Attached to all `wazuh-archives-*` indices via ISM template (priority 100).

Both policies confirmed via `_plugins/_ism/policies`.

### 8B: Snapshot Repository

Added `path.repo: ["/mnt/wazuh-snapshots"]` to `/etc/wazuh-indexer/opensearch.yml`
on all three indexer nodes, created the directory, set ownership to `wazuh-indexer`,
and restarted each indexer in turn. Cluster remained green throughout.

Registered filesystem snapshot repository `wazuh-snapshots` with compression enabled.
Note: each indexer node uses its own local `/mnt/wazuh-snapshots` directory (not
shared storage), so the repository is registered with `verify=false` to skip the
cross node path check. For production, replace with a shared NFS mount or S3
repository so all nodes write to one location.

Test snapshots:
* `snapshot-test-01`: SUCCESS (wazuh-alerts-*)
* `snapshot-test-02`: SUCCESS (wazuh-alerts-*, taken after clean repository registration)

## Stage 9: Final Validation (COMPLETED)

### Indexer cluster
* Status: green
* Nodes: 3 (wazuh-indexer-01/02/03)
* Active shards: 25, unassigned: 0, active_shards_percent: 100.0
* Cluster manager: wazuh-indexer-02 (<INDEXER_02_IP>)
* Indices present: `wazuh-alerts-4.x-2026.06.10` (1491 docs), `wazuh-monitoring`, `wazuh-statistics`

### Server cluster
```
NAME             TYPE    VERSION  ADDRESS
wazuh-master-01  master  4.14.5   <MASTER_IP>
wazuh-worker-01  worker  4.14.5   <WORKER_01_IP>
wazuh-worker-02  worker  4.14.5   <WORKER_02_IP>
```

### Wazuh API
* authenticate: HTTP 200, token returned
* Dashboard Server APIs page: Online, no errors

### Filebeat
* All three server nodes (master, worker-01, worker-02): talk to server OK on all
  three indexers over TLSv1.3

### Agents and groups
```
ID: 001  Name: agent-linux-01   Group: linux          Status: Active
ID: 002  Name: agent-linux-02   Group: linux          Status: Active
ID: 003  Name: win-agent-02     Group: windows        Status: Active
ID: 004  Name: win-agent-01     Group: windows, win   Status: Active
ID: 005  Name: windows-ad-dc    Group: win            Status: Active
```

Agent 004 belongs to two groups and agent 005 belongs only to `win`, a third group that
Stage 6 does not create. See `docs/EVALUATION.md`, finding 4.

### End to end event ingestion
Triggered 6 failed SSH login attempts (invaliduser@127.0.0.1) on agent-linux-01.
Alerts confirmed in OpenSearch within seconds:

* rule 5710: `sshd: Attempt to login using a non-existent user` (level 5)
* rule 5503: PAM: User login failed (level 5)

Full chain verified: agent collect -> worker decode and rule match -> Filebeat ship ->
indexer store -> searchable in OpenSearch and visible in dashboard.

### Overall result
All success criteria met. The lab is fully operational.
