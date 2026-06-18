# Part 1: Planning and Preparation

This part covers project overview, resource planning, network design, the
pre-deployment checklist, and the deployment sequence.

---

# 1. Architecture Overview

## 1.1 Role of each VM

**Wazuh indexer cluster (wazuh-indexer-01/02/03)**
The indexer is the OpenSearch based data store and search engine. It receives alert
and event data from the Wazuh server via Filebeat over port 9200, stores it in
indices, and serves search queries to the dashboard. Three nodes provide high
availability and let primary and replica shards spread across the cluster, so a
single node loss does not stop search.

**Wazuh server cluster (wazuh-master-01, wazuh-worker-01, wazuh-worker-02)**
The server (manager) is the analysis engine. It decodes incoming agent logs,
matches them against rules, and generates alerts. In a cluster there is exactly one
master and one or more workers. The master coordinates and synchronizes shared state
(agent keys, rules, decoders, CDB lists, group files, centralized config). Workers
do the heavy lifting of receiving and analyzing agent events.

**Wazuh dashboard (wazuh-dashboard-01)**
The web UI. It reads alert data from the indexer over 9200 and reads management data
(agents, groups, rules, status) from the Wazuh server API over 55000. It is kept on
its own VM so dashboard load never competes with indexer JVM heap and disk IO.

**Load balancer (wazuh-lb-01)**
An HAProxy TCP load balancer in front of the server cluster. It terminates agent
enrollment (1515) toward the master and distributes agent reporting (1514) across
both workers, with health checks and automatic failover.

**Agents (win-agent-01/02, ubuntu-agent-01/02)**
The endpoint software. Agents collect logs and telemetry and ship them to the server
cluster through the load balancer. Agents never analyze; they only forward.

## 1.2 Difference between the components

| Component       | Job                                    | Data direction                                             |
|-----------------|----------------------------------------|------------------------------------------------------------|
| Agent           | Collect and forward logs               | Sends to LB then to workers                                |
| Load balancer   | Distribute and fail over agent traffic | Forwards 1514 to workers, 1515 to master                   |
| Server cluster  | Decode, rule match, generate alerts    | Receives from agents, sends alerts via Filebeat to indexer |
| Indexer cluster | Store and search alert/event data      | Receives from Filebeat, serves dashboard                   |
| Dashboard       | Visualize and manage                   | Reads indexer (9200) and server API (55000)                |

## 1.3 Why agents point to the load balancer

Pointing agents at a single worker creates a single point of failure and uneven
load. The Wazuh documentation recommends a load balancer so agents register and
report in a distributed way, the load balancer decides which worker handles each
connection, load is spread evenly, and if a worker fails its agents reconnect to a
surviving worker automatically. Agents never need to know the individual worker
addresses; they only know `wazuh-lb.lab.local`.

## 1.4 Why the master should not be the primary event receiver

The master centralizes and coordinates the cluster: agent registration and deletion,
and synchronization of rules, decoders, CDB lists, group files, and centralized
configuration to the workers. If the master also carried the full agent event load,
its synchronization and coordination duties would compete with event analysis,
hurting both. The standard pattern is: master handles enrollment (1515) and
coordination; workers handle the event stream (1514). This is why the load balancer
sends 1515 only to the master and 1514 only to the workers.

## 1.5 How workers receive agent events

Agents send keepalives and events to the load balancer on 1514/TCP. HAProxy forwards
each connection to one of the two workers using round robin with health checks. The
worker that receives the connection decodes the logs, runs them through the ruleset,
and produces alerts locally. All workers share the same rules and decoders because
the master synchronizes them across the cluster.

## 1.6 How Filebeat ships alerts to the indexer

Each server node runs Filebeat. Filebeat reads the manager alert output
(`/var/ossec/logs/alerts/alerts.json`) and ships it to the indexer cluster over
9200/TCP using the Wazuh template. Filebeat is configured with all three indexer
hosts so it can keep delivering if one indexer node is down.

## 1.7 How the dashboard reads data

The dashboard has two backend connections. For alert visualization and search it
queries the indexer cluster on 9200 (configured with all three indexer hosts in
`opensearch.hosts`). For management views (agent list, groups, rules, cluster status,
restarts) it calls the Wazuh server API on 55000. Both connections use TLS.

## 1.8 ASCII architecture diagram

```
                    Windows agents                Ubuntu agents
                  win-agent-01 .101              ubuntu-agent-01 .111
                  win-agent-02 .102              ubuntu-agent-02 .112
                        |                                |
                        |  1514/TCP event and keepalive  |
                        |  1515/TCP enrollment           |
                        +----------------+---------------+
                                         |
                                         v
                              +---------------------+
                              |    wazuh-lb-01      |
                              |   192.168.90.112       |
                              |   HAProxy (TCP)     |
                              +----------+----------+
                                         |
            1515/TCP -> master           |          1514/TCP -> workers (RR)
            +----------------------------+----------------------------+
            |                            |                            |
            v                            v                            v
   +------------------+        +------------------+        +------------------+
   | wazuh-master-01  |        | wazuh-worker-01  |        | wazuh-worker-02  |
   |   192.168.90.115    |<------>|   192.168.90.116    |<------>|   192.168.90.117    |
   |  master node     | 1516   |  worker node     | 1516   |  worker node     |
   +--------+---------+        +--------+---------+        +--------+---------+
            |                           |                           |
            |   Filebeat -> 9200/TCP (alerts.json to indexer cluster)
            +---------------------------+---------------------------+
                                        |
                                        v
   +------------------+   9300-9400  +------------------+   9300-9400  +------------------+
   | wazuh-indexer-01 |<------------>| wazuh-indexer-02 |<------------>| wazuh-indexer-03 |
   |   192.168.90.111    |   transport  |   192.168.90.113    |   transport  |   192.168.90.114    |
   +--------+---------+              +--------+---------+              +--------+---------+
            ^                                 ^                                 ^
            |                                 |                                 |
            +------------------ 9200/TCP search and index ---------------------+
                                        ^
                                        |
                              +---------+-----------+
                              | wazuh-dashboard-01  |
                              |   192.168.90.118       |
                              |  9200 -> indexer    |
                              |  55000 -> server API|
                              +---------+-----------+
                                        ^
                                        | 443/TCP HTTPS
                                        |
                                   Admin / User browser
                              https://wazuh-dashboard.lab.local
```

---

# 2. Resource Planning

Two reference profiles are provided below (minimum lab and production like). The
actual lab is deployed on a third, tighter profile documented first.

## 2.0 Actual deployed profile (this lab)

All 8 server side nodes run Ubuntu 22.04 with 2 GB RAM and 128 GB disk each, due to
resource limits.

| VM                       | IP             | vCPU   | RAM  | Disk   |
|--------------------------|----------------|--------|------|--------|
| wazuh-indexer-01         | 192.168.90.111 | shared | 2 GB | 128 GB |
| wazuh-indexer-02         | 192.168.90.113 | shared | 2 GB | 128 GB |
| wazuh-indexer-03         | 192.168.90.114 | shared | 2 GB | 128 GB |
| wazuh-manager-master     | 192.168.90.115 | shared | 2 GB | 128 GB |
| wazuh-manager-worker-01  | 192.168.90.116 | shared | 2 GB | 128 GB |
| wazuh-manager-worker-02  | 192.168.90.117 | shared | 2 GB | 128 GB |
| wazuh-dashboard          | 192.168.90.118 | shared | 2 GB | 128 GB |
| wazuh-lb-01              | 192.168.90.112 | shared | 2 GB | 128 GB |

### Constraint warning: 2 GB RAM is below the Wazuh recommended minimum

The Wazuh documentation recommends 4 GB minimum for an indexer node. Running indexer
and worker nodes at 2 GB will boot and is fine for a low volume proof of concept, but
expect memory pressure once ingestion rises or during search. Mandatory mitigations
already applied in Stage 0:

- **Swap**: 4 GB swapfile on every node, with `vm.swappiness=10` so swap is used only
  under pressure. This is a safety net against the out of memory killer terminating
  the indexer or manager, not a substitute for RAM.
- **JVM heap**: set the indexer heap explicitly to about half of RAM and equal min and
  max. For 2 GB nodes use 1 GB heap. Edit `/etc/wazuh-indexer/jvm.options`:
  ```
  -Xms1g
  -Xmx1g
  ```
  Do the same caution for the Wazuh server JVM if you tune it; leave headroom for the
  OS and filesystem cache.
- **vm.max_map_count=262144** on indexer nodes (required for OpenSearch to start).

If you can raise RAM later, prioritize the three indexer nodes first (to 4 GB), then
the two workers. The dashboard and load balancer tolerate 2 GB more comfortably.

## 2.1 Profile A: Minimum lab version

Suitable for a laptop or resource constrained host. The whole lab fits in roughly
32 GB RAM if you are careful, but 48 to 64 GB is comfortable.


| VM                      | vCPU | RAM  | Disk  | Notes                          |
|-------------------------|------|------|-------|--------------------------------|
| wazuh-indexer-01        | 2    | 4 GB | 50 GB | JVM heap 2 GB                  |
| wazuh-indexer-02        | 2    | 4 GB | 50 GB | JVM heap 2 GB                  |
| wazuh-indexer-03        | 2    | 4 GB | 50 GB | JVM heap 2 GB                  |
| wazuh-manager-master    | 2    | 4 GB | 40 GB | Coordination, enrollment       |
| wazuh-manager-worker-01 | 2    | 4 GB | 40 GB | Event analysis                 |
| wazuh-manager-worker-02 | 2    | 4 GB | 40 GB | Event analysis                 |
| wazuh-dashboard         | 2    | 4 GB | 30 GB | Node and OpenSearch Dashboards |
| wazuh-lb-01             | 1    | 1 GB | 20 GB | HAProxy only                   |
| win-agent-01            | 2    | 4 GB | 40 GB | Windows Server or 10/11        |
| win-agent-02            | 2    | 4 GB | 40 GB | Windows Server or 10/11        |
| linux-agent-01          | 1    | 2 GB | 20 GB | Ubuntu 22.04/24.04             |
| linux-agent-02          | 1    | 2 GB | 20 GB | Ubuntu 22.04/24.04             |

## 2.2 Profile B: Production like lab version

Realistic for simulating an enterprise rollout and for index/shard testing under
load.

| VM                      | vCPU | RAM   | Disk       | Notes                             |
|-------------------------|------|-------|------------|---------------------------------- |
| wazuh-indexer-01        | 8    | 16 GB | 500 GB SSD | JVM heap 8 GB, data tier          |
| wazuh-indexer-02        | 8    | 16 GB | 500 GB SSD | JVM heap 8 GB, data tier          | 
| wazuh-indexer-03        | 8    | 16 GB | 500 GB SSD | JVM heap 8 GB, data tier          |
| wazuh-manager-master    | 4    | 8 GB  | 100 GB     | Coordination, enrollment          |
| wazuh-manager-worker-01 | 8    | 16 GB | 200 GB     | High event throughput             |
| wazuh-manager-worker-02 | 8    | 16 GB | 200 GB     | High event throughput             |
| wazuh-dashboard         | 4    | 8 GB  | 100 GB     | Dedicated, not on indexer         |
| wazuh-lb-01             | 2    | 2 GB  | 40 GB      | HAProxy, lightweight but critical |
| win-agent-01            | 2    | 4 GB  | 60 GB      | Windows endpoint                  |
| win-agent-02            | 2    | 4 GB  | 60 GB      | Windows endpoint                  |
| linux-agent-01          | 2    | 4 GB  | 40 GB      | Ubuntu endpoint                   |
| linux-agent-02          | 2    | 4 GB  | 40 GB      | Ubuntu endpoint                   |

## 2.3 Sizing notes

- The indexer needs the most disk and RAM. It stores all indexed data and runs a
  JVM whose heap should be roughly half the node RAM and never above about 26 to 32
  GB. Set heap equal on min and max in `jvm.options`.
- Workers need enough CPU and RAM for event decoding and rule matching, since they
  carry the agent event stream. Scale workers, not the master, when event volume
  grows.
- The dashboard must not share a host with an indexer node in a production ready
  lab. Dashboard rendering and OpenSearch heap will contend for the same memory and
  IO and cause slow searches.
- The load balancer is lightweight on CPU and RAM but is critical to availability.
  If it dies, all agent enrollment and reporting stops. Consider a second HAProxy
  with keepalived for a real production design.
- Disk on indexers should be SSD. Spinning disk will bottleneck indexing and search
  latency once volume rises.

---

# 3. Network and Firewall Matrix

## 3.1 Port matrix

| Source                  | Destination             | Port      | Protocol | Function                                         | Required |
|-------------------------|-------------------------|-----------|----------|--------------------------------------------------|----------|
| Agents                  | wazuh-lb-01             | 1514      | TCP      | Agent event and keepalive reporting              | Required |
| Agents                  | wazuh-lb-01             | 1515      | TCP      | Agent enrollment                                 | Required |
| wazuh-lb-01             | wazuh-manager-master    | 1515      | TCP      | Enrollment forward to master                     | Required |
| wazuh-lb-01             | wazuh-manager-worker-01 | 1514      | TCP      | Event forward to worker                          | Required |
| wazuh-lb-01             | wazuh-manager-worker-02 | 1514      | TCP      | Event forward to worker                          | Required |
| Server nodes            | Server nodes            | 1516      | TCP      | Wazuh server cluster communication               | Required |
| Server nodes (Filebeat) | Indexer nodes           | 9200      | TCP      | Ship alerts to indexer                           | Required |
| Indexer nodes           | Indexer nodes           | 9300-9400 | TCP      | Indexer inter node transport                     | Required |
| wazuh-dashboard         | Server API (master)     | 55000     | TCP      | Management data                                  | Required |
| wazuh-dashboard         | Indexer nodes           | 9200      | TCP      | Alert search                                     | Required |
| Admin/User              | wazuh-dashboard         | 443       | TCP      | Dashboard HTTPS                                  | Required |
| Admin                   | All Linux nodes         | 22        | TCP      | SSH administration                               | Optional |
| Admin                   | Windows agents          | 3389      | TCP      | RDP administration                               | Optional |
| Admin                   | Windows agents          | 5985/5986 | TCP      | WinRM (PowerShell Remoting)                      | Optional |
| Agents                  | wazuh-manager-master    | 1514/1515 | TCP      | Direct failover if LB down (not used by default) | Optional |

Notes on the API port: the dashboard connects to the Wazuh server API on 55000. In a
cluster the API runs on every node; point the dashboard at the master for a stable
management endpoint, or front the API with the load balancer if you want HA on it
too.

## 3.2 UFW examples

### Indexer node (each of wazuh-indexer-01/02/03)

```bash
sudo ufw allow 9200/tcp comment 'indexer http api'
sudo ufw allow 9300:9400/tcp comment 'indexer transport'
sudo ufw allow 22/tcp comment 'ssh admin'
sudo ufw enable
sudo ufw status numbered
```

### Master node (wazuh-master-01)

```bash
sudo ufw allow 1515/tcp comment 'agent enrollment from LB'
sudo ufw allow 1516/tcp comment 'server cluster'
sudo ufw allow 55000/tcp comment 'wazuh api'
sudo ufw allow 9200/tcp comment 'filebeat to indexer'  # egress; needed on indexer side
sudo ufw allow 22/tcp
sudo ufw enable
```

### Worker node (wazuh-worker-01/02)

```bash
sudo ufw allow 1514/tcp comment 'agent events from LB'
sudo ufw allow 1516/tcp comment 'server cluster'
sudo ufw allow 55000/tcp comment 'wazuh api'
sudo ufw allow 22/tcp
sudo ufw enable
```

### Load balancer (wazuh-lb-01)

```bash
sudo ufw allow 1514/tcp comment 'agent events in'
sudo ufw allow 1515/tcp comment 'agent enrollment in'
sudo ufw allow 22/tcp
sudo ufw enable
```

### Dashboard (wazuh-dashboard-01)

```bash
sudo ufw allow 443/tcp comment 'dashboard https'
sudo ufw allow 22/tcp
sudo ufw enable
```

## 3.3 iptables example (indexer node)

If you prefer raw iptables instead of UFW on the indexers:

```bash
# Allow established
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Indexer HTTP API (restrict to server cluster + dashboard + other indexers)
iptables -A INPUT -p tcp --dport 9200 -s 192.168.90.0/24 -j ACCEPT
# Indexer transport between indexer nodes only
iptables -A INPUT -p tcp --dport 9300:9400 -s 192.168.90.111 -j ACCEPT
iptables -A INPUT -p tcp --dport 9300:9400 -s 192.168.90.113 -j ACCEPT
iptables -A INPUT -p tcp --dport 9300:9400 -s 192.168.90.114 -j ACCEPT
# SSH
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
# Loopback
iptables -A INPUT -i lo -j ACCEPT
# Default drop
iptables -P INPUT DROP
```

Tighten the source addresses to the actual subnet in production. In this lab all
nodes share `192.168.90.0/24`.

---

# 4. Pre deployment Checklist

Complete every item before installing any Wazuh package.

## 4.1 Checklist

- [ ] **OS baseline**: Ubuntu 22.04/24.04 LTS on all Linux nodes, fully updated
      (`apt update && apt upgrade`). Windows Server 2019/2022 or Windows 10/11 on
      agents.
- [ ] **Hostname**: set each node hostname to match the topology
      (`hostnamectl set-hostname wazuh-indexer-01`).
- [ ] **Static IP**: assign the fixed IP from the topology table to each node.
- [ ] **DNS or /etc/hosts**: every node must resolve every other node by FQDN. Use
      the shared `/etc/hosts` below if you have no internal DNS.
- [ ] **NTP / time sync**: enable `systemd-timesyncd` or chrony on all nodes. Clock
      drift breaks TLS and cluster sync.
- [ ] **Firewall**: open the ports from section 3 before install, or temporarily
      disable and re enable after.
- [ ] **Package dependencies**: `curl`, `apt-transport-https`, `gnupg`, `lsb-release`
      on Linux nodes.
- [ ] **Certificate planning**: decide node names now; they must match the cert
      common names. Generate certs centrally on one node and copy out.
- [ ] **Disk planning**: confirm indexer data path has the planned disk; mount a
      separate volume on `/var/lib/wazuh-indexer` if possible.
- [ ] **VM snapshot**: snapshot every VM in a clean post OS state before installing
      Wazuh. This is your rollback point.
- [ ] **Internet access / repo**: nodes can reach `packages.wazuh.com` or you have a
      local mirror for offline install.
- [ ] **User privilege / sudo**: an admin user with sudo on every Linux node.
- [ ] **SSH access between nodes**: at least from the node you run cert generation
      and Ansible on, to all others, ideally key based.
- [ ] **Browser access**: a workstation that can reach
      `https://wazuh-dashboard.lab.local` on 443.
- [ ] **Validate ports between nodes**: test reachability before install with
      `nc -vz <host> <port>`.
- [ ] **Enrollment password planning**: decide whether to enable an enrollment
      password. If yes, set it on the master and distribute via `WAZUH_REGISTRATION_PASSWORD`.
- [ ] **Backup directory planning**: decide the snapshot repository path and a config
      backup location (see section 15-I).

## 4.2 Shared /etc/hosts for all Linux servers

Place this in `/etc/hosts` on every Linux node (also see `configs/shared/hosts`).

```
127.0.0.1   localhost

# Wazuh indexer cluster
192.168.90.111 wazuh-indexer-01.lab.local wazuh-indexer-01
192.168.90.113 wazuh-indexer-02.lab.local wazuh-indexer-02
192.168.90.114 wazuh-indexer-03.lab.local wazuh-indexer-03

# Wazuh server cluster
192.168.90.115 wazuh-master-01.lab.local wazuh-master-01
192.168.90.116 wazuh-worker-01.lab.local wazuh-worker-01
192.168.90.117 wazuh-worker-02.lab.local wazuh-worker-02

# Dashboard and load balancer
192.168.90.118 wazuh-dashboard.lab.local wazuh-dashboard-01
192.168.90.112 wazuh-lb.lab.local wazuh-lb-01

# Endpoints
192.168.90.121 windows-ad-dc.lab.local windows-ad-dc
192.168.90.122 win-agent-01.lab.local win-agent-01
192.168.90.123 win-agent-02.lab.local win-agent-02
192.168.90.119 ubuntu-agent-01.lab.local ubuntu-agent-01
192.168.90.120 ubuntu-agent-02.lab.local ubuntu-agent-02
```

On Windows agents add the same entries to
`C:\Windows\System32\drivers\etc\hosts`, at minimum the load balancer line:

```
192.168.90.112 wazuh-lb.lab.local
```

## 4.3 Stage 0 executed procedures (this lab)

These are the exact baseline steps run on the 8 server side nodes before any Wazuh
package was installed. Run on every node unless noted.

### Step 1: Update OS

```bash
sudo apt update && sudo apt upgrade -y
```

### Step 2: Set hostname (per node)

```bash
sudo hostnamectl set-hostname wazuh-indexer-01   # 192.168.90.111
sudo hostnamectl set-hostname wazuh-indexer-02   # 192.168.90.113
sudo hostnamectl set-hostname wazuh-indexer-03   # 192.168.90.114
sudo hostnamectl set-hostname wazuh-master-01    # 192.168.90.115
sudo hostnamectl set-hostname wazuh-worker-01    # 192.168.90.116
sudo hostnamectl set-hostname wazuh-worker-02    # 192.168.90.117
sudo hostnamectl set-hostname wazuh-lb-01        # 192.168.90.112
sudo hostnamectl set-hostname wazuh-dashboard-01 # 192.168.90.118
```

### Step 3: /etc/hosts (append on every node)

```bash
sudo tee -a /etc/hosts <<'EOF'

# Wazuh lab nodes
192.168.90.111  wazuh-indexer-01.lab.local  wazuh-indexer-01
192.168.90.113  wazuh-indexer-02.lab.local  wazuh-indexer-02
192.168.90.114  wazuh-indexer-03.lab.local  wazuh-indexer-03
192.168.90.115  wazuh-master-01.lab.local   wazuh-master-01
192.168.90.116  wazuh-worker-01.lab.local   wazuh-worker-01
192.168.90.117  wazuh-worker-02.lab.local   wazuh-worker-02
192.168.90.112  wazuh-lb.lab.local          wazuh-lb-01
192.168.90.118  wazuh-dashboard.lab.local   wazuh-dashboard-01
EOF
```

### Step 4: Time sync with chrony

```bash
sudo apt install -y chrony
sudo systemctl enable chrony
sudo systemctl start chrony
chronyc tracking   # confirm System time offset under 1 second
```

### Step 5: Swap 4 GB (mandatory, compensates 2 GB RAM)

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
free -h
```

### Step 6: Kernel tuning for OpenSearch (indexer nodes only)

```bash
echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
sysctl vm.max_map_count   # must report 262144
```

### Step 7: Base dependencies

```bash
sudo apt install -y curl gnupg apt-transport-https lsb-release ca-certificates wget
```

### Step 8: Firewall (UFW) per role

Indexer (111, 113, 114):
```bash
sudo ufw allow 22/tcp
sudo ufw allow 9200/tcp
sudo ufw allow 9300:9400/tcp
sudo ufw --force enable
```

Master (115):
```bash
sudo ufw allow 22/tcp
sudo ufw allow 1514/tcp
sudo ufw allow 1515/tcp
sudo ufw allow 1516/tcp
sudo ufw allow 55000/tcp
sudo ufw --force enable
```

Workers (116, 117):
```bash
sudo ufw allow 22/tcp
sudo ufw allow 1514/tcp
sudo ufw allow 1516/tcp
sudo ufw allow 55000/tcp
sudo ufw --force enable
```

Load balancer (112):
```bash
sudo ufw allow 22/tcp
sudo ufw allow 1514/tcp
sudo ufw allow 1515/tcp
sudo ufw --force enable
```

Dashboard (118):
```bash
sudo ufw allow 22/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
```

### Step 9: Validate connectivity between nodes

From wazuh-master-01:
```bash
nc -vz 192.168.90.111 22   # use port 22 before Wazuh is installed
nc -vz 192.168.90.113 22
nc -vz 192.168.90.114 22
```

Note: before Wazuh packages are installed, ports like 9200, 1514, 1515, and 443
will return "Connection refused" because nothing is listening yet. That is expected.
"Connection refused" means the network path is fine but no service is bound;
contrast with "No route to host" or "timed out" which indicate a real network or
firewall problem. Test against port 22 (SSH) to confirm reachability at this stage.

Stage 0 is complete when every node resolves all FQDNs, chrony offset is under one
second, swap is active, indexer nodes report `vm.max_map_count = 262144`, UFW is
enabled per role, and SSH connectivity between nodes succeeds.

---

# 5. Deployment Sequence

The order below is deliberate. Each stage depends on the one before it being healthy.

1. Prepare all VMs (OS, updates, snapshot).
2. Configure hostname and DNS / /etc/hosts.
3. Configure time sync.
4. Configure firewall baseline.
5. Generate Wazuh certificates (one central node, then distribute).
6. Deploy Wazuh indexer cluster (install on all 3 nodes).
7. Initialize Wazuh indexer cluster (run securityadmin once).
8. Validate Wazuh indexer cluster (health green, 3 nodes).
9. Deploy Wazuh master.
10. Deploy Wazuh workers.
11. Configure Wazuh server cluster (cluster block on each node).
12. Validate Wazuh server cluster (cluster_control shows workers).
13. Deploy Wazuh dashboard.
14. Validate dashboard access (login over HTTPS).
15. Deploy load balancer (HAProxy).
16. Validate load balancer port forwarding (listen on 1514/1515, backends up).
17. Create Wazuh agent groups (windows, linux).
18. Create centralized agent configuration (agent.conf per group).
19. Deploy Windows agents using mass deployment simulation (GPO or PS Remoting).
20. Deploy Ubuntu agents using Ansible.
21. Validate agent enrollment (agents appear, correct groups).
22. Validate event ingestion (events arrive at workers, alerts generated).
23. Validate dashboard visibility (alerts searchable).
24. Configure index management and retention (ISM policies, templates).
25. Configure snapshot / backup strategy (repository, schedule, restore test).
26. Final validation and lab report.

## Why this order matters

- **Certificates first (step 5).** Every component (indexer, server, dashboard,
  Filebeat) relies on the same certificate authority. Generating all certs up front
  avoids mismatched CAs that block cluster join and Filebeat shipping.
- **Indexer before server (steps 6 to 8).** The server's Filebeat ships alerts to
  the indexer. If the indexer cluster is not healthy first, Filebeat has nowhere to
  send data and you will chase false alarms.
- **Server cluster before dashboard (steps 9 to 12).** The dashboard reads the
  server API and the indexer. Standing up the server cluster first means the
  dashboard has both backends ready at first login.
- **Load balancer before agents (steps 15 to 16).** Agents are configured to enroll
  and report only through the load balancer. If the LB is not forwarding correctly,
  enrollment fails and you cannot tell whether the problem is the agent, the LB, or
  the server.
- **Groups and centralized config before agent deployment (steps 17 to 18).** The
  `windows` and `linux` groups must exist before mass deployment so that
  `WAZUH_AGENT_GROUP` lands each agent in the right group on first enrollment and
  immediately receives the correct `agent.conf`.
- **Validate ingestion before index management (steps 22 to 24).** Confirm real data
  flows end to end before you start applying retention, rollover, and shard policies,
  so you are tuning against actual indices.
- **Snapshots last but not optional (step 25).** Once data and configuration exist,
  protect them. The indexer cluster is not a backup of itself.
